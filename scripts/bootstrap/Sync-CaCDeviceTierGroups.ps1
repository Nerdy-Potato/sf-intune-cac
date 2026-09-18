#Requires -Version 7.2
<#
.SYNOPSIS
    Adds enrolled Windows devices to their primary user's tier device group.
.DESCRIPTION
    `CaC-Devices-Adult`/`-Teen`/`-Child` are explicit-membership security groups (see
    config/identity/groups.json): this repository creates them but, by design, never manages their
    device membership through the normal plan/apply reconciliation loop (Get-CaCConfiguration
    always returns an empty desired member list for a `memberType: device` group). Historically that
    meant a human had to remember to add every newly enrolled device by hand - and when that step
    was missed, device-scoped policies assigned to those groups (most importantly the "SF Adults
    Local Admin" / "SF Teens Local Admin" Settings Catalog policies and both Windows LAPS policies)
    silently never applied to the device.

    This script closes that gap without touching the config-as-device plan/apply engine: it reads
    each enrolled Windows device's primary user, looks up that user's tier from
    config/identity/users.json (the single source of truth for tier placement), and adds the
    device to the matching `CaC-Devices-<Tier>` group if it is not already a member.

    It is intentionally additive-only. If a device is already sitting in a *different* tier's
    device group (for example, after a birthday moves someone from teen to adult) it is reported as
    a conflict but never automatically removed - reassigning a device across tiers is a deliberate,
    reviewed action, consistent with how this repository treats every other membership change.

    Devices whose primary user is not on the adult/teen/child tier (admin, break-glass, or a UPN
    that does not match any account in users.json) are skipped and reported, never guessed at.

    Reuses this repository's standard GitHub Actions OIDC authentication path: import the
    IntuneCaC module, call Connect-CaCGraph, and issue every Graph request through the
    module-scoped Invoke-CaCGraphRequest helper.
.EXAMPLE
    ./scripts/bootstrap/Sync-CaCDeviceTierGroups.ps1 -WhatIf
.EXAMPLE
    ./scripts/bootstrap/Sync-CaCDeviceTierGroups.ps1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [string] $TenantId = $env:AZURE_TENANT_ID,

    [Parameter()]
    [string] $ClientId = $env:AZURE_CLIENT_ID,

    [Parameter()]
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../config')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $TenantId -or -not $ClientId) {
    throw (
        'TenantId and ClientId are required. Run this script from GitHub Actions with ' +
        'AZURE_TENANT_ID and AZURE_CLIENT_ID set for the OIDC-backed Graph identity.'
    )
}

