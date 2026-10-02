#Requires -Version 7.2
[CmdletBinding()]
param(
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [string] $Ref = $env:GITHUB_REF,
    [string] $CommitSha = $env:GITHUB_SHA,
    [string] $Token = $env:GH_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Ref -cne 'refs/heads/main') {
    throw 'Deployment requires refs/heads/main; dispatch a new run on main.'
}
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
    $CommitSha -notmatch '^[a-fA-F0-9]{40}$' -or [string]::IsNullOrWhiteSpace($Token)) {
    throw 'Deployment source verification requires a valid repository, GITHUB_SHA, and GitHub token.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$checkoutSha = & git -C $repoRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or [string] $checkoutSha -notmatch '^[a-fA-F0-9]{40}$') {
    throw 'Cannot verify the deployment checkout HEAD.'
}
if ($checkoutSha -ne $CommitSha) {
    throw 'Deployment checkout HEAD does not match GITHUB_SHA.'
}

try {
    $main = Invoke-RestMethod -Method Get `
        -Uri "https://api.github.com/repos/$Repository/git/ref/heads/main" `
        -Headers @{
            Authorization = "Bearer $Token"
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
        } -TimeoutSec 30
    $mainSha = [string] $main.object.sha
    if ($main.ref -cne 'refs/heads/main' -or $mainSha -notmatch '^[a-fA-F0-9]{40}$') {
        throw 'Invalid main reference response.'
    }
}
catch {
    # Do not echo response bodies or authorization headers into deployment logs.
    throw 'Cannot verify current remote main through the GitHub API. Nothing may be deployed.'
}

if ($CommitSha -ne $mainSha) {
    throw 'Deployment commit is stale: GITHUB_SHA and checkout HEAD must equal current remote main. Dispatch a new run on main.'
}
Write-Host "Deployment source verified against current remote main: $mainSha"
