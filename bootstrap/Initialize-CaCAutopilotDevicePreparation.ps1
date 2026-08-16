#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Creates the Windows Autopilot device preparation group and makes Intune Provisioning Client its owner.
.DESCRIPTION
    Implements Microsoft's required Autopilot device preparation prerequisite. The script is
    idempotent and matches the service principal by its immutable application id, because its display
    name can be either Intune Provisioning Client or Intune Autopilot ConfidentialClient.
.EXAMPLE
    Connect-MgGraph -Scopes Application.ReadWrite.All,Group.ReadWrite.All,Organization.Read.All
    ./bootstrap/Initialize-CaCAutopilotDevicePreparation.ps1 -WhatIf
    ./bootstrap/Initialize-CaCAutopilotDevicePreparation.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string] $ExpectedTenantDomain = 'nerdypotato.onmicrosoft.com',

    [Parameter()]
    [string] $GroupDisplayName = 'CaC-Autopilot-DevicePreparation-Child',

    [Parameter()]
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$context = Get-MgContext
if (-not $context) {
    throw 'Not connected. Run: Connect-MgGraph -Scopes Application.ReadWrite.All,Group.ReadWrite.All,Organization.Read.All'
}

$organization = (Invoke-MgGraphRequest -Method GET -Uri 'v1.0/organization?$select=id,displayName,verifiedDomains').value[0]
$domains = @($organization.verifiedDomains | ForEach-Object { $_.name })
if ($ExpectedTenantDomain -notin $domains -and -not $Force) {
    throw "Connected tenant ($($organization.displayName)) does not contain $ExpectedTenantDomain. Refusing to configure the wrong tenant."
}

$provisioningClientAppId = 'f1346770-5b25-470b-88bd-d5744ab7952c'
$servicePrincipal = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/servicePrincipals?`$filter=appId eq '$provisioningClientAppId'&`$select=id,appId,displayName").value |
    Select-Object -First 1

if (-not $servicePrincipal) {
    if (-not $PSCmdlet.ShouldProcess('Intune Provisioning Client', 'Create service principal')) { return }
    $servicePrincipal = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/servicePrincipals' -Body @{
        appId = $provisioningClientAppId
    }
    Write-Host "Created service principal: $($servicePrincipal.displayName) [$($servicePrincipal.id)]"
}
else {
    Write-Host "Service principal already exists: $($servicePrincipal.displayName) [$($servicePrincipal.id)]"
}

$escapedGroupName = $GroupDisplayName.Replace("'", "''")
$groupCandidates = @((Invoke-MgGraphRequest -Method GET -Uri "v1.0/groups?`$filter=displayName eq '$escapedGroupName'&`$select=id,displayName,description,securityEnabled,mailEnabled,groupTypes").value)
if ($groupCandidates.Count -gt 1) {
    throw "More than one group is named '$GroupDisplayName'. Refusing to choose an ownership target by display name."
}
$group = $groupCandidates | Select-Object -First 1

if (-not $group) {
    if (-not $PSCmdlet.ShouldProcess($GroupDisplayName, 'Create assigned security device group')) { return }
    $group = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/groups' -Body @{
        displayName     = $GroupDisplayName
        description     = 'Assigned device group populated by Windows Autopilot device preparation for child devices. Managed by sf-intune-cac.'
        mailEnabled     = $false
        mailNickname    = 'cac-autopilot-device-preparation-child'
        securityEnabled = $true
        groupTypes      = @()
    }
    Write-Host "Created group: $($group.displayName) [$($group.id)]"
}
else {
    if (-not $group.securityEnabled -or $group.mailEnabled -or @($group.groupTypes).Count -ne 0 -or
        $group.description -notlike '*Managed by sf-intune-cac.*') {
        throw "Group '$GroupDisplayName' exists but is not the managed assigned security group expected by this repository."
    }
    Write-Host "Group already exists: $($group.displayName) [$($group.id)]"
}

$owners = @((Invoke-MgGraphRequest -Method GET -Uri "v1.0/groups/$($group.id)/owners?`$select=id").value)
$ownerIds = @($owners | ForEach-Object {
    if ($null -ne $_ -and $_.PSObject.Properties['id']) {
        [string]$_.id
    }
})
if ([string]$servicePrincipal.id -notin $ownerIds) {
    if ($PSCmdlet.ShouldProcess($GroupDisplayName, 'Add Intune Provisioning Client as owner')) {
        Invoke-MgGraphRequest -Method POST -Uri "v1.0/groups/$($group.id)/owners/`$ref" -Body @{
            '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($servicePrincipal.id)"
        } | Out-Null
        Write-Host 'Added Intune Provisioning Client as group owner.'
    }
}
else {
    Write-Host 'Intune Provisioning Client is already a group owner.'
}
