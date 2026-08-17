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
            Apps        = @()
            AppAssignments = @{}
            Policies    = @{}
            Assignments = @{}
            Calls       = [System.Collections.Generic.List[object]]::new()
        }

        if ($InSync) {
            $index = 0
            foreach ($group in $script:Config.Groups) {
                $index++
                $objectId = "group-$index"
                $state.Groups += [pscustomobject]@{
                    id          = $objectId
                    displayName = $group.displayName
                    description = '{0} {1}' -f $group.description, $script:Config.Tenant.managedMarker
                }
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

            $appIndex = 0
            foreach ($app in $script:Config.Apps) {
                $appIndex++
                $remote = [ordered]@{ id = "app-$appIndex" }
                foreach ($key in $app.payload.Keys) {
                    $remote[$key] = $app.payload[$key]
                }
                $state.Apps += [pscustomobject] $remote
                $state.AppAssignments["app-$appIndex"] = @($app.assignments | ForEach-Object {
                        $groupObjectId = ($state.Groups | Where-Object displayName -EQ ($script:Config.Groups | Where-Object id -EQ $_.group).displayName).id
                        [pscustomobject]@{
                            intent = $_.intent
                            target = [pscustomobject]@{
                                '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                                groupId       = $groupObjectId
                            }
                        }
                    })
            }

            foreach ($policy in $script:Config.Policies | Where-Object {
                    $null -ne $_.PSObject.Properties['targetApps']
                }) {
                $policyObjects = @($state.Policies[$policy.resource])
                $policyIndex = 0
                while ($policyIndex -lt $policyObjects.Count -and
                    $policyObjects[$policyIndex].displayName -ne $policy.payload.displayName) {
                    $policyIndex++
                }
                $remotePolicy = $policyObjects[$policyIndex]
                $targetIds = @($policy.targetApps | ForEach-Object {
                        $targetApp = $script:Config.Apps | Where-Object id -EQ $_
                        ($state.Apps | Where-Object {
                                $_.packageId -eq $targetApp.payload.packageId -or
                                $_.bundleId -eq $targetApp.payload.bundleId -or
                                $_.displayName -eq $targetApp.payload.displayName
                            } | Select-Object -First 1).id
                    })
                $policyObjects[$policyIndex] = $remotePolicy | Add-Member -Force -PassThru `
                    -NotePropertyName targetedMobileApps -NotePropertyValue $targetIds
                $state.Policies[$policy.resource] = $policyObjects
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
                '^deviceAppManagement/mobileApps$' { return [pscustomobject]@{ value = $State.Apps } }
                '^deviceAppManagement/mobileApps/(?<id>[^/]+)/assignments$' {
                    return [pscustomobject]@{ value = @($State.AppAssignments[$Matches.id]) }
                }
                '/assignments$' {
                    $policyId = ($Uri -split '/')[-2]
                    return [pscustomobject]@{ value = @($State.Assignments[$policyId]) }
                }
                default {
                    $resource = ($Uri -split '/')[-1]
                    $objects = @($State.Policies[$resource])
                    if ($resource -eq 'mobileAppConfigurations') {
                        $objects = @($objects | ForEach-Object {
                                if ($_.displayName -eq 'CaC - Android - Defender and GSA (Child)') {
                                    $_ | Add-Member -Force -PassThru -NotePropertyName targetedMobileApps `
                                        -NotePropertyValue @('app-1')
                                }
                                else {
                                    $_
                                }
                            })
                    }
                    return [pscustomobject]@{ value = $objects }
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

        It 'creates every approved app that can be sourced programmatically' {
            $created = @($script:EmptyPlan | Where-Object { $_.Kind -eq 'App' -and $_.Action -eq 'Create' })
            $created.Count | Should -Be @($script:Config.Apps | Where-Object source -NE 'existing').Count
        }

        It 'reports prepackaged Windows apps as explicit prerequisites' {
            $prerequisites = @($script:EmptyPlan | Where-Object { $_.Kind -eq 'App' -and $_.Action -eq 'Prerequisite' })
            $prerequisites.Count | Should -Be @($script:Config.Apps | Where-Object source -EQ 'existing').Count
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

        It 'does not propose deleting a same-namespace object without the managed marker' {
            $state = New-FakeTenant -InSync -ExtraPolicies @(
                @{
                    Resource = 'deviceCompliancePolicies'
                    Object   = [pscustomobject]@{
                        id          = 'unmanaged-same-namespace'
                        displayName = 'CaC - Windows - Unmanaged Policy'
                        description = 'created by hand'
                    }
                }
            )

            $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $state)

            @($plan | Where-Object Target -EQ 'CaC - Windows - Unmanaged Policy') | Should -BeNullOrEmpty
        }

        It 'warns about deletions in the rendered plan' {
            $script:OrphanPlan | Format-CaCPlan | Should -BeLike '*This plan contains deletions*'
        }
    }

    Context 'when an existing app configuration targets an app that must be created' {
        It 'keeps the policy in the same plan so apply can bind the new app id' {
            $state = New-FakeTenant -InSync
            $defender = $script:Config.Apps | Where-Object id -EQ 'android-defender'
            $remoteDefender = $state.Apps | Where-Object {
                $_.PSObject.Properties['packageId'] -and $_.packageId -eq $defender.payload.packageId
            } |
                Select-Object -First 1
            $state.Apps = @($state.Apps | Where-Object id -NE $remoteDefender.id)

            $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $state)

            @($plan | Where-Object {
                    $_.Kind -eq 'App' -and $_.Action -eq 'Create' -and $_.Target -eq $defender.payload.displayName
                }).Count | Should -Be 1
            @($plan | Where-Object {
                    $_.Kind -eq 'Policy' -and $_.Action -eq 'Update' -and
                    $_.Target -eq 'CaC - Android - Defender and GSA (Child)'
                }).Count | Should -Be 1
        }
    }

    Context 'when an unmanaged app has the same store identity as an approved app' {
        It 'does not propose mutating the unmanaged app' {
            $state = New-FakeTenant -InSync
            $defender = $script:Config.Apps | Where-Object id -EQ 'android-defender'
            $managed = $state.Apps | Where-Object {
                $_.PSObject.Properties['packageId'] -and $_.packageId -eq $defender.payload.packageId
            } |
                Select-Object -First 1
            $state.Apps = @($state.Apps | Where-Object id -NE $managed.id)
            $state.Apps += [pscustomobject]@{
                id          = 'unmanaged-defender'
                packageId   = $defender.payload.packageId
                displayName = 'Portal Defender'
                description = 'created by hand'
            }

            $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $state)
            $appActions = @($plan | Where-Object Target -EQ $defender.payload.displayName)

            @($appActions | Where-Object { $_.Kind -eq 'App' -and $_.Action -in @('Create', 'Update') }) |
                Should -BeNullOrEmpty
        }
    }

    Context 'when the configured bootstrap objects already exist without a marker' {
        BeforeAll {
            $script:AdoptionState = New-FakeTenant -InSync
            $autopilot = $script:AdoptionState.Groups |
                Where-Object displayName -EQ 'CaC-Autopilot-DevicePreparation-Child'
            $autopilot.description = 'Created by the Autopilot bootstrap'
            $autopilot | Add-Member -Force -NotePropertyName securityEnabled -NotePropertyValue $true
            $autopilot | Add-Member -Force -NotePropertyName mailEnabled -NotePropertyValue $false
            $autopilot | Add-Member -Force -NotePropertyName groupTypes -NotePropertyValue @()
            $script:AdoptionState.Members[$autopilot.id] = @(
                [pscustomobject]@{ id = 'device-1'; displayName = 'existing-device' }
            )
            $script:AdoptionPlan = New-CaCPlan -Configuration $script:Config `
                -GraphInvoker (New-FakeInvoker -State $script:AdoptionState)
        }

        It 'plans adoption only for the exact configured bootstrap group' {
            $groupAction = @($script:AdoptionPlan | Where-Object {
                    $_.Kind -eq 'Group' -and $_.Target -eq 'CaC-Autopilot-DevicePreparation-Child'
                })
            $groupAction.Action | Should -Be 'Adopt'
            @($script:AdoptionPlan | Where-Object {
                    $_.Kind -eq 'GroupMembership' -and $_.Target -eq 'CaC-Autopilot-DevicePreparation-Child'
                }) | Should -BeNullOrEmpty
            $script:AdoptionPlan | Format-CaCPlan | Should -Match 'one-time adoption actions'
        }

        It 'fails closed when the group shape does not match' {
            $state = New-FakeTenant -InSync
            $autopilot = $state.Groups | Where-Object displayName -EQ 'CaC-Autopilot-DevicePreparation-Child'
            $autopilot.description = 'Created by the Autopilot bootstrap'
            $autopilot | Add-Member -Force -NotePropertyName securityEnabled -NotePropertyValue $false
            $autopilot | Add-Member -Force -NotePropertyName mailEnabled -NotePropertyValue $false
            $autopilot | Add-Member -Force -NotePropertyName groupTypes -NotePropertyValue @()

            $plan = New-CaCPlan -Configuration $script:Config `
                -GraphInvoker (New-FakeInvoker -State $state)

            @($plan | Where-Object {
                    $_.Action -eq 'Adopt' -and $_.Target -eq 'CaC-Autopilot-DevicePreparation-Child'
                }) | Should -BeNullOrEmpty
            @($plan | Where-Object {
                    $_.Action -eq 'Skip' -and $_.Target -eq 'CaC-Autopilot-DevicePreparation-Child'
                }).Count | Should -BeGreaterThan 0
        }

        It 'does not repeat adoption after the managed marker is established' {
            $adoptionActions = @($script:AdoptionPlan | Where-Object Action -EQ 'Adopt')
            $results = Invoke-CaCPlan -Plan $adoptionActions -Configuration $script:Config `
                -GraphInvoker (New-FakeInvoker -State $script:AdoptionState) -Confirm:$false
            @($results | Where-Object Status -NE 'Applied') | Should -BeNullOrEmpty

            $autopilot = $script:AdoptionState.Groups |
                Where-Object displayName -EQ 'CaC-Autopilot-DevicePreparation-Child'
            $autopilot.description = '{0} {1}' -f $autopilot.description, $script:Config.Tenant.managedMarker

            $second = New-CaCPlan -Configuration $script:Config `
                -GraphInvoker (New-FakeInvoker -State $script:AdoptionState)
            @($second | Where-Object {
                    $_.Action -eq 'Adopt' -and $_.Target -eq 'CaC-Autopilot-DevicePreparation-Child'
                }) | Should -BeNullOrEmpty
        }
    }

    Context 'when a member joins a tier' {
        BeforeAll {
            $script:MemberState = New-FakeTenant -InSync
            $childGroup = @($script:MemberState.Groups | Where-Object displayName -EQ 'CaC-Tier-Child')[0]
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

    It 'applies a JSON-round-tripped reviewed plan without rediscovering ids' {
        $planState = New-FakeTenant -InSync
        $childGroup = @($planState.Groups | Where-Object displayName -EQ 'CaC-Tier-Child')[0]
        $planState.Members[$childGroup.id] = @($planState.Members[$childGroup.id] | Select-Object -Skip 1)
        $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $planState)
        $roundTripped = $plan | ConvertTo-Json -Depth 50 | ConvertFrom-Json

        $applyState = New-FakeTenant -InSync
        $results = Invoke-CaCPlan -Plan $roundTripped -Configuration $script:Config `
            -GraphInvoker (New-FakeInvoker -State $applyState) -Confirm:$false

        @($results | Where-Object Status -in @('Failed', 'Skipped')) | Should -BeNullOrEmpty
        @($applyState.Calls | Where-Object Method -NE 'GET') | Should -Not -BeNullOrEmpty
    }

    It 'preserves app assignments outside the child app catalog scope' {
        $state = New-FakeTenant -InSync
        $app = $state.Apps | Where-Object {
            $_.PSObject.Properties['packageId'] -and $_.packageId -eq 'com.microsoft.scmx'
        } | Select-Object -First 1
        $state.AppAssignments[$app.id] = @([pscustomobject]@{
            intent = 'required'
            target = [pscustomobject]@{
                '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                groupId       = 'external-group'
            }
        })

        $invoker = New-FakeInvoker -State $state
        $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker $invoker
        $null = Invoke-CaCPlan -Plan $plan -Configuration $script:Config -GraphInvoker $invoker -Confirm:$false

        $write = $state.Calls | Where-Object {
            $_.Method -eq 'POST' -and $_.Uri -eq "deviceAppManagement/mobileApps/$($app.id)/assign"
        } | Select-Object -Last 1
        $write.Body.mobileAppAssignments.target.groupId | Should -Contain 'external-group'
    }

    It 'supports -WhatIf so a change can be rehearsed without touching the tenant' {
        $state = New-FakeTenant
        $invoker = New-FakeInvoker -State $state
        $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker $invoker

        $applyState = New-FakeTenant
        $null = Invoke-CaCPlan -Plan $plan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $applyState) -WhatIf

        @($applyState.Calls | Where-Object Method -NE 'GET') | Should -BeNullOrEmpty
    }

    It 'does not take over an unmanaged group with the desired display name' {
        $state = New-FakeTenant
        $group = $script:Config.Groups[0]
        $state.Groups += [pscustomobject]@{
            id          = 'unmanaged-group'
            displayName = $group.displayName
            description = 'created outside config'
        }

        $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $state)
        $match = @($plan | Where-Object { $_.Target -eq $group.displayName })

        $match.Action | Should -Be 'Skip'
        $match.Details -join ' ' | Should -BeLike '*unmanaged group*'
        @($match | Where-Object { $_.Kind -eq 'Group' -and $_.Action -eq 'Create' }) | Should -BeNullOrEmpty
    }

    It 'does not take over an unmanaged app or policy with the desired identity' {
        $state = New-FakeTenant -InSync
        $app = $state.Apps | Where-Object {
            $_.PSObject.Properties['packageId'] -and $_.packageId -eq 'com.microsoft.scmx'
        } | Select-Object -First 1
        $app.description = 'managed by another system'
        $policy = $state.Policies['deviceCompliancePolicies'] |
            Where-Object displayName -EQ 'CaC - Windows - Compliance Baseline'
        $policy.description = 'created outside config'

        $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $state)

        @($plan | Where-Object Target -EQ 'Microsoft Defender' | Where-Object Action -EQ 'Skip') |
            Should -Not -BeNullOrEmpty
        @($plan | Where-Object { $_.Target -eq 'Microsoft Defender' -and $_.Action -in @('Create', 'Update') }) |
            Should -BeNullOrEmpty
        ($plan | Where-Object Target -EQ 'CaC - Windows - Compliance Baseline').Action | Should -Be 'Skip'
        @($plan | Where-Object { $_.Action -in @('Create', 'Update') -and
                $_.Target -in @('Microsoft Defender', 'CaC - Windows - Compliance Baseline') }) |
            Should -BeNullOrEmpty
    }

    It 'fails a dependent policy assignment when its group was skipped' {
        $group = $script:Config.Groups | Where-Object id -EQ 'sg-tier-adult'
        $policy = $script:Config.Policies | Select-Object -First 1
        $plan = @(
            [pscustomobject]@{
                Kind    = 'Group'
                Action  = 'Skip'
                Target  = $group.displayName
                Details = @('unmanaged group')
                Data    = $group
            }
            [pscustomobject]@{
                Kind    = 'Assignment'
                Action  = 'Update'
                Target  = $policy.payload.displayName
                Details = @('include sg-tier-adult')
                Data    = [pscustomobject]@{ Policy = $policy; Id = 'policy-unmanaged' }
            }
        )
        $state = New-FakeTenant
        $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config `
            -GraphInvoker (New-FakeInvoker -State $state) -Confirm:$false

        ($results | Where-Object Action -EQ 'Assign policy').Status | Should -Be 'Failed'
        @($state.Calls | Where-Object Method -NE 'GET') | Should -BeNullOrEmpty
    }

    It 'fails a dependent policy write when its target app was skipped' {
        $app = $script:Config.Apps | Where-Object id -EQ 'android-defender'
        $policy = $script:Config.Policies | Where-Object {
            $_.ContainsKey('targetApps') -and $_.targetApps -contains 'android-defender'
        }
        $plan = @(
            [pscustomobject]@{
                Kind    = 'App'
                Action  = 'Skip'
                Target  = $app.payload.displayName
                Details = @('unmanaged app')
                Data    = $app
            }
            [pscustomobject]@{
                Kind    = 'Policy'
                Action  = 'Update'
                Target  = $policy.payload.displayName
                Details = @('targeted app drift')
                Data    = [pscustomobject]@{ Policy = $policy; Id = 'policy-1' }
            }
        )
        $state = New-FakeTenant
        $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config `
            -GraphInvoker (New-FakeInvoker -State $state) -Confirm:$false

        ($results | Where-Object Action -EQ 'Update policy').Status | Should -Be 'Failed'
        @($state.Calls | Where-Object Method -NE 'GET') | Should -BeNullOrEmpty
    }

    It 'fails a dependent assignment when its policy was skipped' {
        $policy = $script:Config.Policies | Select-Object -First 1
        $plan = @(
            [pscustomobject]@{
                Kind    = 'Policy'
                Action  = 'Skip'
                Target  = $policy.payload.displayName
                Details = @('unmanaged policy')
            }
            [pscustomobject]@{
                Kind    = 'Assignment'
                Action  = 'Update'
                Target  = $policy.payload.displayName
                Details = @('include sg-tier-adult')
                Data    = [pscustomobject]@{ Policy = $policy; Id = 'policy-unmanaged' }
            }
        )
        $state = New-FakeTenant
        $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config `
            -GraphInvoker (New-FakeInvoker -State $state) -Confirm:$false

        ($results | Where-Object Action -EQ 'Assign policy').Status | Should -Be 'Failed'
        @($state.Calls | Where-Object Method -NE 'GET') | Should -BeNullOrEmpty
    }

    It 'fails a dependent app assignment when its app was skipped even if an id is present' {
        $app = $script:Config.Apps | Where-Object id -EQ 'android-defender'
        $plan = @(
            [pscustomobject]@{
                Kind    = 'App'
                Action  = 'Skip'
                Target  = $app.payload.displayName
                Details = @('unmanaged app')
                Data    = $app
            }
            [pscustomobject]@{
                Kind    = 'AppAssignment'
                Action  = 'Update'
                Target  = $app.payload.displayName
                Details = @('required sg-tier-child')
                Data    = [pscustomobject]@{ App = $app; Id = 'app-unmanaged' }
            }
        )
        $state = New-FakeTenant
        $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config `
            -GraphInvoker (New-FakeInvoker -State $state) -Confirm:$false

        ($results | Where-Object Action -EQ 'Assign app').Status | Should -Be 'Failed'
        @($state.Calls | Where-Object Method -NE 'GET') | Should -BeNullOrEmpty
    }

    It 'returns a failed result when a write action fails' {
        $plan = @([pscustomobject]@{
                Kind    = 'Group'
                Action  = 'Create'
                Target  = 'CaC-Tier-Adult'
                Details = @()
                Data    = $script:Config.Groups[0]
            })
        $invoker = {
            param($Method, $Uri, $Body)
            if ($Method -ne 'GET') { throw 'simulated Graph write failure' }
            [pscustomobject]@{ value = @() }
        }

        $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config -GraphInvoker $invoker -Confirm:$false

        ($results | Where-Object Action -EQ 'Create group').Status | Should -Be 'Failed'
        ($results | Where-Object Action -EQ 'Create group').Message | Should -BeLike '*simulated Graph write failure*'
    }

    It 'returns skipped results for plan actions that cannot be applied' {
        $plan = @([pscustomobject]@{
                Kind    = 'App'
                Action  = 'Prerequisite'
                Target  = 'Global Secure Access Client'
                Details = @('package must be added first')
                Data    = $script:Config.Apps | Where-Object id -EQ 'windows-gsa-client'
            })

        $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config `
            -GraphInvoker { param($Method, $Uri, $Body) [pscustomobject]@{ value = @() } } -Confirm:$false

        ($results | Where-Object Target -EQ 'Global Secure Access Client').Status | Should -Be 'Skipped'
    }
}

