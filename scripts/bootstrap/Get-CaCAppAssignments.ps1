#Requires -Version 7.2
<#
.SYNOPSIS
    Read-only diagnostic: lists group assignments for specific Intune mobileApp object IDs.
.DESCRIPTION
    One-off helper used to confirm which of two duplicate app objects (same packageId, different
    @odata.type) actually carry group assignments before either is deleted. Read-only; issues no
    writes. Reuses the same OIDC auth path as the other bootstrap scripts.
.EXAMPLE
    ./scripts/bootstrap/Get-CaCAppAssignments.ps1 -AppId @('id1','id2')
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]] $AppId,

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

$results = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($rawAppId in $AppId) {
    $normalizedAppId = ([string] $rawAppId).Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedAppId)) {
        throw 'AppId values may not be empty.'
    }

    $app = & $graphInvoker -Method 'GET' -Uri "deviceAppManagement/mobileApps/${normalizedAppId}?`$select=id,displayName,`$odata.type,publishingState"
    $assignmentResponse = & $graphInvoker -Method 'GET' -Uri "deviceAppManagement/mobileApps/${normalizedAppId}/assignments"

    $assignmentSummaries = @()
    foreach ($assignment in @($assignmentResponse.value)) {
        $target = $assignment.target
        $groupId = $null
        if ($target -and $target.PSObject.Properties.Match('groupId').Count -gt 0) {
            $groupId = $target.groupId
        }
        $targetType = if ($target) { [string] $target.'@odata.type' } else { $null }
        $assignmentSummaries += "$($assignment.intent)|$targetType|$groupId"
    }

    $results.Add([pscustomobject]@{
            Id              = $normalizedAppId
            DisplayName     = [string] $app.displayName
            ActualType      = [string] $app.'@odata.type'
            PublishingState = [string] $app.publishingState
            AssignmentCount = $assignmentSummaries.Count
            Assignments     = ($assignmentSummaries -join '; ')
        })
}

$results | Format-Table -AutoSize

Write-Host ''
Write-Host '--- JSON (for scripted parsing) ---'
$results | ConvertTo-Json -Depth 6
