#Requires -Version 7.2
<#
.SYNOPSIS
    Deletes a specific orphaned Settings Catalog policy that is marked as owned by this repository.
.DESCRIPTION
    This is a one-off remediation escape hatch for policies that the normal plan/apply engine no
    longer owns safely enough to delete automatically. It resolves a policy by exact display name,
    refuses ambiguous matches, verifies the repository managed marker is present, then deletes it.

    Use only for an explicitly reviewed cleanup, behind the production GitHub environment.
.EXAMPLE
    ./scripts/bootstrap/Remove-CaCOrphanConfigurationPolicy.ps1 -DisplayName 'SF Adults Local Admin' -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string] $DisplayName,

    [Parameter()]
    [string] $TenantId = $env:AZURE_TENANT_ID,

    [Parameter()]
    [string] $ClientId = $env:AZURE_CLIENT_ID,

    [Parameter()]
    [string] $ManagedMarker = 'Managed by sf-intune-cac. Do not edit in the portal.'
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

$filter = [System.Uri]::EscapeDataString("name eq '$(ConvertTo-ODataStringLiteral -Value $DisplayName)'")
$matches = @((& $graphInvoker 'GET' "deviceManagement/configurationPolicies?`$filter=$filter&`$select=id,name,description,platforms,technologies" $null).value)

if (-not $matches) {
    Write-Host "No Settings Catalog policy named '$DisplayName' was found; nothing to delete."
    return
}

if ($matches.Count -gt 1) {
    throw "Refusing to delete '$DisplayName': more than one Settings Catalog policy has this exact name."
}

$policy = $matches[0]
$description = [string] (Get-LocalObjectProperty -InputObject $policy -Name 'description')
if ([string]::IsNullOrWhiteSpace($description) -or $description -notlike "*$ManagedMarker*") {
    throw "Refusing to delete '$DisplayName': the policy does not carry the repository managed marker."
}

if ($PSCmdlet.ShouldProcess("$DisplayName [$($policy.id)]", 'Delete orphaned Settings Catalog policy')) {
    & $graphInvoker 'DELETE' "deviceManagement/configurationPolicies/$($policy.id)" $null | Out-Null
    Write-Host "Deleted orphaned Settings Catalog policy '$DisplayName' [$($policy.id)]."
}
