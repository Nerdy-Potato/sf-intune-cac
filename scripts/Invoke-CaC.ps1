#Requires -Version 7.2
<#
.SYNOPSIS
    Single entry point used by the GitHub Actions workflows (and by humans, locally).
.DESCRIPTION
    Modes:
      validate - schema and safety validation only, no tenant access at all.
      plan     - read-only comparison of this repository with the tenant.
      verify   - verify a reviewed plan artifact without tenant access.
      apply    - apply the exact reviewed plan artifact to the tenant.
.EXAMPLE
    ./scripts/Invoke-CaC.ps1 -Mode validate
.EXAMPLE
    ./scripts/Invoke-CaC.ps1 -Mode plan -TenantId $env:AZURE_TENANT_ID -ClientId $env:AZURE_CLIENT_ID
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('validate', 'plan', 'verify', 'apply')]
    [string] $Mode,

    [Parameter()]
    [string] $TenantId = $env:AZURE_TENANT_ID,

    [Parameter()]
    [string] $ClientId = $env:AZURE_CLIENT_ID,

    [Parameter()]
    [switch] $AllowDelete,

    [Parameter()]
    [string] $PlanPath,

    [Parameter()]
    [string] $ExpectedCommitSha,

    [Parameter()]
    [string] $ExpectedPlanId,

    [Parameter()]
    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
Import-Module -Name (Join-Path $repoRoot 'src/IntuneCaC/IntuneCaC.psd1') -Force

function Get-CaCPlanHash {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Actions)

    $canonical = ConvertTo-Json -InputObject @($Actions) -Depth 50 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Read-CaCPlanDocument {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Reviewed plan artifact was not found at '$Path'."
    }

    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Reviewed plan artifact at '$Path' is not valid JSON: $($_.Exception.Message)"
    }
}

function Assert-CaCReviewedPlan {
    param(
        [Parameter(Mandatory)] $Document,
        [Parameter(Mandatory)][string] $RequiredCommitSha,
        [Parameter()][string] $RequiredPlanId
    )

    if ($Document.SchemaVersion -ne 1) {
        throw 'Reviewed plan artifact has an unsupported or missing schema version.'
    }
    $actionsProperty = $Document.PSObject.Properties['Actions']
    if (-not $actionsProperty -or $null -eq $actionsProperty.Value -or $actionsProperty.Value -isnot [array]) {
        throw 'Reviewed plan artifact has no plan actions.'
    }
    if ([string]::IsNullOrWhiteSpace([string] $Document.CommitSha)) {
        throw 'Reviewed plan artifact has no reviewed commit identity.'
    }
    if ($Document.CommitSha -ne $RequiredCommitSha) {
        throw "Reviewed plan commit '$($Document.CommitSha)' does not match required commit '$RequiredCommitSha'."
    }
    if ($Document.Status -ne 'Ready') {
        throw "Reviewed plan artifact is not deployable (status: $($Document.Status))."
    }

    $actions = @($Document.Actions)
    $blocked = @($actions | Where-Object { $_.Action -in @('Skip', 'Prerequisite') })
    if ($blocked) {
        throw 'Reviewed plan contains skipped or prerequisite actions and cannot pass the deployment gate.'
    }

    $actualPlanId = Get-CaCPlanHash -Actions $actions
    if ([string]::IsNullOrWhiteSpace([string] $Document.PlanId) -or $Document.PlanId -ne $actualPlanId) {
        throw 'Reviewed plan identity does not match its actions.'
    }
    if ($RequiredPlanId -and $Document.PlanId -ne $RequiredPlanId) {
        throw "Reviewed plan id '$($Document.PlanId)' does not match the verified plan id '$RequiredPlanId'."
    }

    return $actions
}

$configuration = Get-CaCConfiguration -Path (Join-Path $repoRoot 'config')

Write-Host "Tenant: $($configuration.Tenant.displayName) ($($configuration.Tenant.fallbackDomain))"
Write-Host "Accounts: $($configuration.Users.Count) | Groups: $($configuration.Groups.Count) | Policies: $($configuration.Policies.Count)"

$findings = Test-CaCConfiguration -Configuration $configuration
foreach ($finding in $findings) {
    $line = "[$($finding.Severity)] $($finding.Rule) :: $($finding.Target) :: $($finding.Message)"
    if ($finding.Severity -eq 'Error') { Write-Host "::error::$line" } else { Write-Host "::warning::$line" }
}

if (@($findings | Where-Object Severity -EQ 'Error')) {
    throw 'Configuration validation failed. Nothing was sent to the tenant.'
}

if ($Mode -eq 'validate') {
    Write-Host 'Validation succeeded.'
    return
}

