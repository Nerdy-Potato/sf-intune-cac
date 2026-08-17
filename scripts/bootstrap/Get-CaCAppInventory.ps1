#Requires -Version 7.2
<#
.SYNOPSIS
    Lists every Intune mobile app object in the tenant with its actual, live @odata.type and
    publishingState, as reported by Microsoft Graph right now.
.DESCRIPTION
    Diagnostic, read-only tool. Get-CaCRemoteAppCandidates matches remote apps to configuration
    by packageId/bundleId only, and Get-CaCPayloadDrift intentionally excludes @odata.type from
    drift comparison (the type is immutable after creation, so a normal Update can never fix it).
    That means a live app object created with the wrong concrete type (for example a beta
    'androidManagedStoreApp' object instead of the v1.0 'managedAndroidStoreApp' type declared in
    config/apps/*.json) will silently and permanently report as 'NoChange' in every plan, even
    though the Intune portal displays it differently (frequently as a "Built-in" app rather than a
    "Managed Google Play Store app").

    Run this to see, for every current mobileApps object, whether its live type actually matches
    what config declares - so mismatches can be identified and deleted for CI to recreate correctly
    typed, instead of being missed indefinitely.
.EXAMPLE
    ./scripts/bootstrap/Get-CaCAppInventory.ps1
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string] $TenantId = $env:AZURE_TENANT_ID,

    [Parameter()]
    [string] $ClientId = $env:AZURE_CLIENT_ID
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $TenantId -or -not $ClientId) {
    throw (
        'TenantId and ClientId are required. Run this script from GitHub Actions with ' +
        'AZURE_TENANT_ID and AZURE_CLIENT_ID set for the OIDC-backed Graph identity.'
    )
}

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../..')).Path
Import-Module -Name (Join-Path $repoRoot 'src/IntuneCaC/IntuneCaC.psd1') -Force

Connect-CaCGraph -TenantId $TenantId -ClientId $ClientId

$module = Get-Module -Name IntuneCaC
if (-not $module) {
    throw 'IntuneCaC module did not load.'
}

$graphInvoker = $module.NewBoundScriptBlock({
        param(
            [Parameter(Mandatory)][string] $Method,
            [Parameter(Mandatory)][string] $Uri,
            $Body
        )

        Invoke-CaCGraphRequest -Method $Method -Uri $Uri -Body $Body
    })

$configuration = Get-CaCConfiguration -Path (Join-Path $repoRoot 'config')
$configuredByPackageOrBundle = @{}
foreach ($app in $configuration.Apps) {
    $configuredPackageId = Get-CaCProperty -InputObject $app.payload -Name 'packageId'
    $configuredBundleId = Get-CaCProperty -InputObject $app.payload -Name 'bundleId'
    $key = if ($configuredPackageId) { $configuredPackageId } elseif ($configuredBundleId) { $configuredBundleId } else { $null }
    if ($key) { $configuredByPackageOrBundle[$key] = $app }
}

$remoteApps = @((& $graphInvoker 'GET' 'deviceAppManagement/mobileApps' $null).value | Where-Object { $_ })

$rows = foreach ($remote in $remoteApps) {
    $packageId = Get-CaCProperty -InputObject $remote -Name 'packageId'
    $bundleId = Get-CaCProperty -InputObject $remote -Name 'bundleId'
    $key = if ($packageId) { $packageId } elseif ($bundleId) { $bundleId } else { $null }
    $configured = if ($key) { $configuredByPackageOrBundle[$key] } else { $null }
    $desiredType = if ($configured) { $configured.payload.'@odata.type' } else { $null }
    $actualType = Get-CaCProperty -InputObject $remote -Name '@odata.type'

    [pscustomobject]@{
        Id               = Get-CaCProperty -InputObject $remote -Name 'id'
        DisplayName      = Get-CaCProperty -InputObject $remote -Name 'displayName'
        PackageOrBundle  = $key
        ActualType       = $actualType
        ConfiguredType   = $desiredType
        TypeMismatch     = [bool]($desiredType -and $actualType -ne $desiredType)
        PublishingState  = Get-CaCProperty -InputObject $remote -Name 'publishingState'
    }
}

$rows | Sort-Object DisplayName | Format-Table -AutoSize -Wrap
$mismatches = @($rows | Where-Object TypeMismatch)
if ($mismatches) {
    Write-Host ''
    Write-Warning "$($mismatches.Count) app object(s) have a live @odata.type that does not match configuration:"
    $mismatches | ForEach-Object { Write-Warning "  $($_.DisplayName) [$($_.Id)]: actual '$($_.ActualType)' vs configured '$($_.ConfiguredType)'" }
}
