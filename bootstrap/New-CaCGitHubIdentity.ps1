#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication
<#
.SYNOPSIS
    One-time bootstrap: creates the two Entra app registrations the GitHub Actions workflows use.
.DESCRIPTION
    This is the only thing in the whole repository that is not deployed by CI/CD, because something
    has to create the identity that CI/CD authenticates with. Run it once, from an interactive
    session, signed in as the dedicated admin account.

    It creates two applications on purpose:

      sf-intune-cac-plan   read-only  - used by pull request planning and nightly drift detection.
      sf-intune-cac-apply  read-write - used only by the environment-gated deployment workflow.

    A pull request from a branch can therefore never obtain write access to the tenant: the write
    credential is bound to the 'production' environment subject, which requires an approval.

    No secrets are created. Both applications authenticate with GitHub's OIDC token through a
    federated credential, so there is nothing to store in GitHub and nothing to rotate.

    The script is idempotent - re-running it reconciles rather than duplicating.
.PARAMETER TenantId
    The tenant to bootstrap. Defaults to the family tenant; the script refuses to run anywhere else
    unless -Force is passed.
.EXAMPLE
    Connect-MgGraph -Scopes Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All, Directory.Read.All
    ./bootstrap/New-CaCGitHubIdentity.ps1 -WhatIf
.NOTES
    Sign in as: johnspaid@nerdypotato.onmicrosoft.com (Global Administrator)
    Tenant:     Nerdy Potato (nerdypotato.onmicrosoft.com)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string] $Repository = 'Nerdy-Potato/sf-intune-cac',

    [Parameter()]
    [string] $ExpectedTenantDomain = 'nerdypotato.onmicrosoft.com',

    [Parameter()]
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$context = Get-MgContext
if (-not $context) {
    throw 'Not connected. Run: Connect-MgGraph -Scopes Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All, Directory.Read.All'
}

$organization = (Invoke-MgGraphRequest -Method GET -Uri 'v1.0/organization').value[0]
$domains = @($organization.verifiedDomains | ForEach-Object { $_.name })

if ($ExpectedTenantDomain -notin $domains -and -not $Force) {
    throw "Connected tenant ($($organization.displayName)) does not contain $ExpectedTenantDomain. Refusing to bootstrap the wrong tenant. Pass -Force only if you are certain."
}

Write-Host "Tenant: $($organization.displayName) [$($organization.id)]"
Write-Host "Repository: $Repository"

$graphAppId = '00000003-0000-0000-c000-000000000000'
$graphSp = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/servicePrincipals?`$filter=appId eq '$graphAppId'").value[0]

$applications = @(
    @{
        Name    = 'sf-intune-cac-plan'
        Purpose = 'Read-only. Pull request planning and drift detection.'
        Roles   = @(
            'DeviceManagementConfiguration.Read.All'
            'DeviceManagementApps.Read.All'
            'Group.Read.All'
            'User.Read.All'
        )
        Subjects = @(
            "repo:$($Repository):pull_request"
            "repo:$($Repository):environment:plan"
        )
    }
    @{
        Name    = 'sf-intune-cac-apply'
        Purpose = 'Read-write. Deployment only, gated behind the production environment.'
        Roles   = @(
            'DeviceManagementConfiguration.ReadWrite.All'
            'DeviceManagementApps.ReadWrite.All'
            'Group.ReadWrite.All'
            'User.Read.All'
        )
        Subjects = @(
            "repo:$($Repository):environment:production"
        )
    }
)

$summary = [System.Collections.Generic.List[object]]::new()

foreach ($definition in $applications) {
    Write-Host "`n== $($definition.Name) =="

    $application = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/applications?`$filter=displayName eq '$($definition.Name)'").value |
        Select-Object -First 1

    if (-not $application) {
        if ($PSCmdlet.ShouldProcess($definition.Name, 'Create application')) {
            $application = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/applications' -Body @{
                displayName    = $definition.Name
                description    = $definition.Purpose
                signInAudience = 'AzureADMyOrg'
            }
            Write-Host "  created application $($application.appId)"
        }
        else {
            continue
        }
    }
    else {
        Write-Host "  application already exists ($($application.appId))"
    }

    $servicePrincipal = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/servicePrincipals?`$filter=appId eq '$($application.appId)'").value |
        Select-Object -First 1

    if (-not $servicePrincipal -and $PSCmdlet.ShouldProcess($definition.Name, 'Create service principal')) {
        $servicePrincipal = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/servicePrincipals' -Body @{
            appId = $application.appId
        }
        Write-Host '  created service principal'
    }

    $existingCredentials = @((Invoke-MgGraphRequest -Method GET -Uri "v1.0/applications/$($application.id)/federatedIdentityCredentials").value)

    foreach ($subject in $definition.Subjects) {
        if ($existingCredentials | Where-Object { $_.subject -eq $subject }) {
            Write-Host "  federated credential already present: $subject"
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($subject, 'Create federated credential')) { continue }

        $null = Invoke-MgGraphRequest -Method POST -Uri "v1.0/applications/$($application.id)/federatedIdentityCredentials" -Body @{
            name        = ($subject -replace '[^A-Za-z0-9]', '-')
            issuer      = 'https://token.actions.githubusercontent.com'
            subject     = $subject
            audiences   = @('api://AzureADTokenExchange')
            description = $definition.Purpose
        }

        Write-Host "  added federated credential: $subject"
    }

    if ($servicePrincipal) {
        $assigned = @((Invoke-MgGraphRequest -Method GET -Uri "v1.0/servicePrincipals/$($servicePrincipal.id)/appRoleAssignments").value)

        foreach ($role in $definition.Roles) {
            $appRole = $graphSp.appRoles | Where-Object { $_.value -eq $role -and $_.allowedMemberTypes -contains 'Application' }

            if (-not $appRole) {
                Write-Warning "  Graph does not expose an application role called '$role'; skipping."
                continue
            }

            if ($assigned | Where-Object { $_.appRoleId -eq $appRole.id }) {
                Write-Host "  role already granted: $role"
                continue
            }

            if (-not $PSCmdlet.ShouldProcess($role, "Grant to $($definition.Name)")) { continue }

            $null = Invoke-MgGraphRequest -Method POST -Uri "v1.0/servicePrincipals/$($servicePrincipal.id)/appRoleAssignments" -Body @{
                principalId = $servicePrincipal.id
                resourceId  = $graphSp.id
                appRoleId   = $appRole.id
            }

            Write-Host "  granted: $role"
        }
    }

    $summary.Add([pscustomobject]@{
            Application = $definition.Name
            ClientId    = $application.appId
        })
}

Write-Host "`n== Repository variables to set =="
Write-Host "gh variable set AZURE_TENANT_ID --body $($organization.id)"

foreach ($item in $summary) {
    $variable = if ($item.Application -like '*plan') { 'AZURE_PLAN_CLIENT_ID' } else { 'AZURE_APPLY_CLIENT_ID' }
    Write-Host "gh variable set $variable --body $($item.ClientId)"
}

Write-Host @'

Remaining manual steps (documented in docs/bootstrap.md):
  1. Create the 'plan' and 'production' GitHub environments.
  2. Add a required reviewer to 'production' so that no deployment reaches the tenant unattended.
  3. Protect main: require the CI and Plan checks before merge.
'@
