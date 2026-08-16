BeforeAll {
    $script:RepoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module -Name (Join-Path $script:RepoRoot 'src/IntuneCaC/IntuneCaC.psd1') -Force

    $script:Config = Get-CaCConfiguration -Path (Join-Path $script:RepoRoot 'config')

    # A fake tenant. State is a hashtable of groups / policies / assignments keyed the way the
    # planner asks for them, plus a log of every request so tests can assert on write behaviour.
    function New-FakeTenant {
        param(
            [switch] $InSync,
            [object[]] $ExtraPolicies = @()
        )

        $state = @{
            Groups      = @()
            Members     = @{}
            Policies    = @{}
            Assignments = @{}
            Calls       = [System.Collections.Generic.List[object]]::new()
        }

        if ($InSync) {
            $index = 0
            foreach ($group in $script:Config.Groups) {
                $index++
                $objectId = "group-$index"
                $state.Groups += [pscustomobject]@{ id = $objectId; displayName = $group.displayName; description = $group.description }
                $state.Members[$objectId] = @($group.members | ForEach-Object { [pscustomobject]@{ id = "user-$_"; userPrincipalName = $_ } })
            }

            $policyIndex = 0
            foreach ($policy in $script:Config.Policies) {
                $policyIndex++
                $remote = [ordered]@{ id = "policy-$policyIndex" }

                foreach ($key in $policy.payload.Keys) {
                    $remote[$key] = $policy.payload[$key]
                }

                $endpoint = $policy.resource
                if (-not $state.Policies.ContainsKey($endpoint)) { $state.Policies[$endpoint] = @() }
                $state.Policies[$endpoint] += [pscustomobject] $remote

                $state.Assignments["policy-$policyIndex"] = @($policy.assignments | ForEach-Object {
                        $groupObjectId = ($state.Groups | Where-Object displayName -EQ ($script:Config.Groups | Where-Object id -EQ $_.group).displayName).id
                        $type = if ($_.intent -eq 'exclude') { '#microsoft.graph.exclusionGroupAssignmentTarget' } else { '#microsoft.graph.groupAssignmentTarget' }
                        [pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = $type; groupId = $groupObjectId } }
                    })
            }
        }

        foreach ($extra in $ExtraPolicies) {
            if (-not $state.Policies.ContainsKey($extra.Resource)) { $state.Policies[$extra.Resource] = @() }
            $state.Policies[$extra.Resource] += $extra.Object
        }

        return $state
    }

    function New-FakeInvoker {
        param([hashtable] $State)

        return {
            param($Method, $Uri, $Body)

            $State.Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body })

            if ($Method -ne 'GET') { return [pscustomobject]@{ id = "new-$($State.Calls.Count)" } }

            switch -Regex ($Uri) {
                '^groups\?' { return [pscustomobject]@{ value = $State.Groups } }
                '^users/' { return [pscustomobject]@{ id = "user-object-$($State.Calls.Count)" } }
                '^groups/(?<id>[^/]+)/members' { return [pscustomobject]@{ value = @($State.Members[$Matches.id]) } }
                '/assignments$' {
                    $policyId = ($Uri -split '/')[-2]
                    return [pscustomobject]@{ value = @($State.Assignments[$policyId]) }
                }
                default {
                    $resource = ($Uri -split '/')[-1]
                    return [pscustomobject]@{ value = @($State.Policies[$resource]) }
                }
            }
        }.GetNewClosure()
    }
}

