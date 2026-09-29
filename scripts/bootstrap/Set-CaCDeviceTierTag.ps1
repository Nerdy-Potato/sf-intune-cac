#Requires -Version 7.2
<#
.SYNOPSIS
    Administrator-only assignment of a device tier via Entra extensionAttribute1.
.DESCRIPTION
    Supply an exact Entra device object ID, not a display name or deviceId. PATCH changes only
    extensionAttribute1; other extension attributes are preserved. Dynamic group membership
    evaluation is asynchronous. Requires Graph Device.ReadWrite.All.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ [guid]::TryParse($_, [ref] ([guid]::Empty)) })]
    [string] $DeviceObjectId,
    [Parameter(Mandatory)]
    [ValidateSet('Adult', 'Teen', 'Child')]
    [string] $Tier,
    [switch] $AllowTierChange,
    [string] $TenantId = $env:AZURE_TENANT_ID,
    [string] $ClientId = $env:AZURE_CLIENT_ID
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DeviceTierTag.Common.ps1')
Assert-CaCDeviceTierIdentity -TenantId $TenantId -ClientId $ClientId
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Import-Module (Join-Path $repoRoot 'src/IntuneCaC/IntuneCaC.psd1') -Force
Connect-CaCGraph -TenantId $TenantId -ClientId $ClientId
$graph = New-CaCDeviceTierGraphInvoker
$id = ([guid] $DeviceObjectId).ToString()
$device = & $graph 'GET' "devices/${id}?`$select=id,extensionAttributes" $null
if ([string] (Get-CaCDeviceTierProperty $device 'id') -ne $id) {
    throw "Entra device object '$id' was not returned exactly; no tag changed."
}
$current = Get-CaCDeviceTierTag $device
if ($current -and $current -cnotin @('Adult', 'Teen', 'Child')) {
    throw "Device '$id' has extensionAttribute1 '$current', which is not one of the supported tiers Adult, Teen, or Child. This script never overwrites an attribute value it does not own, and -AllowTierChange does not permit it. Clear the value deliberately outside this script first."
}
if ($current -cne $Tier -and $current -and -not $AllowTierChange) {
    throw "Device '$id' already has extensionAttribute1 '$current'. Use -AllowTierChange only after reviewing the tier reassignment."
}
if ($current -cne $Tier -and $PSCmdlet.ShouldProcess($id, "Set extensionAttribute1 from '$current' to '$Tier'")) {
    & $graph 'PATCH' "devices/$id" @{ extensionAttributes = @{ extensionAttribute1 = $Tier } } | Out-Null
    $readback = & $graph 'GET' "devices/${id}?`$select=id,extensionAttributes" $null
    if ([string] (Get-CaCDeviceTierProperty $readback 'id') -ne $id -or
        (Get-CaCDeviceTierTag $readback) -cne $Tier) {
        throw "Device '$id' tag write was not verified; inspect the device before retrying."
    }
    $current = $Tier
}
[pscustomobject]@{
    DeviceObjectId = $id
    Tier = $Tier
    Status = if ($WhatIfPreference) { 'WhatIf' } elseif ($current -ceq $Tier) { 'TagVerifiedMembershipPending' } else { 'NotChanged' }
}