# Only these tiers have a corresponding device group; admin/excluded accounts are deliberately
# never auto-enrolled into a tier device group.
$TierGroupDisplayNames = @{
    adult = 'CaC-Devices-Adult'
    teen  = 'CaC-Devices-Teen'
    child = 'CaC-Devices-Child'
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

$configuration = Get-CaCConfiguration -Path $ConfigPath

# UPN (lowercased) -> tier, restricted to the three tiers that own a device group.
$tierByUpn = @{}
foreach ($user in $configuration.Users) {
    if ($TierGroupDisplayNames.ContainsKey([string] $user.tier)) {
        $tierByUpn[([string] $user.upn).ToLowerInvariant()] = [string] $user.tier
    }
}

# Resolve the three device group ids and their current device members once, up front.
$groupsByTier = @{}
foreach ($tier in $TierGroupDisplayNames.Keys) {
    $displayName = $TierGroupDisplayNames[$tier]
    $encodedName = [System.Uri]::EscapeDataString($displayName)
    $matches = @((& $graphInvoker 'GET' "groups?`$filter=displayName eq '${encodedName}'&`$select=id,displayName").value)

    if ($matches.Count -ne 1) {
        throw "Expected exactly one group named '$displayName', found $($matches.Count). Refusing to guess."
    }

    $groupId = [string] $matches[0].id
    $members = @((& $graphInvoker 'GET' "groups/${groupId}/members?`$select=id").value | ForEach-Object { [string] $_.id })

    $groupsByTier[$tier] = [pscustomobject]@{
        DisplayName = $displayName
        Id          = $groupId
        MemberIds   = [System.Collections.Generic.HashSet[string]]::new([string[]] $members)
    }
}

# Which tier's device group (if any) currently contains a given device object id - used to detect
# a device parked in the wrong tier's group without ever removing it automatically.
function Get-CaCDeviceCurrentTier {
    param([Parameter(Mandatory)][string] $DeviceObjectId)

    foreach ($tier in $groupsByTier.Keys) {
        if ($groupsByTier[$tier].MemberIds.Contains($DeviceObjectId)) {
            return $tier
        }
    }

    return $null
}

$windowsDevices = @((& $graphInvoker 'GET' "deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=id,deviceName,azureADDeviceId,userPrincipalName").value)

$results = [System.Collections.Generic.List[object]]::new()

foreach ($device in $windowsDevices) {
    $deviceName = [string] $device.deviceName
    $azureAdDeviceId = [string] $device.azureADDeviceId
    $upn = [string] $device.userPrincipalName

    if ([string]::IsNullOrWhiteSpace($azureAdDeviceId) -or $azureAdDeviceId -eq '00000000-0000-0000-0000-000000000000') {
        $results.Add([pscustomobject]@{ Device = $deviceName; Status = 'Skipped'; Reason = 'No Entra device id (not Entra-joined/registered).' })
        continue
    }

    if ([string]::IsNullOrWhiteSpace($upn)) {
        $results.Add([pscustomobject]@{ Device = $deviceName; Status = 'Skipped'; Reason = 'No primary user on the managed device record.' })
        continue
    }

    $tier = $tierByUpn[$upn.ToLowerInvariant()]
    if (-not $tier) {
        $results.Add([pscustomobject]@{ Device = $deviceName; Status = 'Skipped'; Reason = "Primary user '$upn' is not on the adult/teen/child tier." })
        continue
    }

    $directoryDevice = @((& $graphInvoker 'GET' "devices?`$filter=deviceId eq '${azureAdDeviceId}'&`$select=id,displayName").value) | Select-Object -First 1
    if (-not $directoryDevice) {
        $results.Add([pscustomobject]@{ Device = $deviceName; Status = 'Skipped'; Reason = 'No matching Entra device object was found yet.' })
        continue
    }

    $deviceObjectId = [string] $directoryDevice.id
    $targetGroup = $groupsByTier[$tier]

    $currentTier = Get-CaCDeviceCurrentTier -DeviceObjectId $deviceObjectId
    if ($currentTier -and $currentTier -ne $tier) {
        $results.Add([pscustomobject]@{
                Device = $deviceName
                Status = 'Conflict'
                Reason = "Already a member of $($groupsByTier[$currentTier].DisplayName) but primary user '$upn' is tier '$tier'. Not removing automatically - review and move manually."
            })
        continue
    }

    if ($targetGroup.MemberIds.Contains($deviceObjectId)) {
        $results.Add([pscustomobject]@{ Device = $deviceName; Status = 'AlreadyPresent'; Reason = $targetGroup.DisplayName })
        continue
    }

    if ($PSCmdlet.ShouldProcess("$deviceName ($upn, tier: $tier)", "Add to $($targetGroup.DisplayName)")) {
        $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/${deviceObjectId}" }
        & $graphInvoker 'POST' "groups/$($targetGroup.Id)/members/`$ref" $body | Out-Null
        $targetGroup.MemberIds.Add($deviceObjectId) | Out-Null
        $results.Add([pscustomobject]@{ Device = $deviceName; Status = 'Added'; Reason = $targetGroup.DisplayName })
    }
}

$results | Sort-Object -Property Status, Device | Format-Table -Property Device, Status, Reason -AutoSize | Out-Host

$summary = $results | Group-Object -Property Status | ForEach-Object { "$($_.Name): $($_.Count)" }
Write-Host ''
Write-Host "Summary: $($summary -join ', ')"

return $results
