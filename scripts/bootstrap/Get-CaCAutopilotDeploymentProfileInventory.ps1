#Requires -Version 7.2
<#
.SYNOPSIS
    Lists Windows Autopilot deployment profiles and their OOBE user account type.
.DESCRIPTION
    Read-only diagnostic used before reimaging a device through Autopilot. The OOBE
    outOfBoxExperienceSettings.userType value controls whether the user joining the device is
    added to the local Administrators group (`administrator`) or created as a standard user
    (`standard`).
.EXAMPLE
    ./scripts/bootstrap/Get-CaCAutopilotDeploymentProfileInventory.ps1
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

if (-not $TenantId -or -not $ClientId) {
    throw (
        'TenantId and ClientId are required. Run this script from GitHub Actions with ' +
        'AZURE_TENANT_ID and AZURE_CLIENT_ID set for the OIDC-backed Graph identity.'
    )
}

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../..')).Path
Import-Module -Name (Join-Path $repoRoot 'src/IntuneCaC/IntuneCaC.psd1') -Force

Connect-CaCGraph -TenantId $TenantId -ClientId $ClientId -ReadOnly

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

$profiles = @((& $graphInvoker 'GET' 'deviceManagement/windowsAutopilotDeploymentProfiles' $null).value)

$results = foreach ($profile in $profiles) {
    $oobe = Get-LocalObjectProperty -InputObject $profile -Name 'outOfBoxExperienceSettings'
    if (-not $oobe) {
        $oobe = Get-LocalObjectProperty -InputObject $profile -Name 'outOfBoxExperienceSetting'
    }

    [pscustomobject]@{
        DisplayName       = Get-LocalObjectProperty -InputObject $profile -Name 'displayName'
        Id                = Get-LocalObjectProperty -InputObject $profile -Name 'id'
        UserType          = Get-LocalObjectProperty -InputObject $oobe -Name 'userType'
        DeviceUsageType   = Get-LocalObjectProperty -InputObject $oobe -Name 'deviceUsageType'
        LastModified      = Get-LocalObjectProperty -InputObject $profile -Name 'lastModifiedDateTime'
    }
}

$results | Sort-Object DisplayName | Format-Table -AutoSize

Write-Host ''
Write-Host '--- JSON (for scripted parsing) ---'
$results | Sort-Object DisplayName | ConvertTo-Json -Depth 10
