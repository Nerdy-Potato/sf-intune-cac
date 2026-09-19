#Requires -Version 7.2
<#
.SYNOPSIS
    Creates (or updates) the "CaC - Enrolling User Local Admin" Intune proactive remediation and
    assigns it, on an hourly schedule, to the Adult and Teen device tier groups.
.DESCRIPTION
    Windows Autopilot Device Preparation's own "User account type = Administrator" setting has
    been verified end to end in this tenant (policy exists, is targeted correctly, the device is
    MDM-enrolled via that exact policy) and still does not reliably make the enrolling user a
    local administrator. Rather than keep trying to make Device Preparation's own admin-grant step
    work, this deploys an independent, self-healing safety net: an Intune proactive remediation
    (deviceHealthScripts) that runs scripts/remediation/Detect-CaCEnrollingUserLocalAdmin.ps1 and
    scripts/remediation/Remediate-CaCEnrollingUserLocalAdmin.ps1 as SYSTEM on a recurring schedule,
    identifies the specific user who enrolled that specific device (not every member of their
    tier), and adds them to the local Administrators group if they are missing.

    Proactive remediations (deviceHealthScripts) are a distinct Graph resource shape from the
    Settings Catalog/deviceConfigurations objects the rest of this repository's plan/apply engine
    manages (two base64-encoded script blobs plus a schedule-based /assign action, not a
    settings array), so this is a dedicated bootstrap script rather than a config/ entry - the
    same pattern already used for Autopilot Group Tag and device tier group management.

    Idempotent: safe to re-run. If a deviceHealthScript with this display name already exists, it
    is PATCHed (refusing to touch one that does not carry the repository managed marker) rather
    than duplicated, and its assignment is fully replaced (not merged) on every run - the same
    "assign is idempotent replace" semantics this repository already relies on for app assignments.
.PARAMETER Tier
    Which tier's device group(s) to assign this remediation to. Defaults to adult and teen -
    Child-tier devices are intentionally never assigned (Child stays Standard by design).
.EXAMPLE
    ./scripts/bootstrap/New-CaCLocalAdminRemediationScript.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [ValidateSet('adult', 'teen')]
    [string[]] $Tier = @('adult', 'teen'),

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

# Keep in sync with Convert-CaCDeviceTierGroupsToDynamic.ps1 - these are the device-scoped tier
# groups Windows LAPS already targets. Child is intentionally excluded (see .DESCRIPTION).
$GroupConfigIdByTier = @{
    adult = 'sg-devices-adult'
    teen  = 'sg-devices-teen'
}

$DisplayName = 'CaC - Enrolling User Local Admin'

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
$description = "Adds the user who enrolled this device to the local Administrators group when Windows Autopilot Device Preparation's own admin grant did not take effect. $marker".Trim()

$detectionScriptPath = Join-Path $repoRoot 'scripts/remediation/Detect-CaCEnrollingUserLocalAdmin.ps1'
$remediationScriptPath = Join-Path $repoRoot 'scripts/remediation/Remediate-CaCEnrollingUserLocalAdmin.ps1'

$detectionScriptContent = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Content -Path $detectionScriptPath -Raw)))
$remediationScriptContent = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Content -Path $remediationScriptPath -Raw)))

$payload = @{
    '@odata.type'             = '#microsoft.graph.deviceHealthScript'
    displayName               = $DisplayName
    description               = $description
    publisher                 = 'sf-intune-cac'
    runAs32Bit                = $false
    runAsAccount              = 'system'
    enforceSignatureCheck     = $false
    detectionScriptContent    = $detectionScriptContent
    remediationScriptContent  = $remediationScriptContent
    detectionScriptParameters = @()
    remediationScriptParameters = @()
}

$filter = [System.Uri]::EscapeDataString("displayName eq '$(ConvertTo-ODataStringLiteral -Value $DisplayName)'")
$existing = @((& $graphInvoker 'GET' "deviceManagement/deviceHealthScripts?`$filter=$filter" $null).value)

if ($existing.Count -gt 1) {
    throw "Refusing to update '$DisplayName': more than one proactive remediation has this exact display name."
}

$remote = $existing | Select-Object -First 1
$scriptId = $null

if ($remote) {
    $existingDescription = [string] (Get-LocalObjectProperty -InputObject $remote -Name 'description')
    if (-not $existingDescription -or $existingDescription -notlike "*$marker*") {
        throw "'$DisplayName' already exists but does not carry the repository managed marker; refusing to overwrite a proactive remediation this repository may not own."
    }

    $scriptId = Get-LocalObjectProperty -InputObject $remote -Name 'id'
    if ($PSCmdlet.ShouldProcess("$DisplayName [$scriptId]", 'Update proactive remediation script content')) {
        & $graphInvoker 'PATCH' "deviceManagement/deviceHealthScripts/$scriptId" $payload | Out-Null
        Write-Host "Updated proactive remediation '$DisplayName' [$scriptId]."
    }
}
else {
    if ($PSCmdlet.ShouldProcess($DisplayName, 'Create proactive remediation script')) {
        $created = & $graphInvoker 'POST' 'deviceManagement/deviceHealthScripts' $payload
        $scriptId = Get-LocalObjectProperty -InputObject $created -Name 'id'
        Write-Host "Created proactive remediation '$DisplayName' [$scriptId]."
    }
}

if (-not $scriptId) {
    # -WhatIf path: nothing was created, so there is no id to assign against.
    return
}

$assignments = foreach ($t in $Tier) {
    $groupConfigId = $GroupConfigIdByTier[$t]
    $groupSpec = $configuration.Groups | Where-Object { $_.id -eq $groupConfigId }
    if (-not $groupSpec) {
        throw "No group configuration found for id '$groupConfigId'."
    }

    $groupDisplayName = [string] $groupSpec.displayName
    $groupFilter = [System.Uri]::EscapeDataString("displayName eq '$(ConvertTo-ODataStringLiteral -Value $groupDisplayName)'")
    $groupMatches = @((& $graphInvoker 'GET' "groups?`$filter=$groupFilter&`$select=id,displayName" $null).value)

    if ($groupMatches.Count -ne 1) {
        throw "Expected exactly one group named '$groupDisplayName' for tier '$t', found $($groupMatches.Count)."
    }

    @{
        target                = @{
            '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
            groupId       = $groupMatches[0].id
        }
        runRemediationScript  = $true
        runSchedule           = @{
            '@odata.type' = '#microsoft.graph.deviceHealthScriptHourlySchedule'
            interval      = 1
        }
    }
}

if ($PSCmdlet.ShouldProcess("$DisplayName [$scriptId]", "Assign to tier(s): $($Tier -join ', ')")) {
    & $graphInvoker 'POST' "deviceManagement/deviceHealthScripts/$scriptId/assign" @{ deviceHealthScriptAssignments = @($assignments) } | Out-Null
    Write-Host "Assigned '$DisplayName' to: $($Tier -join ', ') (hourly schedule)."
}
