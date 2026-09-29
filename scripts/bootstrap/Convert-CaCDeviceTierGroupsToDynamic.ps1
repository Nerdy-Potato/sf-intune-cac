#Requires -Version 7.2
<#
.SYNOPSIS
    Safely convert the existing three CaC device-tier groups to dynamic membership.
.DESCRIPTION
    Preflight reads every tier group, its members, and every tenant Entra device before writing.
    Each assigned group's existing membership is the sole authority for extensionAttribute1.
    Missing tags are stamped and read back before any group changes. The same group IDs and all
    policy assignments are retained. A failed run is resumable; it never deletes groups or rolls
    back tags. Dynamic membership evaluation is eventual: verify actual memberships separately
    before declaring the rollout complete. Empty assigned groups are safe only if no tenant
    device already carries that tier's tag.
    Requires dynamic membership licensing and Graph Device.ReadWrite.All, Group.ReadWrite.All.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $TenantId = $env:AZURE_TENANT_ID,
    [string] $ClientId = $env:AZURE_CLIENT_ID,
    [string] $ConfigPath = (Join-Path $PSScriptRoot '../../config')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DeviceTierTag.Common.ps1')
Assert-CaCDeviceTierIdentity -TenantId $TenantId -ClientId $ClientId
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Import-Module (Join-Path $repoRoot 'src/IntuneCaC/IntuneCaC.psd1') -Force
Connect-CaCGraph -TenantId $TenantId -ClientId $ClientId
$graph = New-CaCDeviceTierGraphInvoker
$config = Get-CaCConfiguration -Path $ConfigPath
$marker = [string] $config.Tenant.managedMarker
if ([string]::IsNullOrWhiteSpace($marker)) { throw 'Managed marker is missing from tenant configuration.' }
$tiers = @('adult', 'teen', 'child')
$groups = @{}
$membersByTier = @{}
$rules = @{}

