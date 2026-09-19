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

function Get-LocalGraphCollection {
    param([Parameter(Mandatory)][string] $Uri)

    $items = @()
    $nextUri = $Uri

    while ($nextUri) {
        $response = & $graphInvoker 'GET' $nextUri $null
        foreach ($item in @($response.value)) {
            $items += $item
        }
        $nextUri = Get-LocalObjectProperty -InputObject $response -Name '@odata.nextLink'
    }

    return @($items)
}

function Get-ChoiceSettingValue {
    param([Parameter()] $Setting)

    $settingInstance = Get-LocalObjectProperty -InputObject $Setting -Name 'settingInstance'
    if (-not $settingInstance) { return $null }

    $choice = Get-LocalObjectProperty -InputObject $settingInstance -Name 'choiceSettingValue'
    if (-not $choice) { return $null }

    return Get-LocalObjectProperty -InputObject $choice -Name 'value'
}

$profiles = Get-LocalGraphCollection -Uri 'deviceManagement/windowsAutopilotDeploymentProfiles'

$classicResults = foreach ($profile in $profiles) {
    $oobe = Get-LocalObjectProperty -InputObject $profile -Name 'outOfBoxExperienceSettings'
    if (-not $oobe) {
        $oobe = Get-LocalObjectProperty -InputObject $profile -Name 'outOfBoxExperienceSetting'
    }

    [pscustomobject]@{
        Kind              = 'windowsAutopilotDeploymentProfile'
        DisplayName       = Get-LocalObjectProperty -InputObject $profile -Name 'displayName'
        Id                = Get-LocalObjectProperty -InputObject $profile -Name 'id'
        UserType          = Get-LocalObjectProperty -InputObject $oobe -Name 'userType'
        DeviceUsageType   = Get-LocalObjectProperty -InputObject $oobe -Name 'deviceUsageType'
        TemplateId        = $null
        RawAccountSetting = $null
        Priority          = $null
        Assignments       = $null
        LastModified      = Get-LocalObjectProperty -InputObject $profile -Name 'lastModifiedDateTime'
    }
}

$configurationPolicies = Get-LocalGraphCollection -Uri 'deviceManagement/configurationPolicies'
$devicePreparationPolicies = @($configurationPolicies | Where-Object {
        $templateReference = Get-LocalObjectProperty -InputObject $_ -Name 'templateReference'
        $templateId = Get-LocalObjectProperty -InputObject $templateReference -Name 'templateId'
        $templateDisplayName = Get-LocalObjectProperty -InputObject $templateReference -Name 'templateDisplayName'

        $templateId -match 'autopilot|devicepreparation|dpp' -or
        $templateDisplayName -match 'Autopilot|Device Preparation'
    })

function Get-AssignmentTargetSummary {
    param([Parameter()] $Assignments)

    $summaries = foreach ($assignment in @($Assignments)) {
        $target = Get-LocalObjectProperty -InputObject $assignment -Name 'target'
        $odataType = Get-LocalObjectProperty -InputObject $target -Name '@odata.type'
        $groupId = Get-LocalObjectProperty -InputObject $target -Name 'groupId'
        if ($groupId) { "$odataType($groupId)" } else { $odataType }
    }

    return ($summaries -join '; ')
}

$devicePreparationResults = foreach ($policy in $devicePreparationPolicies) {
    $policyId = Get-LocalObjectProperty -InputObject $policy -Name 'id'
    $settings = Get-LocalGraphCollection -Uri "deviceManagement/configurationPolicies/$policyId/settings"
    $fullPolicy = & $graphInvoker 'GET' "deviceManagement/configurationPolicies/$policyId" $null
    $assignments = Get-LocalGraphCollection -Uri "deviceManagement/configurationPolicies/$policyId/assignments"

    $accountTypeSetting = $settings | Where-Object {
        $instance = Get-LocalObjectProperty -InputObject $_ -Name 'settingInstance'
        $definitionId = Get-LocalObjectProperty -InputObject $instance -Name 'settingDefinitionId'
        $definitionId -match 'account|user'
    } | Select-Object -First 1

    $rawAccountSetting = Get-ChoiceSettingValue -Setting $accountTypeSetting
    $userType = switch -Regex ($rawAccountSetting) {
        'administrator|admin' { 'administrator'; break }
        'accountype_0|accounttype_0' { 'administrator'; break }
        'standard' { 'standard'; break }
        'accountype_1|accounttype_1' { 'standard'; break }
        default { $rawAccountSetting }
    }

    $templateReference = Get-LocalObjectProperty -InputObject $policy -Name 'templateReference'

    [pscustomobject]@{
        Kind              = 'configurationPolicy'
        DisplayName       = Get-LocalObjectProperty -InputObject $policy -Name 'name'
        Id                = $policyId
        UserType          = $userType
        DeviceUsageType   = $null
        TemplateId        = Get-LocalObjectProperty -InputObject $templateReference -Name 'templateId'
        RawAccountSetting = $rawAccountSetting
        Priority          = Get-LocalObjectProperty -InputObject $fullPolicy -Name 'priority'
        Assignments       = Get-AssignmentTargetSummary -Assignments $assignments
        LastModified      = Get-LocalObjectProperty -InputObject $policy -Name 'lastModifiedDateTime'
    }
}

$results = @($classicResults) + @($devicePreparationResults)

if (-not $results) {
    Write-Host 'No classic Windows Autopilot deployment profiles or Autopilot Device Preparation configuration policies were found.'
}
else {
    $results | Sort-Object Kind, DisplayName | Format-Table -AutoSize
}

Write-Host ''
Write-Host '--- JSON (for scripted parsing) ---'
$results | Sort-Object DisplayName | ConvertTo-Json -Depth 10