if ($Mode -eq 'verify') {
    if (-not $PlanPath) { throw 'PlanPath is required for verify.' }
    if (-not $ExpectedCommitSha) { throw 'ExpectedCommitSha is required for verify.' }

    $document = Read-CaCPlanDocument -Path $PlanPath
    $null = Assert-CaCReviewedPlan -Document $document -RequiredCommitSha $ExpectedCommitSha `
        -RequiredPlanId $ExpectedPlanId
    Write-Host "Reviewed plan verified: $($document.PlanId)"
    return
}

if (-not $TenantId -or -not $ClientId) {
    throw 'TenantId and ClientId are required for plan and apply. Set the AZURE_TENANT_ID and AZURE_CLIENT_ID variables.'
}

New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null

if ($Mode -eq 'plan') {
    Connect-CaCGraph -TenantId $TenantId -ClientId $ClientId -ReadOnly
    $plan = @(New-CaCPlan -Configuration $configuration)
    $sourceCommitSha = $env:CAC_REVIEWED_COMMIT
    if (-not $sourceCommitSha -and $env:GITHUB_EVENT_PATH -and (Test-Path -LiteralPath $env:GITHUB_EVENT_PATH)) {
        $event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
        $pullRequestEvent = $event.PSObject.Properties['pull_request']
        if ($pullRequestEvent -and $pullRequestEvent.Value -and
            $pullRequestEvent.Value.PSObject.Properties['head']) {
            $sourceCommitSha = $pullRequestEvent.Value.head.sha
        }
    }
    if (-not $sourceCommitSha) { $sourceCommitSha = $env:GITHUB_SHA }

    $blocked = @($plan | Where-Object { $_.Action -in @('Skip', 'Prerequisite') })
    $document = [ordered]@{
        SchemaVersion = 1
        PlanId        = Get-CaCPlanHash -Actions $plan
        CommitSha     = $sourceCommitSha
        Status        = if ($blocked) { 'Blocked' } else { 'Ready' }
        Actions       = $plan
    }

    $document | ConvertTo-Json -Depth 50 | Set-Content -Path (Join-Path $OutputPath 'plan.json') -Encoding utf8
}
else {
    if (-not $PlanPath) { throw 'PlanPath is required for apply.' }
    if (-not $ExpectedCommitSha) { throw 'ExpectedCommitSha is required for apply.' }

    $document = Read-CaCPlanDocument -Path $PlanPath
    $plan = @(Assert-CaCReviewedPlan -Document $document -RequiredCommitSha $ExpectedCommitSha `
            -RequiredPlanId $ExpectedPlanId)
    Connect-CaCGraph -TenantId $TenantId -ClientId $ClientId
}

$markdown = $plan | Format-CaCPlan
$markdown | Set-Content -Path (Join-Path $OutputPath 'plan.md') -Encoding utf8

Write-Host $markdown

if ($env:GITHUB_STEP_SUMMARY) {
    $markdown | Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

if ($Mode -eq 'plan') { return }

$results = Invoke-CaCPlan -Plan $plan -Configuration $configuration -AllowDelete:$AllowDelete -Confirm:$false
$results | Format-Table -AutoSize | Out-String | Write-Host

if ($env:GITHUB_STEP_SUMMARY) {
    "`n### Applied`n" | Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8
    ($results | ForEach-Object { "- $($_.Status): $($_.Action) - $($_.Target) $($_.Message)" }) -join "`n" |
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

# 'ManualActionRequired' is an expected, successful outcome for resource kinds Microsoft Graph
# permanently refuses app-only writes to (deviceEnrollmentConfigurations - see
# Get-CaCResourceMap and .squad/decisions.md's 2026-08-18 manual-apply contract). It is
# deliberately NOT included in $incomplete below: the plan/apply pipeline did exactly what it
# should - detected the diff and correctly declined to attempt a blocked write - so it must never
# fail the deploy on its own. The per-result line above is easy to miss among ordinary "Applied"
# rows, so give it a dedicated, prominent job-summary section as well.
$manualActionItems = @($results | Where-Object Status -eq 'ManualActionRequired')
if ($manualActionItems -and $env:GITHUB_STEP_SUMMARY) {
    $manualActionLines = [System.Collections.Generic.List[string]]::new()
    $manualActionLines.Add("`n### :warning: Manual portal action required`n")
    $manualActionLines.Add('Microsoft Graph blocks app-only/service-principal writes to Enrollment Restrictions by design - this is a documented Microsoft Graph platform limitation, not a bug in this pipeline. See [Microsoft365DSC/Microsoft365DSC#5127](https://github.com/microsoft/Microsoft365DSC/issues/5127).')
    $manualActionLines.Add('')
    $manualActionLines.Add('Apply the item(s) below by hand in the Intune admin center: Devices > Enrollment > Enrollment restrictions (Platform restrictions / Device limit restrictions, as applicable).')
    $manualActionLines.Add('')
    $manualActionLines.Add('The rest of this deployment completed normally; only the item(s) below still need a manual step.')
    $manualActionLines.Add('')
    foreach ($item in $manualActionItems) {
        $manualActionLines.Add("- $($item.Action) - $($item.Target): $($item.Message)")
    }
    ($manualActionLines -join "`n") | Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

$incomplete = @($results | Where-Object Status -in @('Skipped', 'Failed'))
if ($incomplete) {
    $summary = ($incomplete | ForEach-Object {
        "$($_.Status): $($_.Action) - $($_.Target) $($_.Message)"
    }) -join '; '
    throw "Deployment did not complete successfully. No skipped or failed actions may be reported as success. $summary"
}
