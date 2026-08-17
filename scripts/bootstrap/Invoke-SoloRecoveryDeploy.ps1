#Requires -Version 7.2
<#
.SYNOPSIS
    Dispatches the documented solo-maintainer recovery deployment workflow.
.DESCRIPTION
    Auto-discovers the correct reviewed commit and starts deploy.yml in its workflow_dispatch
    recovery mode. This is the repository's designed recovery path for a solo maintainer when
    GitHub cannot accept a self-approval review; it still requires an explicit reviewed commit,
    a successful plan artifact, and the production environment gate.

    deploy.yml's recovery-mode verify step requires `reviewed_sha` to equal an actual merged pull
    request's HEAD commit (`head.sha`, i.e. the tip of the PR branch before it was merged) -- NOT
    the merge/squash commit that lands on `main`. Because this repository merges pull requests with
    `gh pr merge --squash`, `git rev-parse main` almost never equals any pull request's head sha, so
    that naive default cannot satisfy deploy.yml's check.

    When -CommitSha is not supplied, this script auto-discovers the correct value by:
      1. Listing the most recently merged pull requests (newest first).
      2. Skipping any whose merge commit has not actually landed on the local `main` branch yet
         (verified with `git merge-base --is-ancestor`), so a not-yet-landed PR is never selected.
      3. For each remaining candidate, resolving its PR head sha and checking for a successful
         plan.yml run against that head sha with a valid, non-expired `plan` artifact.
      4. Walking backwards through up to the 30 most recently merged pull requests until one with
         a usable Plan run is found (a PR that only touched paths outside plan.yml's trigger filters
         will never have a Plan run and is skipped rather than failing the whole discovery).
      5. Throwing a clear error if none of the last 30 merged pull requests has a usable Plan run.
.PARAMETER CommitSha
    Optional power-user override. When supplied, this MUST be a pull request's HEAD sha (the tip of
    the PR branch prior to merge) -- the same value deploy.yml's recovery-mode `reviewed_sha` input
    expects -- not a `main`-branch merge/squash commit. When omitted, the correct head sha is
    auto-discovered as described above.
.EXAMPLE
    ./scripts/bootstrap/Invoke-SoloRecoveryDeploy.ps1
    Auto-discovers the most recently merged pull request (walking backwards as needed) that has a
    successful Plan run with a valid artifact, and dispatches deploy.yml against its PR head sha.
.EXAMPLE
    ./scripts/bootstrap/Invoke-SoloRecoveryDeploy.ps1 -CommitSha 0123456789abcdef0123456789abcdef01234567
    Uses an explicit PR head sha (not a main merge commit) as the reviewed commit, bypassing
    auto-discovery.
.EXAMPLE
    ./scripts/bootstrap/Invoke-SoloRecoveryDeploy.ps1 -CommitSha 0123456789abcdef0123456789abcdef01234567 -AllowDelete
