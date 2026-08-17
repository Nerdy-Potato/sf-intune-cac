BeforeAll {
    # NOTE: fixtures for this file's gh/git mocks intentionally live under $global: (SRD_ prefix),
    # not $script:. The system under test is invoked via `& $scriptPath`, which executes as its own
    # script file and pushes a new script-scope onto the stack; a Mock body's `$script:` modifier
    # resolves against that new (empty) script scope rather than this test file's scope, so
    # $script:-scoped fixtures would appear unset from inside the mock. $global: is unambiguous.
    $global:SRD_RepoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
    $global:SRD_ScriptPath = Join-Path $global:SRD_RepoRoot 'scripts/bootstrap/Invoke-SoloRecoveryDeploy.ps1'
    $global:SRD_Repo = 'Nerdy-Potato/sf-intune-cac'
}

Describe 'Invoke-SoloRecoveryDeploy auto-discovery' {
    BeforeEach {
        # Reset per-test fixtures consumed by the gh/git mocks below.
        $global:SRD_MergedPrs = @()
        $global:SRD_PlanRuns = @()
        $global:SRD_ArtifactsByRunId = @{}
        $global:SRD_AncestorMergeCommits = @()
        $global:SRD_DeployRunListCallCount = 0
        $global:SRD_DispatchedRunId = 999001
        $global:SRD_DeployDispatchCalled = $false
        $global:SRD_LastDispatchedSha = $null

        Mock -CommandName Start-Sleep -MockWith {}

        Mock -CommandName git -MockWith {
            if (($args -contains 'merge-base') -and ($args -contains '--is-ancestor')) {
                $shaIndex = [array]::IndexOf($args, '--is-ancestor') + 1
                $sha = $args[$shaIndex]
                $global:LASTEXITCODE = if ($global:SRD_AncestorMergeCommits -contains $sha) { 0 } else { 1 }
                return ''
            }
            throw "Unexpected git invocation: $($args -join ' ')"
        }

        Mock -CommandName gh -MockWith {
            $global:LASTEXITCODE = 0
            $joined = $args -join ' '

            if ($args[0] -eq 'pr' -and $args[1] -eq 'list') {
                return ($global:SRD_MergedPrs | ConvertTo-Json -Depth 10 -Compress -AsArray)
            }
            elseif ($args[0] -eq 'run' -and $args[1] -eq 'list' -and ($args -contains 'plan.yml')) {
                return ($global:SRD_PlanRuns | ConvertTo-Json -Depth 10 -Compress -AsArray)
            }
            elseif ($args[0] -eq 'api') {
                if ($args[1] -match 'actions/runs/(\d+)/artifacts') {
                    $runId = $Matches[1]
                    $artifacts = @()
                    if ($global:SRD_ArtifactsByRunId.ContainsKey($runId)) {
                        $artifacts = $global:SRD_ArtifactsByRunId[$runId]
                    }
                    return ($artifacts | ConvertTo-Json -Depth 10 -Compress -AsArray)
                }
                throw "Unexpected gh api invocation: $joined"
            }
            elseif ($args[0] -eq 'run' -and $args[1] -eq 'list' -and ($args -contains 'deploy.yml')) {
                $global:SRD_DeployRunListCallCount++
                if ($global:SRD_DeployRunListCallCount -eq 1 -or -not $global:SRD_DeployDispatchCalled) {
                    return '[]'
                }
                $dispatched = @{
                    databaseId = $global:SRD_DispatchedRunId
                    event      = 'workflow_dispatch'
                    url        = "https://github.com/$global:SRD_Repo/actions/runs/$global:SRD_DispatchedRunId"
                    createdAt  = (Get-Date).ToString('o')
                    headSha    = $global:SRD_LastDispatchedSha
                }
                return (@($dispatched) | ConvertTo-Json -Depth 10 -Compress -AsArray)
            }
            elseif ($args[0] -eq 'workflow' -and $args[1] -eq 'run' -and ($args -contains 'deploy.yml')) {
                $global:SRD_DeployDispatchCalled = $true
                $shaArg = @($args | Where-Object { $_ -like 'reviewed_sha=*' })[0]
                $global:SRD_LastDispatchedSha = $shaArg -replace '^reviewed_sha=', ''
                return ''
            }
            else {
                throw "Unexpected gh invocation: $joined"
            }
        }
    }

    It 'auto-discovers the reviewed commit from the most recently merged pull request with a valid plan run and artifact' {
        $global:SRD_MergedPrs = @(
            @{ number = 21; headRefOid = 'head-newest'; mergeCommit = @{ oid = 'merge-newest' }; mergedAt = '2026-08-17T10:00:00Z' },
            @{ number = 20; headRefOid = 'head-older'; mergeCommit = @{ oid = 'merge-older' }; mergedAt = '2026-08-17T09:00:00Z' }
        )
        $global:SRD_AncestorMergeCommits = @('merge-newest', 'merge-older')
        $global:SRD_PlanRuns = @(
            @{ databaseId = 501; headSha = 'head-newest'; conclusion = 'success'; event = 'pull_request' }
        )
        $global:SRD_ArtifactsByRunId = @{
            '501' = @(@{ name = 'plan'; expired = $false; size_in_bytes = 100 })
        }

        & $global:SRD_ScriptPath -Repo $global:SRD_Repo

        $global:SRD_LastDispatchedSha | Should -Be 'head-newest'
        Should -Invoke -CommandName gh -ParameterFilter { $args[0] -eq 'pr' -and $args[1] -eq 'list' } -Times 1
    }

    It 'skips a merged pull request whose merge commit has not landed on main yet' {
        $global:SRD_MergedPrs = @(
            @{ number = 22; headRefOid = 'head-not-landed'; mergeCommit = @{ oid = 'merge-not-landed' }; mergedAt = '2026-08-17T11:00:00Z' },
            @{ number = 20; headRefOid = 'head-landed'; mergeCommit = @{ oid = 'merge-landed' }; mergedAt = '2026-08-17T09:00:00Z' }
        )
        # Only the second PR's merge commit is actually an ancestor of main.
        $global:SRD_AncestorMergeCommits = @('merge-landed')
        $global:SRD_PlanRuns = @(
            @{ databaseId = 502; headSha = 'head-landed'; conclusion = 'success'; event = 'pull_request' }
        )
        $global:SRD_ArtifactsByRunId = @{
            '502' = @(@{ name = 'plan'; expired = $false; size_in_bytes = 100 })
        }

        & $global:SRD_ScriptPath -Repo $global:SRD_Repo

        $global:SRD_LastDispatchedSha | Should -Be 'head-landed'
    }

    It 'walks backwards past a merged pull request without a successful Plan run or valid artifact' {
        $global:SRD_MergedPrs = @(
            @{ number = 23; headRefOid = 'head-no-plan'; mergeCommit = @{ oid = 'merge-no-plan' }; mergedAt = '2026-08-17T12:00:00Z' },
            @{ number = 22; headRefOid = 'head-expired-artifact'; mergeCommit = @{ oid = 'merge-expired-artifact' }; mergedAt = '2026-08-17T11:00:00Z' },
            @{ number = 20; headRefOid = 'head-usable'; mergeCommit = @{ oid = 'merge-usable' }; mergedAt = '2026-08-17T09:00:00Z' }
        )
        $global:SRD_AncestorMergeCommits = @('merge-no-plan', 'merge-expired-artifact', 'merge-usable')
        $global:SRD_PlanRuns = @(
            # PR #22 has a successful Plan run, but its artifact has expired -- must be skipped.
            @{ databaseId = 503; headSha = 'head-expired-artifact'; conclusion = 'success'; event = 'pull_request' },
            @{ databaseId = 504; headSha = 'head-usable'; conclusion = 'success'; event = 'pull_request' }
        )
        $global:SRD_ArtifactsByRunId = @{
            '503' = @(@{ name = 'plan'; expired = $true; size_in_bytes = 100 })
            '504' = @(@{ name = 'plan'; expired = $false; size_in_bytes = 100 })
        }

        & $global:SRD_ScriptPath -Repo $global:SRD_Repo

        $global:SRD_LastDispatchedSha | Should -Be 'head-usable'
    }

    It 'throws a clear error when none of the recently merged pull requests has a usable plan run' {
        $global:SRD_MergedPrs = @(
            @{ number = 24; headRefOid = 'head-1'; mergeCommit = @{ oid = 'merge-1' }; mergedAt = '2026-08-17T12:00:00Z' }
        )
        $global:SRD_AncestorMergeCommits = @('merge-1')
        $global:SRD_PlanRuns = @()

        { & $global:SRD_ScriptPath -Repo $global:SRD_Repo } | Should -Throw -ExpectedMessage '*has a successful Plan workflow run with a valid plan artifact*'
    }

    It 'skips pull-request auto-discovery entirely when -CommitSha is supplied explicitly' {
        $global:SRD_PlanRuns = @(
            @{ databaseId = 505; headSha = 'explicit-sha'; conclusion = 'success'; event = 'pull_request' }
        )
        $global:SRD_ArtifactsByRunId = @{
            '505' = @(@{ name = 'plan'; expired = $false; size_in_bytes = 100 })
        }

        & $global:SRD_ScriptPath -Repo $global:SRD_Repo -CommitSha 'explicit-sha'

        $global:SRD_LastDispatchedSha | Should -Be 'explicit-sha'
        Should -Invoke -CommandName gh -ParameterFilter { $args[0] -eq 'pr' -and $args[1] -eq 'list' } -Times 0
    }
}

AfterAll {
    Remove-Item -Path Variable:\SRD_* -ErrorAction SilentlyContinue
}
