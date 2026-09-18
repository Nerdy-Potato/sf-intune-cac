#Requires -Version 7.2
<#
.SYNOPSIS
    One-time bootstrap: converts CaC-Devices-Adult/Teen/Child from explicit to dynamic
    membership, keyed on each device's Windows Autopilot Group Tag.
.DESCRIPTION
    CaC-Devices-Adult/Teen/Child are the assignment targets for Windows LAPS and tier-specific
    Settings Catalog policies. They were created as ordinary assigned (explicit-membership)
    security groups, which meant nothing in the enrollment flow ever added a device to them - a
    human had to remember to do it by hand, and when that step was missed, those device-scoped
    policies silently never applied.

    Microsoft Graph does not allow converting an existing group's membership type from assigned to
    dynamic (groupTypes is immutable after creation), so the only way to make membership
    self-maintaining is to delete the old assigned group and recreate it as a dynamic group whose
    rule matches on the device's Windows Autopilot Group Tag (Microsoft Entra's `OrderID` device
    physical id) - see https://learn.microsoft.com/autopilot/enrollment-autopilot#group-tag. Once
    a device is Autopilot-registered with the matching tag, Entra ID adds it to the group on its
    own, continuously, forever - no repository code, workflow, or schedule involved.

    This is a one-time, disruptive operation on purpose:
      - Any device currently sitting in the old assigned group (added by hand) is NOT carried
        over. It must be Autopilot-registered with the matching Group Tag - see
        Set-CaCAutopilotGroupTag.ps1 - for the new dynamic rule to pick it back up.
      - The group's object id changes. Local-admin/LAPS policy assignments that reference the
        group by config key (not by id) are automatically re-pointed at the new id on the next
        plan/apply run; no config change is needed for that.
      - Existing per-device compliance/assignment history tied to the old group id is not
        preserved - consistent with how this repository already treats any other group deletion
        (see docs/operations.md's Deletions/Rollback sections).

    Requires Entra ID P1 (or an equivalent license that unlocks dynamic group membership rules).
.PARAMETER Tier
    Which tier's device group(s) to convert. Defaults to all three.
.EXAMPLE
    ./scripts/bootstrap/Convert-CaCDeviceTierGroupsToDynamic.ps1 -WhatIf
.EXAMPLE
    ./scripts/bootstrap/Convert-CaCDeviceTierGroupsToDynamic.ps1 -Tier adult
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [ValidateSet('adult', 'teen', 'child')]
    [string[]] $Tier = @('adult', 'teen', 'child'),

    [Parameter()]
    [string] $TenantId = $env:AZURE_TENANT_ID,

    [Parameter()]
    [string] $ClientId = $env:AZURE_CLIENT_ID,

    [Parameter()]
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../config')
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

# The Windows Autopilot Group Tag each tier's devices must be registered with. Keep this in sync
# with the guidance in docs/enterprise-child-enrollment.md and Set-CaCAutopilotGroupTag.ps1.
$GroupTagByTier = @{
    adult = 'CaC-Adult'
    teen  = 'CaC-Teen'
    child = 'CaC-Child'
}

# The three device group ids these tiers correspond to in config/identity/groups.json.
$GroupConfigIdByTier = @{
    adult = 'sg-devices-adult'
    teen  = 'sg-devices-teen'
    child = 'sg-devices-child'
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

$configuration = Get-CaCConfiguration -Path $ConfigPath
$marker = [string] $configuration.Tenant.managedMarker

foreach ($t in $Tier) {
    $groupConfigId = $GroupConfigIdByTier[$t]
    $groupSpec = $configuration.Groups | Where-Object { $_.id -eq $groupConfigId }
    if (-not $groupSpec) {
        throw "No group configuration found for id '$groupConfigId'."
    }

    $displayName = [string] $groupSpec.displayName
    $groupTag = $GroupTagByTier[$t]
    $membershipRule = "(device.devicePhysicalIds -any (_ -eq `"[OrderID]:$groupTag`"))"

    Write-Host "`n== $displayName (tier: $t, Group Tag: $groupTag) =="

    $filter = [System.Uri]::EscapeDataString("displayName eq '$(ConvertTo-ODataStringLiteral -Value $displayName)'")
    $existing = @((& $graphInvoker 'GET' "groups?`$filter=$filter&`$select=id,displayName,description,groupTypes,membershipRule" $null).value)

    if ($existing.Count -gt 1) {
        throw "Refusing to convert '$displayName': more than one group has this exact display name."
    }

    $remote = $existing | Select-Object -First 1

    if ($remote) {
        $existingGroupTypes = @(Get-LocalObjectProperty -InputObject $remote -Name 'groupTypes')
        if ($existingGroupTypes -contains 'DynamicMembership') {
            $existingRule = Get-LocalObjectProperty -InputObject $remote -Name 'membershipRule'
            Write-Host "  already a dynamic group (rule: $existingRule); nothing to do."
            continue
        }

        $existingDescription = [string] (Get-LocalObjectProperty -InputObject $remote -Name 'description')
        if (-not $existingDescription -or $existingDescription -notlike "*$marker*") {
            Write-Warning "  '$displayName' does not carry the repository managed marker; refusing to delete a group this repository may not own."
            continue
        }

        $members = @((& $graphInvoker 'GET' "groups/$($remote.id)/members?`$select=id,displayName" $null).value)
        if ($members) {
            Write-Warning "  '$displayName' currently has $($members.Count) manually-added member(s) that will NOT carry over: $((($members | ForEach-Object { $_.displayName }) -join ', ')). Re-tag those devices with Set-CaCAutopilotGroupTag.ps1 after this conversion."
        }

        if ($PSCmdlet.ShouldProcess("$displayName [$($remote.id)]", 'Delete assigned group (converting to dynamic)')) {
            & $graphInvoker 'DELETE' "groups/$($remote.id)" $null | Out-Null
            Write-Host "  deleted assigned group $($remote.id)."
        }
        else {
            continue
        }
    }

    if ($PSCmdlet.ShouldProcess($displayName, "Create dynamic group with rule: $membershipRule")) {
        $body = @{
            displayName                  = $displayName
            mailNickname                 = [string] $groupSpec.mailNickname
            description                  = "$($groupSpec.description) $marker".Trim()
            securityEnabled              = $true
            mailEnabled                  = $false
            groupTypes                   = @('DynamicMembership')
            membershipRule               = $membershipRule
            membershipRuleProcessingState = 'On'
        }

        $created = & $graphInvoker 'POST' 'groups' $body
        Write-Host "  created dynamic group $($created.id) with rule: $membershipRule"
    }
}

Write-Host @'

Next steps:
  1. Every device that must land in one of these groups needs to be Autopilot-registered with the
     matching Group Tag (see the table in docs/enterprise-child-enrollment.md). For an
     already-registered device, use Set-CaCAutopilotGroupTag.ps1.
  2. Dynamic group processing is not instant - allow up to a few minutes to a few hours for large
     tenants, though a family-sized tenant is normally fast.
  3. Re-run the deploy plan afterwards: the LAPS and tier-specific policy assignments will show as
     Update (re-pointing at the new group ids), not Create - this is expected and safe.
'@
