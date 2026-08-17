#Requires -Version 7.2
<#
.SYNOPSIS
    Read-only diagnostic: lists every Intune Settings Catalog policy
    (deviceManagement/configurationPolicies), its full settings payload, and its assignments.
.DESCRIPTION
    Used to capture the exact live JSON schema of a policy created manually via the Intune portal
    (for example, an Endpoint Security > Account Protection > "Local user group membership"
    policy) so that config/*.json can be written to describe reality precisely, instead of
    guessing at settingDefinitionId strings or payload shape. Read-only; issues no writes. Reuses
    the same OIDC auth path as the other bootstrap scripts.
.EXAMPLE
    ./scripts/bootstrap/Get-CaCConfigurationPolicyInventory.ps1
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

$policies = @((& $graphInvoker 'GET' 'deviceManagement/configurationPolicies' $null).value | Where-Object { $_ })

$results = foreach ($policy in $policies) {
    $policyId = $policy.id
    $settingsResponse = & $graphInvoker 'GET' "deviceManagement/configurationPolicies/${policyId}/settings" $null
    $assignmentResponse = & $graphInvoker 'GET' "deviceManagement/configurationPolicies/${policyId}/assignments" $null

    $assignmentSummaries = @()
    foreach ($assignment in @($assignmentResponse.value)) {
        $target = $assignment.target
        $groupId = $null
        if ($target -and $target.PSObject.Properties.Match('groupId').Count -gt 0) {
            $groupId = $target.groupId
        }
        $targetType = if ($target) { [string] $target.'@odata.type' } else { $null }
        $assignmentSummaries += "$targetType|$groupId"
    }

    [pscustomobject]@{
        Id              = $policyId
        Name            = $policy.name
        Description     = $policy.description
        Platforms       = $policy.platforms
        Technologies    = $policy.technologies
        Settings        = $settingsResponse.value
        Assignments     = $assignmentSummaries
    }
}

$results | Select-Object Id, Name, Platforms, Technologies | Format-Table -AutoSize

Write-Host ''
Write-Host '--- JSON (for scripted parsing) ---'
$results | ConvertTo-Json -Depth 20