Describe 'Graph client safety' {
    It 'blocks every write while the session is read-only' {
        InModuleScope IntuneCaC {
            Connect-CaCGraph -TenantId '00000000-0000-0000-0000-000000000000' -AccessToken 'not-a-real-token' -ReadOnly
            { Invoke-CaCGraphRequest -Method POST -Uri 'groups' -Body @{} } | Should -Throw '*read-only*'
        }
    }

    It 'never retries a POST after a possible create timeout' {
        InModuleScope IntuneCaC {
            Connect-CaCGraph -TenantId '00000000-0000-0000-0000-000000000000' `
                -AccessToken 'not-a-real-token'
            $script:requestCount = 0
            Mock Invoke-RestMethod {
                $script:requestCount++
                throw 'simulated timeout after the server accepted the request'
            }

            { Invoke-CaCGraphRequest -Method POST -Uri 'groups' -Body @{} -MaxAttempts 3 } | Should -Throw
            $script:requestCount | Should -Be 1
        }
    }

    It 'surfaces Graph error details when a request ultimately fails' {
        InModuleScope IntuneCaC {
            Connect-CaCGraph -TenantId '00000000-0000-0000-0000-000000000000' `
                -AccessToken 'not-a-real-token'
            Mock Invoke-RestMethod {
                $exception = [System.Exception]::new(
                    'Response status code does not indicate success: 400 (Bad Request).'
                )
                $exception | Add-Member -NotePropertyName Response `
                    -NotePropertyValue ([pscustomobject]@{ StatusCode = 400 })
                $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                    $exception,
                    'MockGraphFailure',
                    [System.Management.Automation.ErrorCategory]::InvalidOperation,
                    $null
                )
                $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
                    '{"error":{"code":"BadRequest","message":"assignment target is invalid"}}'
                )

                throw $errorRecord
            }

            {
                Invoke-CaCGraphRequest -Method POST -Uri 'groups' -Body @{} -MaxAttempts 1
            } | Should -Throw '*Response body: {"error":{"code":"BadRequest","message":"assignment target is invalid"}}*'
        }
    }
}
