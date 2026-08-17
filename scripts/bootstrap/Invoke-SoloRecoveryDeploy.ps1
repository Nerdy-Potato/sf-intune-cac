#Requires -Version 7.2
<#
.SYNOPSIS
    Dispatches the documented solo-maintainer recovery deployment workflow.
.DESCRIPTION
    Finds the most recent successful Plan workflow run for a reviewed commit on main and starts
    deploy.yml in its workflow_dispatch recovery mode. This is the repository's designed recovery
    path for a solo maintainer when GitHub cannot accept a self-approval review; it still requires
    an explicit reviewed commit, a successful plan artifact, and the production environment gate.
.EXAMPLE
    ./scripts/bootstrap/Invoke-SoloRecoveryDeploy.ps1
.EXAMPLE
    ./scripts/bootstrap/Invoke-SoloRecoveryDeploy.ps1 -CommitSha 0123456789abcdef0123456789abcdef01234567
.EXAMPLE
    ./scripts/bootstrap/Invoke-SoloRecoveryDeploy.ps1 -CommitSha 0123456789abcdef0123456789abcdef01234567 -AllowDelete
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string] $CommitSha,

    [Parameter()]
    [string] $Repo = 'Nerdy-Potato/sf-intune-cac',

    [Parameter()]
    [switch] $AllowDelete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../..')).Path

function Invoke-CheckedTool {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $lines = & $FilePath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $commandText = ($Arguments | ForEach-Object {
                if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
            }) -join ' '
        throw "{0} {1} failed: {2}" -f $FilePath, $commandText, (($lines | ForEach-Object { "$_" }) -join [Environment]::NewLine)
    }

    return (($lines | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
}

if (-not $CommitSha) {
    $CommitSha = Invoke-CheckedTool -FilePath 'git' -Arguments @('-C', $repoRoot, 'rev-parse', 'main')
}

if ([string]::IsNullOrWhiteSpace($CommitSha)) {
    throw 'CommitSha could not be resolved. Pass -CommitSha explicitly or ensure the local main branch exists.'
}

$planRuns = @()
$planRunsJson = Invoke-CheckedTool -FilePath 'gh' -Arguments @(
    'run', 'list',
    '--repo', $Repo,
    '--workflow', 'plan.yml',
    '--json', 'databaseId,headSha,conclusion,event',
    '--limit', '100'
)
if ($planRunsJson) {
    $planRuns = @($planRunsJson | ConvertFrom-Json)
}

$matchingRun = @(
    $planRuns | Where-Object {
        $_.conclusion -eq 'success' -and $_.headSha -eq $CommitSha
    } | Select-Object -First 1
)

if (-not $matchingRun) {
    throw (
        "No successful Plan workflow run was found in {0} for reviewed commit {1}. " +
        'Run plan.yml for that commit first, then retry this solo-maintainer recovery deployment.'
    ) -f $Repo, $CommitSha
}

# Snapshot existing deploy runs so the new dispatch can be identified and reported back with a URL.
$existingDeployRunsJson = Invoke-CheckedTool -FilePath 'gh' -Arguments @(
    'run', 'list',
    '--repo', $Repo,
    '--workflow', 'deploy.yml',
    '--json', 'databaseId,event,url,createdAt,headSha',
    '--limit', '20'
)
$existingDeployRuns = if ($existingDeployRunsJson) {
    @($existingDeployRunsJson | ConvertFrom-Json)
}
else {
    @()
}
$existingDeployRunIds = @($existingDeployRuns | ForEach-Object { [string] $_.databaseId })
$allowDeleteValue = if ($AllowDelete) { 'true' } else { 'false' }

Write-Host "Using reviewed commit $CommitSha and successful Plan run $($matchingRun.databaseId)."

$null = Invoke-CheckedTool -FilePath 'gh' -Arguments @(
    'workflow', 'run', 'deploy.yml',
    '--repo', $Repo,
    '-f', 'confirm_deploy=true',
    '-f', "reviewed_sha=$CommitSha",
    '-f', "plan_run_id=$($matchingRun.databaseId)",
    '-f', "allow_delete=$allowDeleteValue"
)

$dispatchedRun = $null
for ($attempt = 0; $attempt -lt 10 -and -not $dispatchedRun; $attempt++) {
    Start-Sleep -Seconds 2
    $deployRunsJson = Invoke-CheckedTool -FilePath 'gh' -Arguments @(
        'run', 'list',
        '--repo', $Repo,
        '--workflow', 'deploy.yml',
        '--json', 'databaseId,event,url,createdAt,headSha',
        '--limit', '20'
    )
    $deployRuns = if ($deployRunsJson) { @($deployRunsJson | ConvertFrom-Json) } else { @() }
    $dispatchedRun = @(
        $deployRuns | Where-Object {
            $_.event -eq 'workflow_dispatch' -and
            $_.headSha -eq $CommitSha -and
            ([string] $_.databaseId) -notin $existingDeployRunIds
        } |
            Sort-Object createdAt -Descending |
            Select-Object -First 1
    )
}

if (-not $dispatchedRun) {
    throw (
        "Deploy workflow was dispatched for reviewed commit {0}, but the new run URL could not be " +
        'resolved automatically. Check https://github.com/{1}/actions/workflows/deploy.yml for the workflow_dispatch run.'
    ) -f $CommitSha, $Repo
}

Write-Host ''
Write-Host 'Solo-maintainer recovery deploy dispatched.'
Write-Host "Repository: $Repo"
Write-Host "Reviewed commit: $CommitSha"
Write-Host "Plan run ID: $($matchingRun.databaseId)"
Write-Host "allow_delete: $allowDeleteValue"
Write-Host "Run URL: $($dispatchedRun.url)"
Write-Host ''
Write-Host (
    'This is the repository''s documented recovery path for a solo maintainer. ' +
    'It does not bypass the reviewed-plan requirement or the production environment approval gate.'
)
