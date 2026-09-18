#Requires -Version 7.2
<#
.SYNOPSIS
    Sets the Windows Autopilot Group Tag on an already hardware-hash-registered device, so the
    dynamic CaC-Devices-<Tier> group picks it up.
.DESCRIPTION
    Windows Autopilot devices carry a Group Tag (Entra's `OrderID` device physical id) that the
    CaC-Devices-Adult/Teen/Child dynamic groups match on - see
    Convert-CaCDeviceTierGroupsToDynamic.ps1. New devices should have their Group Tag set at
    hardware-hash registration time (the Autopilot CSV/portal import already has a Group Tag
    column - see docs/enterprise-child-enrollment.md). This script exists for the case where that
    was missed, or a device needs to move tiers: it calls the Autopilot device identity's
    updateDeviceProperties action to set/correct the tag on an already-registered device.

    Entra ID re-evaluates the dynamic group rule automatically after the tag changes; no group
    membership call is made by this script.
.PARAMETER SerialNumber
    The device's serial number, exactly as it appears in Intune > Devices > Enrollment >
    Windows Autopilot devices.
.PARAMETER Tier
    Which tier's Group Tag to apply (adult, teen, or child).
.EXAMPLE
    ./scripts/bootstrap/Set-CaCAutopilotGroupTag.ps1 -SerialNumber '5CD1234ABC' -Tier adult
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [string] $SerialNumber,

    [Parameter(Mandatory)]
    [ValidateSet('adult', 'teen', 'child')]
    [string] $Tier,

    [Parameter()]
    [string] $TenantId = $env:AZURE_TENANT_ID,

    [Parameter()]
    [string] $ClientId = $env:AZURE_CLIENT_ID
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LocalObjectProperty {
    param(
        [Parameter()] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    if (-not $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject[$Name] }

    $property = $InputObject.PSObject.Properties[$Name]
    if (-not $property) { return $null }

    return $property.Value
}

function ConvertTo-ODataStringLiteral {
    param(
        [Parameter(Mandatory)] [string] $Value
    )

    return $Value.Replace("'", "''")
}

if (-not $TenantId -or -not $ClientId) {
    throw (
        'TenantId and ClientId are required. Run this script from GitHub Actions with ' +
        'AZURE_TENANT_ID and AZURE_CLIENT_ID set for the OIDC-backed Graph identity.'
    )
}

# Keep in sync with Convert-CaCDeviceTierGroupsToDynamic.ps1 and docs/enterprise-child-enrollment.md.
$GroupTagByTier = @{
    adult = 'CaC-Adult'
    teen  = 'CaC-Teen'
    child = 'CaC-Child'
}
$groupTag = $GroupTagByTier[$Tier]

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

$filter = [System.Uri]::EscapeDataString("contains(serialNumber,'$(ConvertTo-ODataStringLiteral -Value $SerialNumber)')")
$matches = @((& $graphInvoker 'GET' "deviceManagement/windowsAutopilotDeviceIdentities?`$filter=$filter" $null).value)

if (-not $matches) {
    throw "No Windows Autopilot device identity found with serial number '$SerialNumber'. Confirm it has been hardware-hash registered."
}
if ($matches.Count -gt 1) {
    throw "More than one Windows Autopilot device identity matched serial number '$SerialNumber'; refusing to guess."
}

$device = $matches[0]
$currentTag = [string] (Get-LocalObjectProperty -InputObject $device -Name 'groupTag')

if ($currentTag -eq $groupTag) {
    Write-Host "Device $SerialNumber ($($device.id)) already has Group Tag '$groupTag'; nothing to do."
    return
}

Write-Host "Device $SerialNumber ($($device.id)): Group Tag '$currentTag' -> '$groupTag' (tier: $Tier)"

if ($PSCmdlet.ShouldProcess("$SerialNumber [$($device.id)]", "Set Windows Autopilot Group Tag to '$groupTag'")) {
    & $graphInvoker 'POST' "deviceManagement/windowsAutopilotDeviceIdentities/$($device.id)/updateDeviceProperties" @{ groupTag = $groupTag } | Out-Null
    Write-Host 'Done. Entra ID will re-evaluate the dynamic CaC-Devices group membership automatically (usually within minutes).'
}