foreach ($tier in $tiers) {
    $spec = @($config.Groups | Where-Object id -EQ "sg-devices-$tier")
    if ($spec.Count -ne 1 -or $spec[0].memberType -ne 'device') {
        throw "Expected exactly one device group configuration for $tier."
    }
    $name = [string] $spec[0].displayName
    $filter = [uri]::EscapeDataString("displayName eq '$($name.Replace("'", "''"))'")
    $matches = @(((& $graph 'GET' "groups?`$filter=$filter&`$select=id,displayName,mailNickname,description,securityEnabled,mailEnabled,groupTypes,membershipRule,membershipRuleProcessingState,onPremisesSyncEnabled,isAssignableToRole" $null).value))
    if ($matches.Count -ne 1 -or [string] $matches[0].displayName -cne $name) {
        throw "Expected exactly one existing group named '$name'; no groups will be created."
    }
    $group = $matches[0]
    $groupId = [string] (Get-CaCDeviceTierProperty $group 'id')
    $types = @(Get-CaCDeviceTierProperty $group 'groupTypes')
    $rule = "(device.extensionAttribute1 -eq `"$([char]::ToUpperInvariant($tier[0]))$($tier.Substring(1))`")"
    if (-not [guid]::TryParse($groupId, [ref] ([guid]::Empty)) -or
        [string] (Get-CaCDeviceTierProperty $group 'mailNickname') -cne [string] $spec[0].mailNickname -or
        [string] (Get-CaCDeviceTierProperty $group 'description') -notlike "*$marker*" -or
        (Get-CaCDeviceTierProperty $group 'securityEnabled') -cne $true -or
        (Get-CaCDeviceTierProperty $group 'mailEnabled') -cne $false -or
        (Get-CaCDeviceTierProperty $group 'onPremisesSyncEnabled') -eq $true -or
        (Get-CaCDeviceTierProperty $group 'isAssignableToRole') -eq $true -or
        @($types | Where-Object { $_ -ne 'DynamicMembership' }).Count -gt 0) {
        throw "Group '$name' has unexpected ownership or security properties; review it manually."
    }
    if ($types -contains 'DynamicMembership' -and (
            [string] (Get-CaCDeviceTierProperty $group 'membershipRule') -cne $rule -or
            [string] (Get-CaCDeviceTierProperty $group 'membershipRuleProcessingState') -cne 'On')) {
        throw "Group '$name' is dynamic with an unexpected rule or paused processing; review it manually."
    }
    if ($types.Count -eq 0 -and (
            -not [string]::IsNullOrWhiteSpace([string] (Get-CaCDeviceTierProperty $group 'membershipRule')) -or
            [string] (Get-CaCDeviceTierProperty $group 'membershipRuleProcessingState') -notin @('', 'Off'))) {
        throw "Assigned group '$name' has unexpected dynamic membership settings."
    }
    $groups[$tier] = $group
    $rules[$tier] = $rule
    $membersByTier[$tier] = @(((& $graph 'GET' "groups/$groupId/members" $null).value))
}

# Invoke-CaCGraphRequest follows @odata.nextLink internally for all collection reads.
$devices = @(((& $graph 'GET' 'devices?$select=id,extensionAttributes,operatingSystem' $null).value))
$byId = @{}
foreach ($device in $devices) {
    $id = [string] (Get-CaCDeviceTierProperty $device 'id')
    if (-not [guid]::TryParse($id, [ref] ([guid]::Empty)) -or $byId.ContainsKey($id)) {
        throw "Device inventory contains a missing, invalid or duplicate object ID '$id'."
    }
    $byId[$id] = $device
}
$assigned = @{}
$expected = @{}
foreach ($tier in $tiers) {
    $tag = "$([char]::ToUpperInvariant($tier[0]))$($tier.Substring(1))"
    foreach ($member in $membersByTier[$tier]) {
        $id = [string] (Get-CaCDeviceTierProperty $member 'id')
        if ((Get-CaCDeviceTierProperty $member '@odata.type') -ne '#microsoft.graph.device' -or
            -not $byId.ContainsKey($id)) {
            throw "Tier $tier contains a non-device, nested, or unknown member '$id'; review manually."
        }
        if ($assigned.ContainsKey($id)) {
            throw "Device '$id' has duplicate or multiple tier memberships; review manually."
        }
        $assigned[$id] = $tag
    }
}
foreach ($device in $devices) {
    $id = [string] $device.id
    $current = Get-CaCDeviceTierTag $device
    if ($current -and $current -cnotin @('Adult', 'Teen', 'Child')) {
        throw "Device '$id' has an occupied extensionAttribute1 ('$current'); review manually."
    }
    if ($assigned.ContainsKey($id) -and $current -and $current -cne $assigned[$id]) {
        throw "Device '$id' has a tier tag conflicting with its assigned group; review manually."
    }
    if ($current -and -not $assigned.ContainsKey($id)) {
        $tier = $current.ToLowerInvariant()
        if (@(Get-CaCDeviceTierProperty $groups[$tier] 'groupTypes') -notcontains 'DynamicMembership') {
            throw "Tagged device '$id' is outside assigned tier group $tier; review manually before migration."
        }
    }
}

$missing = @($assigned.Keys | Where-Object { -not (Get-CaCDeviceTierTag $byId[$_]) } | Sort-Object)
$pending = @($tiers | Where-Object { @(Get-CaCDeviceTierProperty $groups[$_] 'groupTypes') -notcontains 'DynamicMembership' })
$target = "all three device-tier groups ($($pending.Count) assigned), $($missing.Count) device tags"
if (-not $PSCmdlet.ShouldProcess($target, 'Stamp and verify all missing tags, then convert existing group IDs to dynamic membership')) {
    [pscustomobject]@{ Status = 'WhatIf'; PendingGroups = $pending.Count; PendingTags = $missing.Count }
    return
}
foreach ($id in $missing) {
    & $graph 'PATCH' "devices/$id" @{ extensionAttributes = @{ extensionAttribute1 = $assigned[$id] } } | Out-Null
    $readback = & $graph 'GET' "devices/${id}?`$select=id,extensionAttributes" $null
    if ([string] (Get-CaCDeviceTierProperty $readback 'id') -ne $id -or
        (Get-CaCDeviceTierTag $readback) -cne $assigned[$id]) {
        throw "Device '$id' tag write was not verified; no groups have been changed. Inspect and rerun."
    }
}
foreach ($tier in $pending) {
    $id = [string] $groups[$tier].id
    & $graph 'PATCH' "groups/$id" @{
        groupTypes = @('DynamicMembership')
        membershipRule = $rules[$tier]
        membershipRuleProcessingState = 'On'
    } | Out-Null
    $readback = & $graph 'GET' "groups/${id}?`$select=id,groupTypes,membershipRule,membershipRuleProcessingState" $null
    if ([string] $readback.id -ne $id -or
        @(Get-CaCDeviceTierProperty $readback 'groupTypes') -notcontains 'DynamicMembership' -or
        [string] $readback.membershipRule -cne $rules[$tier] -or
        [string] $readback.membershipRuleProcessingState -cne 'On') {
        throw "Group '$tier' conversion was not verified. Inspect and rerun; no rollback was attempted."
    }
}
[pscustomobject]@{
    Status = 'ConfigurationVerifiedMembershipPending'
    GroupIds = @($tiers | ForEach-Object { [string] $groups[$_].id })
    TaggedDevices = $missing.Count
    ConvertedGroups = $pending.Count
}
