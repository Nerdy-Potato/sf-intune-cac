#Requires -Version 7.2
<#
.SYNOPSIS
    Wipes a user's Intune MAM managed app registrations for a specific device tag.
.DESCRIPTION
    Remediation for the MAM SDK "This app is already managed with account X. Only a single managed
    account is allowed for this app." loop, once device-side fixes (clearing the affected app's
    storage/cache and Company Portal's storage/cache) have not resolved it. This means the
    tenant-side managedAppRegistration record is orphaned/stale.

    Calls POST /users/{id}/wipeManagedAppRegistrationsByDeviceTag, Microsoft's documented action for
    exactly this scenario. IMPORTANT: this wipes every managed app registration sharing the given
    deviceTag for that user - i.e. every corporate-managed app container on that one device, not
    just the app that was showing the error - since the MAM SDK correlates registrations on the same
    device by deviceTag. It does not touch the user's account, mailbox, files, personal app data, or
    other devices. Apps re-register (and mail/files re-sync from the cloud) the next time each app is
    reopened and signed in.

    Run Get-CaCManagedAppRegistrations.ps1 first to find the deviceTag for the stuck registration.

    The script intentionally reuses this repository's GitHub Actions OIDC authentication path:
    import the IntuneCaC module, call Connect-CaCGraph, and issue Graph requests through the
    module-scoped Invoke-CaCGraphRequest helper. Run it from GitHub Actions with
    permissions: id-token: write plus AZURE_TENANT_ID and AZURE_CLIENT_ID environment variables.

    Microsoft guidance:
    https://learn.microsoft.com/graph/api/intune-mam-user-wipemanagedappregistrationsbydevicetag
.EXAMPLE
    ./scripts/bootstrap/Invoke-CaCManagedAppWipe.ps1 -Upn robin@spaid.family -DeviceTag 'abc123' -WhatIf
.EXAMPLE
    ./scripts/bootstrap/Invoke-CaCManagedAppWipe.ps1 -Upn robin@spaid.family -DeviceTag 'abc123'
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Upn,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $DeviceTag,

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
$normalizedDeviceTag = $DeviceTag.Trim()
if ([string]::IsNullOrWhiteSpace($normalizedUpn)) {
    throw 'Upn may not be empty.'
}
if ([string]::IsNullOrWhiteSpace($normalizedDeviceTag)) {
    throw 'DeviceTag may not be empty.'
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

$registrationsResponse = & $graphInvoker -Method 'GET' -Uri "users/$($user.id)/managedAppRegistrations"
$matchingRegistrations = @(@($registrationsResponse.value) | Where-Object { $_.deviceTag -eq $normalizedDeviceTag })

if (-not $matchingRegistrations.Count) {
    Write-Warning (
        "No managed app registrations found for $normalizedUpn with deviceTag '$normalizedDeviceTag'. " +
        'Re-run Get-CaCManagedAppRegistrations.ps1 to confirm the current deviceTag before retrying.'
    )
}
else {
    Write-Host "Found $($matchingRegistrations.Count) registration(s) for $normalizedUpn with deviceTag '$normalizedDeviceTag':"
    foreach ($registration in $matchingRegistrations) {
        $identifier = $registration.appIdentifier
        $appId = if ($identifier.packageId) { [string] $identifier.packageId } else { [string] $identifier.bundleId }
        Write-Host "  - $appId (device: $($registration.deviceName), last sync: $($registration.lastSyncDateTime))"
    }
}

if ($PSCmdlet.ShouldProcess(
        "$($user.displayName) [$($user.id)], deviceTag '$normalizedDeviceTag'",
        'Wipe managed app registrations by device tag')) {
    & $graphInvoker -Method 'POST' -Uri "users/$($user.id)/wipeManagedAppRegistrationsByDeviceTag" -Body @{ deviceTag = $normalizedDeviceTag } | Out-Null
    Write-Host "Wipe issued for $normalizedUpn, deviceTag '$normalizedDeviceTag'. Apps on that device will re-register (and re-sync data from the cloud) the next time each is reopened and signed in."
}