Describe 'New-CaCPlan' {
    Context 'against an empty tenant' {
        BeforeAll {
            $script:EmptyState = New-FakeTenant
            $script:EmptyPlan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $script:EmptyState)
        }

        It 'creates every group defined in the repository' {
            $created = @($script:EmptyPlan | Where-Object { $_.Kind -eq 'Group' -and $_.Action -eq 'Create' })
            $created.Count | Should -Be $script:Config.Groups.Count
        }

        It 'creates every enabled policy defined in the repository' {
            $created = @($script:EmptyPlan | Where-Object { $_.Kind -eq 'Policy' -and $_.Action -eq 'Create' })
            $created.Count | Should -Be @($script:Config.Policies | Where-Object enabled).Count
        }

        It 'never proposes a deletion when the tenant is empty' {
            @($script:EmptyPlan | Where-Object Action -EQ 'Delete') | Should -BeNullOrEmpty
        }

        It 'plans an assignment for every created policy' {
            $assignments = @($script:EmptyPlan | Where-Object Kind -EQ 'Assignment')
            $assignments.Count | Should -Be @($script:Config.Policies | Where-Object enabled).Count
        }
    }

    Context 'against a tenant that already matches' {
        BeforeAll {
            $script:SyncState = New-FakeTenant -InSync
            $script:SyncPlan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $script:SyncState)
        }

        It 'reports no changes at all' {
            $changes = @($script:SyncPlan | Where-Object { $_.Action -notin @('NoChange', 'Skip') })
            $changes | Should -BeNullOrEmpty -Because ((($changes | ForEach-Object { "$($_.Kind) $($_.Action) $($_.Target): $($_.Details -join ',')" }) -join ' | '))
        }

        It 'is idempotent: a second plan is also empty' {
            $second = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $script:SyncState)
            @($second | Where-Object { $_.Action -notin @('NoChange', 'Skip') }) | Should -BeNullOrEmpty
        }

        It 'renders a no-change plan as Markdown' {
            $script:SyncPlan | Format-CaCPlan | Should -BeLike '*No changes*'
        }
    }

    Context 'when somebody edits a policy in the portal' {
        BeforeAll {
            $script:DriftState = New-FakeTenant -InSync
            $windows = $script:DriftState.Policies['deviceCompliancePolicies'] |
                Where-Object displayName -EQ 'CaC - Windows - Compliance Baseline'
            $windows.passwordMinimumLength = 4
            $script:DriftPlan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $script:DriftState)
        }

        It 'detects the drift and reports the old and new value' {
            $update = @($script:DriftPlan | Where-Object { $_.Kind -eq 'Policy' -and $_.Action -eq 'Update' })
            $update.Count | Should -Be 1
            $update.Details -join ' ' | Should -BeLike "*passwordMinimumLength: '4' -> '8'*"
        }
    }

    Context 'when a managed policy is removed from the repository' {
        BeforeAll {
            $script:OrphanState = New-FakeTenant -InSync -ExtraPolicies @(
                @{
                    Resource = 'deviceCompliancePolicies'
                    Object   = [pscustomobject]@{
                        id          = 'orphan-1'
                        displayName = 'CaC - Windows - Retired Policy'
                        description = $script:Config.Tenant.managedMarker
                    }
                },
                @{
                    Resource = 'deviceCompliancePolicies'
                    Object   = [pscustomobject]@{
                        id          = 'handmade-1'
                        displayName = 'Some policy someone made in the portal'
                        description = 'created by hand'
                    }
                }
            )

            $script:OrphanPlan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $script:OrphanState)
        }

        It 'proposes deleting only the object this repository owns' {
            $deletes = @($script:OrphanPlan | Where-Object Action -EQ 'Delete')
            $deletes.Count | Should -Be 1
            $deletes[0].Target | Should -Be 'CaC - Windows - Retired Policy'
        }

        It 'leaves objects created by hand in the portal completely alone' {
            @($script:OrphanPlan | Where-Object Target -EQ 'Some policy someone made in the portal') | Should -BeNullOrEmpty
        }

        It 'warns about deletions in the rendered plan' {
            $script:OrphanPlan | Format-CaCPlan | Should -BeLike '*This plan contains deletions*'
        }
    }

    Context 'when a member joins a tier' {
        BeforeAll {
            $script:MemberState = New-FakeTenant -InSync
            $childGroup = $script:MemberState.Groups | Where-Object displayName -EQ 'CaC-Tier-Child'
            $script:MemberState.Members[$childGroup.id] = @($script:MemberState.Members[$childGroup.id] | Select-Object -Skip 1)

            $script:MemberPlan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $script:MemberState)
        }

        It 'plans the missing membership without touching the policies' {
            $membership = @($script:MemberPlan | Where-Object Kind -EQ 'GroupMembership')
            $membership.Count | Should -Be 1
            $membership[0].Details -join ' ' | Should -BeLike '*add:*'
            @($script:MemberPlan | Where-Object { $_.Kind -eq 'Policy' -and $_.Action -ne 'NoChange' }) | Should -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-CaCPlan' {
    It 'creates groups before it assigns policies to them' {
        $state = New-FakeTenant
        $invoker = New-FakeInvoker -State $state
        $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker $invoker

        # The planner reads an empty tenant; the apply run sees the groups it just created.
        $applyState = New-FakeTenant -InSync
        $applyInvoker = New-FakeInvoker -State $applyState

        $null = Invoke-CaCPlan -Plan $plan -Configuration $script:Config -GraphInvoker $applyInvoker -Confirm:$false

        $writes = @($applyState.Calls | Where-Object { $_.Method -ne 'GET' })
        $firstAssign = ($writes | Where-Object { $_.Uri -like '*/assign' } | Select-Object -First 1)
        $lastGroupWrite = ($writes | Where-Object { $_.Uri -like 'groups*' } | Select-Object -Last 1)

        $writes.IndexOf($lastGroupWrite) | Should -BeLessThan $writes.IndexOf($firstAssign)
    }

    It 'refuses to delete unless deletion was explicitly approved' {
        $state = New-FakeTenant -InSync -ExtraPolicies @(
            @{
                Resource = 'deviceCompliancePolicies'
                Object   = [pscustomobject]@{
                    id          = 'orphan-1'
                    displayName = 'CaC - Windows - Retired Policy'
                    description = $script:Config.Tenant.managedMarker
                }
            }
        )

        $invoker = New-FakeInvoker -State $state
        $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker $invoker

        $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config -GraphInvoker $invoker -Confirm:$false

        ($results | Where-Object Action -EQ 'Delete policy').Status | Should -Be 'Skipped'
        @($state.Calls | Where-Object Method -EQ 'DELETE') | Should -BeNullOrEmpty
    }

    It 'deletes the orphaned object when deletion is approved' {
        $state = New-FakeTenant -InSync -ExtraPolicies @(
            @{
                Resource = 'deviceCompliancePolicies'
                Object   = [pscustomobject]@{
                    id          = 'orphan-1'
                    displayName = 'CaC - Windows - Retired Policy'
                    description = $script:Config.Tenant.managedMarker
                }
            }
        )

        $invoker = New-FakeInvoker -State $state
        $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker $invoker

        $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config -GraphInvoker $invoker -AllowDelete -Confirm:$false

        ($results | Where-Object Action -EQ 'Delete policy').Status | Should -Be 'Applied'
        @($state.Calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Uri -like '*orphan-1' }) | Should -Not -BeNullOrEmpty
    }

    It 'does nothing at all when the tenant already matches' {
        $state = New-FakeTenant -InSync
        $invoker = New-FakeInvoker -State $state
        $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker $invoker

        $null = Invoke-CaCPlan -Plan $plan -Configuration $script:Config -GraphInvoker $invoker -Confirm:$false

        @($state.Calls | Where-Object Method -NE 'GET') | Should -BeNullOrEmpty
    }

    It 'supports -WhatIf so a change can be rehearsed without touching the tenant' {
        $state = New-FakeTenant
        $invoker = New-FakeInvoker -State $state
        $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker $invoker

        $applyState = New-FakeTenant
        $null = Invoke-CaCPlan -Plan $plan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $applyState) -WhatIf

        @($applyState.Calls | Where-Object Method -NE 'GET') | Should -BeNullOrEmpty
    }
}

Describe 'Graph client safety' {
    It 'blocks every write while the session is read-only' {
        InModuleScope IntuneCaC {
            Connect-CaCGraph -TenantId '00000000-0000-0000-0000-000000000000' -AccessToken 'not-a-real-token' -ReadOnly
            { Invoke-CaCGraphRequest -Method POST -Uri 'groups' -Body @{} } | Should -Throw '*read-only*'
        }
    }
}
