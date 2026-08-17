#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Assigns the Intune Administrator directory role to the sf-intune-cac-apply service principal.
.DESCRIPTION
    Microsoft Graph app-only calls that create or update device enrollment platform restriction
    configurations (deviceEnrollmentPlatformRestrictionConfiguration) are rejected with

        403 Forbidden - "Tenant is not Global Admin or Intune Service Admin. Operation is restricted."

    unless the calling service principal is a member of the Intune Administrator (formerly "Intune
    Service Administrator") Microsoft Entra directory role. This is on top of, not instead of, the
    Graph application permissions granted by New-CaCGitHubIdentity.ps1 - Microsoft requires both for
    this specific resource type. Read-only Plan calls are unaffected; only writes need the role.

    This cannot be run by CI/CD: assigning a directory role requires RoleManagement.ReadWrite.Directory,
    which is itself a privileged permission that only a Global Administrator can consent to, and
    granting it to the apply identity would be a bigger privilege increase than the one problem it
    would solve. Like the other scripts in this folder, it is a one-time, hand-run bootstrap step.

    The script looks up the "Intune Administrator" role template dynamically rather than hardcoding
    its GUID, activates the directory role if this is the tenant's first use of it, and is idempotent.
.PARAMETER ApplicationDisplayName
    Display name of the application whose service principal should receive the role. Defaults to the
    write-capable identity; the read-only sf-intune-cac-plan identity does not need this role.
.EXAMPLE
    Connect-MgGraph -Scopes RoleManagement.ReadWrite.Directory, Application.Read.All
    ./bootstrap/Grant-CaCIntuneServiceAdminRole.ps1 -WhatIf
    ./bootstrap/Grant-CaCIntuneServiceAdminRole.ps1
.NOTES
    Sign in as: johnspaid@nerdypotato.onmicrosoft.com (Global Administrator)
    Tenant:     Nerdy Potato (nerdypotato.onmicrosoft.com)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string] $ApplicationDisplayName = 'sf-intune-cac-apply',

    [Parameter()]
    [string] $ExpectedTenantDomain = 'nerdypotato.onmicrosoft.com',

    [Parameter()]
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$context = Get-MgContext
if (-not $context) {
    throw 'Not connected. Run: Connect-MgGraph -Scopes RoleManagement.ReadWrite.Directory, Application.Read.All'
}

$organization = (Invoke-MgGraphRequest -Method GET -Uri 'v1.0/organization?$select=id,displayName,verifiedDomains').value[0]
$domains = @($organization.verifiedDomains | ForEach-Object { $_.name })
if ($ExpectedTenantDomain -notin $domains -and -not $Force) {
    throw "Connected tenant ($($organization.displayName)) does not contain $ExpectedTenantDomain. Refusing to configure the wrong tenant."
}

$servicePrincipal = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/servicePrincipals?`$filter=displayName eq '$ApplicationDisplayName'&`$select=id,appId,displayName").value |
    Select-Object -First 1

if (-not $servicePrincipal) {
    throw "No service principal named '$ApplicationDisplayName' was found. Run New-CaCGitHubIdentity.ps1 first."
}

Write-Host "Service principal: $($servicePrincipal.displayName) [$($servicePrincipal.id)]"

# The role is renamed in the portal ("Intune Service Administrator" -> "Intune Administrator") but
# roleTemplateId 3a2c62db-5318-420d-8d74-23affee5d9d5 has never changed. Look it up by name anyway
# so this keeps working if Microsoft ever renames it again.
$roleTemplate = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/directoryRoleTemplates?`$select=id,displayName").value |
    Where-Object { $_.displayName -in @('Intune Administrator', 'Intune Service Administrator') } |
    Select-Object -First 1

if (-not $roleTemplate) {
    throw 'Could not find the Intune Administrator directory role template in this tenant.'
}

$directoryRole = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/directoryRoles?`$filter=roleTemplateId eq '$($roleTemplate.id)'&`$select=id,displayName").value |
    Select-Object -First 1

if (-not $directoryRole) {
    if (-not $PSCmdlet.ShouldProcess($roleTemplate.displayName, 'Activate directory role in this tenant')) { return }
    $directoryRole = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/directoryRoles' -Body @{
        '@odata.id' = "https://graph.microsoft.com/v1.0/directoryRoleTemplates/$($roleTemplate.id)"
    }
    Write-Host "Activated directory role: $($directoryRole.displayName) [$($directoryRole.id)]"
}
else {
    Write-Host "Directory role already active: $($directoryRole.displayName) [$($directoryRole.id)]"
}

$members = @((Invoke-MgGraphRequest -Method GET -Uri "v1.0/directoryRoles/$($directoryRole.id)/members?`$select=id").value)
$memberIds = @($members | ForEach-Object {
    if ($null -ne $_ -and $_.PSObject.Properties['id']) {
        [string]$_.id
    }
})

if ([string]$servicePrincipal.id -in $memberIds) {
    Write-Host "$($servicePrincipal.displayName) is already a member of $($directoryRole.displayName)."
}
elseif ($PSCmdlet.ShouldProcess($servicePrincipal.displayName, "Add to $($directoryRole.displayName)")) {
    Invoke-MgGraphRequest -Method POST -Uri "v1.0/directoryRoles/$($directoryRole.id)/members/`$ref" -Body @{
        '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($servicePrincipal.id)"
    } | Out-Null
    Write-Host "Added $($servicePrincipal.displayName) to $($directoryRole.displayName)."
}

Write-Host "`nRe-dispatch the Deploy workflow once this has propagated (usually under a minute) to retry the enrollment restriction policies."
