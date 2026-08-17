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

# Get-CaCProperty is a private module function; bind it to the module scope the same way
# graphInvoker is bound above, rather than duplicating its hashtable/PSCustomObject logic here.
$getProperty = $module.NewBoundScriptBlock({
        param(
            $InputObject,
            [Parameter(Mandatory)][string] $Name
        )

        Get-CaCProperty -InputObject $InputObject -Name $Name
    })

$configuration = Get-CaCConfiguration -Path (Join-Path $repoRoot 'config')
# Case-sensitive dictionaries, split by identity field: PowerShell's default @{} hashtable
# compares string keys case-insensitively, which would silently collide an Android packageId
# (e.g. com.microsoft.office.word) with a differently-cased iOS bundleId
# (e.g. com.microsoft.Office.Word) and report a false type mismatch. Splitting by field also
# guarantees we never compare across identity types, matching the switch on $App.source in
# Get-CaCRemoteAppCandidates.
$configuredByPackageId = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
$configuredByBundleId = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
foreach ($app in $configuration.Apps) {
    $configuredPackageId = & $getProperty $app.payload 'packageId'
    $configuredBundleId = & $getProperty $app.payload 'bundleId'
    if ($configuredPackageId) { $configuredByPackageId[$configuredPackageId] = $app }
    if ($configuredBundleId) { $configuredByBundleId[$configuredBundleId] = $app }
}

$remoteApps = @((& $graphInvoker 'GET' 'deviceAppManagement/mobileApps' $null).value | Where-Object { $_ })

$rows = foreach ($remote in $remoteApps) {
    $packageId = & $getProperty $remote 'packageId'
    $bundleId = & $getProperty $remote 'bundleId'

    $configured = $null
    $key = $null
    if ($packageId -and $configuredByPackageId.ContainsKey($packageId)) {
        $configured = $configuredByPackageId[$packageId]
        $key = $packageId
    }
    elseif ($bundleId -and $configuredByBundleId.ContainsKey($bundleId)) {
        $configured = $configuredByBundleId[$bundleId]
        $key = $bundleId
    }
    else {
        $key = if ($packageId) { $packageId } elseif ($bundleId) { $bundleId } else { $null }
    }

    $desiredType = if ($configured) { $configured.payload.'@odata.type' } else { $null }
    $actualType = & $getProperty $remote '@odata.type'

    [pscustomobject]@{
        Id               = & $getProperty $remote 'id'
        DisplayName      = & $getProperty $remote 'displayName'
        PackageOrBundle  = $key
        ActualType       = $actualType
        ConfiguredType   = $desiredType
        TypeMismatch     = [bool]($desiredType -and $actualType -ne $desiredType)
        PublishingState  = & $getProperty $remote 'publishingState'
    }
}

$rows | Sort-Object DisplayName | Format-Table -AutoSize
$mismatches = @($rows | Where-Object TypeMismatch)
if ($mismatches) {
    Write-Host ''
    Write-Warning "$($mismatches.Count) app object(s) have a live @odata.type that does not match configuration:"
    $mismatches | ForEach-Object { Write-Warning "  $($_.DisplayName) [$($_.Id)]: actual '$($_.ActualType)' vs configured '$($_.ConfiguredType)'" }
}

Write-Host ''
Write-Host '--- JSON (for scripted parsing) ---'
$rows | Sort-Object DisplayName | ConvertTo-Json -Depth 4
