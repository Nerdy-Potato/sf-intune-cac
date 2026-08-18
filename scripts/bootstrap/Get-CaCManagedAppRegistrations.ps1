#Requires -Version 7.2
<#
.SYNOPSIS
    Read-only diagnostic: lists a user's Intune MAM managed app registrations.
.DESCRIPTION
    One-off helper for troubleshooting the classic MAM SDK "This app is already managed with
    account X. Only a single managed account is allowed for this app." loop. That error means the
    tenant-side managedAppRegistration record for the user/app/device is stale or orphaned - most
    often after a device reset, app reinstall, or Company Portal data clear that did not also clear
    the affected app's own storage. This script lists the user's registrations so the specific
    stuck one (matched by device or package/bundle id) can be identified before anything is wiped
    with Invoke-CaCManagedAppWipe.ps1.

    Read-only; issues no writes. Reuses the same OIDC auth path as the other bootstrap scripts.
.EXAMPLE
    ./scripts/bootstrap/Get-CaCManagedAppRegistrations.ps1 -Upn robin@spaid.family
.EXAMPLE
    ./scripts/bootstrap/Get-CaCManagedAppRegistrations.ps1 -Upn robin@spaid.family -AppIdFilter outlook
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Upn,

    [Parameter()]
    [string] $AppIdFilter,

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

$normalizedUpn = $Upn.Trim()
if ([string]::IsNullOrWhiteSpace($normalizedUpn)) {
    throw 'Upn may not be empty.'
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

$user = & $graphInvoker -Method 'GET' -Uri "users/${normalizedUpn}?`$select=id,displayName,userPrincipalName"
if (-not $user -or -not $user.id) {
    throw "Could not resolve user '$normalizedUpn'."
}

Write-Host "Resolved $normalizedUpn -> $($user.displayName) [$($user.id)]"

$registrationsResponse = & $graphInvoker -Method 'GET' -Uri "users/$($user.id)/managedAppRegistrations"
$registrations = @($registrationsResponse.value)

if ($AppIdFilter) {
    $registrations = @($registrations | Where-Object {
            $identifier = $_.appIdentifier
            $needle = [string] $AppIdFilter
            ($identifier.packageId -and $identifier.packageId -match [regex]::Escape($needle)) -or
            ($identifier.bundleId -and $identifier.bundleId -match [regex]::Escape($needle))
        })
}

$results = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($registration in $registrations) {
    $identifier = $registration.appIdentifier
    $appId = if ($identifier.packageId) { [string] $identifier.packageId } else { [string] $identifier.bundleId }

    $results.Add([pscustomobject]@{
            Id                 = [string] $registration.id
            AppIdentifier      = $appId
            DeviceType         = [string] $registration.deviceType
            DeviceName         = [string] $registration.deviceName
            DeviceTag          = [string] $registration.deviceTag
            ApplicationVersion = [string] $registration.applicationVersion
            CreatedDateTime    = [string] $registration.createdDateTime
            LastSyncDateTime   = [string] $registration.lastSyncDateTime
            FlaggedReasons     = (@($registration.flaggedReasons) -join '; ')
        })
}

if (-not $results.Count) {
    Write-Warning "No managed app registrations found for $normalizedUpn (after any -AppIdFilter)."
}

$results | Format-Table -AutoSize

Write-Host ''
Write-Host '--- JSON (for scripted parsing) ---'
$results | ConvertTo-Json -Depth 6
