#Requires -Version 7.2
<#
.SYNOPSIS
    Retires the portal-created "Recover Adult Admin" / "Recover Teen Admin" local administrator
    policies.
.DESCRIPTION
    Those two Settings Catalog policies were created by hand in the Intune portal as a temporary
    recovery measure. They add an entire tier user group (CaC-Tier-Adult / CaC-Tier-Teen) to the
    local Administrators group of every device in the matching tier device group, which is exactly
    the broad grant this repository's design rules out: local administrator rights come only from
    the enrollment-time settings (Autopilot device preparation "User account type = Administrator"
    and the Entra registering-users scope). See docs/operations.md.

    They carry no repository managed marker, so Remove-CaCOrphanConfigurationPolicy.ps1 refuses
    them by design. This script deletes only those two exact names, and only after it has proven,
    for every selected policy, that the policy:
      - is the single Settings Catalog policy with that exact name;
      - contains exactly one LocalUsersAndGroups grant;
      - adds (Update, never Replace) exactly one member to local Administrators;
      - and that member is the SID of the expected live tier user group.
    All selected policies are validated before any of them is deleted.

    Deleting an additive LocalUsersAndGroups policy is not guaranteed to remove the membership it
    granted from devices, and is not guaranteed to keep it either. Verify on each endpoint.
.EXAMPLE
    ./scripts/bootstrap/Remove-CaCLocalAdminRecoveryPolicy.ps1 -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [ValidateSet('Recover Adult Admin', 'Recover Teen Admin')]
    [string[]] $Name = @('Recover Adult Admin', 'Recover Teen Admin'),

    [Parameter()]
    [string] $TenantId = $env:AZURE_TENANT_ID,

    [Parameter()]
    [string] $ClientId = $env:AZURE_CLIENT_ID
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'LocalAdminRecoveryPolicy.Common.ps1')

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

function ConvertTo-ODataStringLiteral {
    param([Parameter(Mandatory)] [string] $Value)
    return $Value.Replace("'", "''")
}

$toDelete = [System.Collections.Generic.List[object]]::new()

foreach ($policyName in $Name) {
    $groupName = $script:CaCLocalAdminRecoveryPolicies[$policyName]

    $policyFilter = [System.Uri]::EscapeDataString("name eq '$(ConvertTo-ODataStringLiteral -Value $policyName)'")
    $policies = @((& $graphInvoker 'GET' "deviceManagement/configurationPolicies?`$filter=$policyFilter&`$select=id,name" $null).value)
    if ($policies.Count -eq 0) {
        Write-Host "No Settings Catalog policy named '$policyName' was found; nothing to retire."
        continue
    }
    if ($policies.Count -gt 1) {
        throw "Refusing to delete '$policyName': more than one Settings Catalog policy has this exact name."
    }
    $policy = $policies[0]

    $groupFilter = [System.Uri]::EscapeDataString("displayName eq '$(ConvertTo-ODataStringLiteral -Value $groupName)'")
    $groups = @((& $graphInvoker 'GET' "groups?`$filter=$groupFilter&`$select=id,displayName" $null).value)
    if ($groups.Count -ne 1) {
        throw "Refusing to delete '$policyName': expected exactly one group named '$groupName', found $($groups.Count)."
    }
    $expectedSid = ConvertTo-CaCEntraGroupSid -ObjectId ([string] $groups[0].id)

    $settings = @((& $graphInvoker 'GET' "deviceManagement/configurationPolicies/$($policy.id)/settings" $null).value)
    try {
        $grant = Get-CaCLocalAdminRecoveryGrant -Settings $settings
    }
    catch {
        throw "Refusing to delete '$policyName': $($_.Exception.Message)"
    }
    Assert-CaCLocalAdminRecoveryGrant -Grant $grant -ExpectedSid $expectedSid -PolicyName $policyName

    Write-Host "Verified '$policyName' [$($policy.id)] only adds $groupName ($expectedSid) to local Administrators."
    $toDelete.Add([pscustomobject]@{ Name = $policyName; Id = [string] $policy.id }) | Out-Null
}

foreach ($item in $toDelete) {
    if ($PSCmdlet.ShouldProcess("$($item.Name) [$($item.Id)]", 'Delete portal-created local admin recovery policy')) {
        & $graphInvoker 'DELETE' "deviceManagement/configurationPolicies/$($item.Id)" $null | Out-Null
        Write-Host "Deleted '$($item.Name)' [$($item.Id)]."
    }
}

if ($toDelete.Count -gt 0) {
    Write-Host (
        'Verify each affected endpoint with Get-LocalGroupMember -Group Administrators after its next ' +
        'sync. Removing an additive policy does not reliably revoke or retain the membership it granted.'
    )
}
