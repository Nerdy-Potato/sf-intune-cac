#Requires -Version 7.2
<#
.SYNOPSIS
    Deletes Intune mobile app objects that are stuck in Microsoft Graph publishingState 'processing'.
.DESCRIPTION
    This is a one-time remediation for store app objects that remain in Microsoft Graph
    publishingState 'processing' well past the ~1 hour window where Microsoft documents normal
    publishing to complete in a few minutes. When that backend sync does not clear on its own,
    Microsoft's guidance is to delete the stuck app object and let automation recreate it.

    The script intentionally reuses this repository's GitHub Actions OIDC authentication path:
    import the IntuneCaC module, call Connect-CaCGraph, and issue Graph requests through the
    module-scoped Invoke-CaCGraphRequest helper. Run it from GitHub Actions with
    permissions: id-token: write plus AZURE_TENANT_ID and AZURE_CLIENT_ID environment variables.

    Microsoft guidance:
    https://learn.microsoft.com/mem/intune/apps/apps-add
.EXAMPLE
    ./scripts/bootstrap/Remove-CaCStuckApp.ps1 -AppId 0016c1fd-2abc-4b5c-8d37-a6da9ba650d5 -WhatIf
.EXAMPLE
    ./scripts/bootstrap/Remove-CaCStuckApp.ps1 -AppId @(
        '0016c1fd-2abc-4b5c-8d37-a6da9ba650d5',
        '2c3b96cc-b476-4d12-877d-1fff8dfa28f5'
    )
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
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

foreach ($rawAppId in $AppId) {
    $normalizedAppId = [string] $rawAppId
    if ([string]::IsNullOrWhiteSpace($normalizedAppId)) {
        throw 'AppId values may not be empty.'
    }

    $normalizedAppId = $normalizedAppId.Trim()
    $app = & $graphInvoker -Method 'GET' -Uri "deviceAppManagement/mobileApps/${normalizedAppId}?`$select=id,displayName,publishingState"

    $displayName = if ([string]::IsNullOrWhiteSpace([string] $app.displayName)) {
        $normalizedAppId
    }
    else {
        [string] $app.displayName
    }
    $publishingState = [string] $app.publishingState

    Write-Host "Resolved $normalizedAppId -> $displayName (publishingState: $publishingState)"
    if ($publishingState -ne 'processing') {
        Write-Warning (
            "App '$displayName' is currently '$publishingState', not 'processing'. " +
            'Continue only if this delete/recreate remediation is still intended.'
        )
    }

    if ($PSCmdlet.ShouldProcess("$displayName [$normalizedAppId]", 'Delete Intune mobile app object')) {
        & $graphInvoker -Method 'DELETE' -Uri "deviceAppManagement/mobileApps/${normalizedAppId}" | Out-Null
        Write-Host "Deleted $displayName [$normalizedAppId]."
    }
}