.NOTES
    Plan staleness gotcha: a Plan run's plan.json is a snapshot of the diff computed against live
    Graph state AT THE TIME PLAN RAN. If tenant state changed afterward -- for example after running
    a remediation script that deleted stuck objects -- redeploying an old-but-otherwise-valid plan
    artifact can try to act on object IDs that no longer exist. This script does not detect that
    staleness; if tenant state changed since the plan you intend to reuse was reviewed, open a fresh
    pull request touching config/**, src/**, or scripts/** first so plan.yml produces a plan that
    reflects current tenant reality, then rerun this script.
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

function Get-PlanWorkflowRuns {
    param([Parameter(Mandatory)][string] $Repo)

    $planRunsJson = Invoke-CheckedTool -FilePath 'gh' -Arguments @(
        'run', 'list',
        '--repo', $Repo,
        '--workflow', 'plan.yml',
        '--json', 'databaseId,headSha,conclusion,event',
        '--limit', '100'
    )
    if ($planRunsJson) {
        return @($planRunsJson | ConvertFrom-Json)
    }
    return @()
}

function Find-SuccessfulPlanRun {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array] $PlanRuns,
        [Parameter(Mandatory)][string] $HeadSha
    )

    return @(
        $PlanRuns | Where-Object {
            $_.conclusion -eq 'success' -and $_.headSha -eq $HeadSha
        } | Select-Object -First 1
    )
}

function Test-PlanArtifactValid {
    # Mirrors deploy.yml's own "plan" artifact validity check (present, not expired, non-empty)
    # so auto-discovery never selects a Plan run whose artifact was never uploaded or has expired.
    param(
        [Parameter(Mandatory)][string] $Repo,
        [Parameter(Mandatory)] $RunId
    )

    $artifactsJson = Invoke-CheckedTool -FilePath 'gh' -Arguments @(
        'api', "repos/$Repo/actions/runs/$RunId/artifacts",
        '--jq', '.artifacts'
    )
    if ([string]::IsNullOrWhiteSpace($artifactsJson)) {
        return $false
    }

    $artifacts = @($artifactsJson | ConvertFrom-Json)
    $validArtifact = @(
        $artifacts | Where-Object {
            $_.name -eq 'plan' -and -not $_.expired -and $_.size_in_bytes -gt 0
        } | Select-Object -First 1
    )
    return [bool] $validArtifact
}

function Resolve-ReviewedCommit {
    # deploy.yml's recovery-mode verify step requires reviewed_sha to equal a merged pull request's
    # HEAD sha (the PR branch tip before merge), not a main-branch merge/squash commit. Auto-discover
    # that value by walking recently merged pull requests, newest first, skipping any that have not
    # actually landed on the local main branch and any without a usable Plan run/artifact.
    param(
        [Parameter(Mandatory)][string] $Repo,
        [Parameter(Mandatory)][string] $RepoRoot
    )

    $mergedPrsJson = Invoke-CheckedTool -FilePath 'gh' -Arguments @(
        'pr', 'list',
        '--repo', $Repo,
        '--state', 'merged',
        '--limit', '30',
        '--json', 'number,headRefOid,mergeCommit,mergedAt'
    )
    $mergedPrs = if ($mergedPrsJson) { @($mergedPrsJson | ConvertFrom-Json) } else { @() }
    $mergedPrs = @($mergedPrs | Sort-Object { [datetime] $_.mergedAt } -Descending)

    if (-not $mergedPrs) {
        throw (
            "No merged pull requests were found in {0}. Open a pull request touching config/**, " +
            'src/**, or scripts/** to generate a fresh reviewable plan, then retry.'
        ) -f $Repo
    }

    # @(...) wrapping is required here: a helper function's `return @()` unrolls to $null at the
    # call site when the array is empty, so callers must re-wrap to keep a reliable array/count.
    $planRuns = @(Get-PlanWorkflowRuns -Repo $Repo)

    foreach ($pr in $mergedPrs) {
        $mergeCommitSha = $pr.mergeCommit.oid
        if ([string]::IsNullOrWhiteSpace($mergeCommitSha)) {
            continue
        }

        # Skip any pull request whose merge commit is not actually an ancestor of (or equal to) the
        # local main HEAD -- guards against selecting a PR that has not landed yet.
        & git -C $RepoRoot merge-base --is-ancestor $mergeCommitSha main *> $null
        if ($LASTEXITCODE -ne 0) {
            continue
        }

        $headSha = $pr.headRefOid
        if ([string]::IsNullOrWhiteSpace($headSha)) {
            continue
        }

        $matchingRun = @(Find-SuccessfulPlanRun -PlanRuns $planRuns -HeadSha $headSha)
        if (-not $matchingRun) {
            continue
        }

        if (-not (Test-PlanArtifactValid -Repo $Repo -RunId $matchingRun.databaseId)) {
            continue
        }

        return [pscustomobject]@{
            CommitSha   = $headSha
            PullRequest = $pr.number
            MatchingRun = $matchingRun
        }
    }

    throw (
        "None of the {0} most recently merged pull requests in {1} has a successful Plan workflow " +
        'run with a valid plan artifact. Open a pull request touching config/**, src/**, or ' +
        'scripts/** to generate a fresh reviewable plan, then retry this solo-maintainer recovery deployment.'
    ) -f $mergedPrs.Count, $Repo
}

if (-not $CommitSha) {
    $resolved = Resolve-ReviewedCommit -Repo $Repo -RepoRoot $repoRoot
    $CommitSha = $resolved.CommitSha
    $matchingRun = $resolved.MatchingRun
    Write-Host "Auto-discovered reviewed commit $CommitSha from merged pull request #$($resolved.PullRequest)."
}
else {
    $planRuns = @(Get-PlanWorkflowRuns -Repo $Repo)
    $matchingRun = @(Find-SuccessfulPlanRun -PlanRuns $planRuns -HeadSha $CommitSha)

    if (-not $matchingRun) {
        throw (
            "No successful Plan workflow run was found in {0} for reviewed commit {1}. " +
            'Run plan.yml for that commit first, then retry this solo-maintainer recovery deployment.'
        ) -f $Repo, $CommitSha
    }
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
