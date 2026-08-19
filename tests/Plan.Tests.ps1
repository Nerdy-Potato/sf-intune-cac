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

Describe 'Get-CaCResourceMap' {
    It 'flags deviceEnrollmentConfigurations as requiring a manual portal apply' {
        InModuleScope IntuneCaC {
            (Get-CaCResourceMap -Resource 'deviceEnrollmentConfigurations').RequiresPortalApply | Should -BeTrue
        }
    }

    It 'does not flag any other resource kind' {
        InModuleScope IntuneCaC {
            $map = Get-CaCResourceMap
            $otherKinds = @($map.Keys | Where-Object { $_ -ne 'deviceEnrollmentConfigurations' })
            $otherKinds.Count | Should -BeGreaterThan 0
            foreach ($kind in $otherKinds) {
                ($map[$kind].ContainsKey('RequiresPortalApply') -and $map[$kind].RequiresPortalApply) |
                    Should -Not -BeTrue -Because "resource kind '$kind' must not require a manual portal apply"
            }
        }
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

    Context 'when more than one existing app shares the same store identity' {
        It 'skips the app instead of silently picking one, even when the app is already managed' {
            $state = New-FakeTenant -InSync
            $defender = $script:Config.Apps | Where-Object id -EQ 'android-defender'
            $managed = $state.Apps | Where-Object {
                $_.PSObject.Properties['packageId'] -and $_.packageId -eq $defender.payload.packageId
            } |
                Select-Object -First 1

            # Simulate a second, already-managed duplicate of the same app - the exact shape that
            # let duplicate iOS apps accumulate unnoticed: every prior run picked one of the
            # duplicates via Select-Object -First 1 and never reported the ambiguity.
            $duplicate = $managed.PSObject.Copy()
            $duplicate.id = 'duplicate-of-managed-app'
            $state.Apps += $duplicate

            $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $state)
            # Filter by the config app's own id (not displayName - Android and iOS "Microsoft
            # Defender" share a display name but are different config entries with different ids).
            $defenderAction = @($plan | Where-Object {
                    $_.Kind -eq 'App' -and ($_.Data.id -eq $defender.id -or $_.Data.App.id -eq $defender.id)
                })

            $defenderAction.Count | Should -Be 1
            $defenderAction[0].Action | Should -Be 'Skip'
            $defenderAction[0].Details -join ' ' | Should -BeLike '*more than one existing app*resolve the duplicates*'
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

    Context 'RequiresPortalApply propagation for deviceEnrollmentConfigurations' {
        # Microsoft Graph permanently blocks app-only writes to deviceEnrollmentConfigurations
        # (Microsoft365DSC/Microsoft365DSC#5127). See .squad/decisions.md (2026-08-18 manual-apply
        # contract): New-CaCPlan must stamp RequiresPortalApply = $true on Create/Update/Delete/
        # Assignment actions for this resource kind only, and leave every other resource kind at
        # the default $false so Invoke-CaCPlan can safely skip the Graph write for this kind alone.

        It 'flags Create and its paired Assignment action for every new enrollment restriction' {
            $state = New-FakeTenant
            $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $state)

            $enrollmentCreates = @($plan | Where-Object {
                    $_.Kind -eq 'Policy' -and $_.Action -eq 'Create' -and $_.Data.resource -eq 'deviceEnrollmentConfigurations'
                })
            $enrollmentCreates.Count | Should -BeGreaterThan 0
            @($enrollmentCreates | Where-Object { -not $_.RequiresPortalApply }) | Should -BeNullOrEmpty

            $enrollmentTargets = @($enrollmentCreates | ForEach-Object { $_.Target })
            $enrollmentAssignments = @($plan | Where-Object { $_.Kind -eq 'Assignment' -and $_.Target -in $enrollmentTargets })
            $enrollmentAssignments.Count | Should -Be $enrollmentCreates.Count
            @($enrollmentAssignments | Where-Object { -not $_.RequiresPortalApply }) | Should -BeNullOrEmpty
        }

        It 'leaves every other resource kind at the default RequiresPortalApply = $false' {
            $state = New-FakeTenant
            $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $state)

            $otherCreates = @($plan | Where-Object {
                    $_.Kind -eq 'Policy' -and $_.Action -eq 'Create' -and $_.Data.resource -ne 'deviceEnrollmentConfigurations'
                })
            $otherCreates.Count | Should -BeGreaterThan 0
            @($otherCreates | Where-Object RequiresPortalApply) | Should -BeNullOrEmpty

            $otherAssignments = @($plan | Where-Object {
                    $_.Kind -eq 'Assignment' -and $_.Target -notin (@($plan | Where-Object {
                                $_.Kind -eq 'Policy' -and $_.Data.resource -eq 'deviceEnrollmentConfigurations'
                            }) | ForEach-Object { $_.Target })
                })
            @($otherAssignments | Where-Object RequiresPortalApply) | Should -BeNullOrEmpty
        }

        It 'flags an Update action when a managed enrollment restriction drifts' {
            $state = New-FakeTenant -InSync
            $remoteEnrollment = @($state.Policies['deviceEnrollmentConfigurations'])[0]
            $remoteEnrollment.priority = $remoteEnrollment.priority + 100

            $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $state)

            $update = @($plan | Where-Object { $_.Kind -eq 'Policy' -and $_.Action -eq 'Update' -and $_.Target -eq $remoteEnrollment.displayName })
            $update.Count | Should -Be 1
            $update[0].RequiresPortalApply | Should -BeTrue
        }

        It 'flags a Delete action for an orphaned, no-longer-configured enrollment restriction' {
            $state = New-FakeTenant -InSync -ExtraPolicies @(
                @{
                    Resource = 'deviceEnrollmentConfigurations'
                    Object   = [pscustomobject]@{
                        id          = 'orphan-enrollment-1'
                        displayName = "$($script:Config.Tenant.namePrefix) - Enrollment - Retired Policy"
                        description = $script:Config.Tenant.managedMarker
                    }
                }
            )

            $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $state)

            $delete = @($plan | Where-Object { $_.Action -eq 'Delete' -and $_.Target -eq "$($script:Config.Tenant.namePrefix) - Enrollment - Retired Policy" })
            $delete.Count | Should -Be 1
            $delete[0].RequiresPortalApply | Should -BeTrue
        }

        It 'never reports a RequiresPortalApply item as Skip or Prerequisite, so the plan stays Ready-eligible' {
            # Mirrors the exact blocking predicate used by Assert-CaCReviewedPlan and
            # scripts/Invoke-CaC.ps1's Status computation: Action -in @('Skip', 'Prerequisite').
            # RequiresPortalApply items must never match it, or an unrelated PR would be
            # permanently blocked for no safety benefit (see the manual-apply contract).
            $state = New-FakeTenant
            $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker (New-FakeInvoker -State $state)

            $portalApplyItems = @($plan | Where-Object RequiresPortalApply)
            $portalApplyItems.Count | Should -BeGreaterThan 0
            @($portalApplyItems | Where-Object { $_.Action -in @('Skip', 'Prerequisite') }) | Should -BeNullOrEmpty

            $blocked = @($plan | Where-Object { $_.Action -in @('Skip', 'Prerequisite') })
            $blocked | Should -BeNullOrEmpty
        }
    }
}

Describe 'Format-CaCPlan RequiresPortalApply callout' {
    It 'renders a distinct [!IMPORTANT] banner, separate from the [!CAUTION] blocked banner, listing the affected targets' {
        $plan = @(
            [pscustomobject]@{
                Kind                = 'Policy'
                Action              = 'Create'
                Target              = 'CaC - Enrollment - Corporate-Owned Child Devices (Android)'
                Details             = @('resource: deviceEnrollmentConfigurations')
                Data                = $null
                RequiresPortalApply = $true
            }
        )

        $markdown = $plan | Format-CaCPlan

        $markdown | Should -Match '\[!IMPORTANT\]'
        $markdown | Should -BeLike '*Microsoft365DSC/Microsoft365DSC#5127*'
        $markdown | Should -BeLike '*Enrollment restrictions*'
        $markdown | Should -BeLike '*CaC - Enrollment - Corporate-Owned Child Devices (Android)*'
        $markdown | Should -Not -Match '\[!CAUTION\]'
    }

    It 'does not render the callout when no plan item requires a manual portal apply' {
        $plan = @(
            [pscustomobject]@{
                Kind                = 'Group'
                Action              = 'Create'
                Target              = 'CaC-Tier-Adult'
                Details             = @()
                Data                = $null
                RequiresPortalApply = $false
            }
        )

        ($plan | Format-CaCPlan) | Should -Not -Match '\[!IMPORTANT\]'
    }

    It 'does not confuse a RequiresPortalApply item with a blocked Skip/Prerequisite item' {
        $plan = @(
            [pscustomobject]@{
                Kind                = 'Policy'
                Action              = 'Create'
                Target              = 'CaC - Enrollment - Corporate-Owned Child Devices (Android)'
                Details             = @()
                Data                = $null
                RequiresPortalApply = $true
            }
            [pscustomobject]@{
                Kind                = 'App'
                Action              = 'Prerequisite'
                Target              = 'Global Secure Access Client'
                Details             = @('package must be added first')
                Data                = $null
                RequiresPortalApply = $false
            }
        )

        $markdown = $plan | Format-CaCPlan
        $markdown | Should -Match '\[!IMPORTANT\]'
        $markdown | Should -Match '\[!CAUTION\]'
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

    It 'never sends appStoreUrl in an iosStoreApp update PATCH, even when only description drifted' {
        $state = New-FakeTenant -InSync
        $copilot = $script:Config.Apps | Where-Object id -EQ 'ios-copilot'
        $remoteCopilot = $state.Apps | Where-Object {
            $_.PSObject.Properties['bundleId'] -and $_.bundleId -eq $copilot.payload.bundleId
        } | Select-Object -First 1
        $remoteCopilot.description = 'stale description from before this app was managed. Managed by sf-intune-cac.'

        $invoker = New-FakeInvoker -State $state
        $plan = New-CaCPlan -Configuration $script:Config -GraphInvoker $invoker
        $updateAction = $plan | Where-Object { $_.Kind -eq 'App' -and $_.Target -eq $copilot.payload.displayName -and $_.Action -eq 'Update' }
        $updateAction | Should -Not -BeNullOrEmpty

        $applyState = New-FakeTenant -InSync
        $applyCopilot = $applyState.Apps | Where-Object {
            $_.PSObject.Properties['bundleId'] -and $_.bundleId -eq $copilot.payload.bundleId
        } | Select-Object -First 1
        $applyCopilot.description = $remoteCopilot.description
        $applyInvoker = New-FakeInvoker -State $applyState

        $null = Invoke-CaCPlan -Plan @($updateAction) -Configuration $script:Config -GraphInvoker $applyInvoker -Confirm:$false

        $patchCall = $applyState.Calls | Where-Object { $_.Method -eq 'PATCH' -and $_.Uri -like "deviceAppManagement/mobileApps/$($remoteCopilot.id)" }
        $patchCall | Should -Not -BeNullOrEmpty
        $patchCall.Body.ContainsKey('appStoreUrl') | Should -BeFalse -Because 'Graph rejects any PATCH to an iosStoreApp that includes appStoreUrl, even unchanged'
        $patchCall.Body.displayName | Should -Be $copilot.payload.displayName
    }

    It 'waits for a store app to reach the published state before assigning it' {
        $app = [pscustomobject]@{
            id          = 'android-edge'
            payload      = @{
                '@odata.type' = '#microsoft.graph.managedAndroidStoreApp'
                displayName   = 'Microsoft Edge'
            }
            assignments = @()
        }
        $plan = @(
            [pscustomobject]@{
                Kind    = 'App'
                Action  = 'Create'
                Target  = $app.payload.displayName
                Details = @()
                Data    = $app
            }
            [pscustomobject]@{
                Kind    = 'AppAssignment'
                Action  = 'Update'
                Target  = $app.payload.displayName
                Details = @('required sg-tier-child')
                Data    = [pscustomobject]@{ App = $app }
            }
        )
        $calls = [System.Collections.Generic.List[object]]::new()
        $publishingStates = [System.Collections.Generic.Queue[string]]::new()
        @('processing', 'published') | ForEach-Object { $publishingStates.Enqueue($_) }
        $invoker = {
            param($Method, $Uri, $Body)

            $calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body })

            switch ("$Method $Uri") {
                'POST deviceAppManagement/mobileApps' { return [pscustomobject]@{ id = 'created-app' } }
                'POST deviceAppManagement/mobileApps/created-app/assign' { return [pscustomobject]@{} }
            }

            if ($Method -eq 'GET' -and $Uri -eq 'deviceAppManagement/mobileApps/created-app') {
                return [pscustomobject]@{
                    id              = 'created-app'
                    publishingState = $publishingStates.Dequeue()
                }
            }

            throw "Unexpected call: $Method $Uri"
        }.GetNewClosure()

        Mock Start-Sleep {} -ModuleName IntuneCaC
        $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config -GraphInvoker $invoker -Confirm:$false

        ($results | Where-Object Action -EQ 'Assign app').Status | Should -Be 'Applied'
        @($calls | Where-Object {
                $_.Method -eq 'GET' -and $_.Uri -eq 'deviceAppManagement/mobileApps/created-app'
            }).Count | Should -Be 2
        ($calls | ForEach-Object { "$($_.Method) $($_.Uri)" }) | Should -Be @(
            'POST deviceAppManagement/mobileApps'
            'GET deviceAppManagement/mobileApps/created-app'
            'GET deviceAppManagement/mobileApps/created-app'
            'POST deviceAppManagement/mobileApps/created-app/assign'
        )
    }

    It 'proceeds to assign an app after the publish wait budget is exhausted' {
        $app = [pscustomobject]@{
            id          = 'android-word'
            payload      = @{
                '@odata.type' = '#microsoft.graph.managedAndroidStoreApp'
                displayName   = 'Microsoft Word'
            }
            assignments = @()
        }
        $plan = @(
            [pscustomobject]@{
                Kind    = 'App'
                Action  = 'Create'
                Target  = $app.payload.displayName
                Details = @()
                Data    = $app
            }
            [pscustomobject]@{
                Kind    = 'AppAssignment'
                Action  = 'Update'
                Target  = $app.payload.displayName
                Details = @('required sg-tier-child')
                Data    = [pscustomobject]@{ App = $app }
            }
        )
        $calls = [System.Collections.Generic.List[object]]::new()
        $invoker = {
            param($Method, $Uri, $Body)

            $calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body })

            switch ("$Method $Uri") {
                'POST deviceAppManagement/mobileApps' { return [pscustomobject]@{ id = 'created-app' } }
                'POST deviceAppManagement/mobileApps/created-app/assign' { return [pscustomobject]@{} }
            }

            if ($Method -eq 'GET' -and $Uri -eq 'deviceAppManagement/mobileApps/created-app') {
                return [pscustomobject]@{
                    id              = 'created-app'
                    publishingState = 'processing'
                }
            }

            throw "Unexpected call: $Method $Uri"
        }.GetNewClosure()

        Mock Start-Sleep {} -ModuleName IntuneCaC
        $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config -GraphInvoker $invoker -Confirm:$false

        ($results | Where-Object Action -EQ 'Assign app').Status | Should -Be 'Applied'
        @($calls | Where-Object {
                $_.Method -eq 'GET' -and $_.Uri -eq 'deviceAppManagement/mobileApps/created-app'
            }).Count | Should -Be 7
        ($calls | Select-Object -Last 1 | ForEach-Object { "$($_.Method) $($_.Uri)" }) |
            Should -Be 'POST deviceAppManagement/mobileApps/created-app/assign'
    }

    It 'uses a shared publish polling budget across multiple app assignments' {
        $apps = @(
            [pscustomobject]@{
                id          = 'android-edge'
                payload      = @{
                    '@odata.type' = '#microsoft.graph.managedAndroidStoreApp'
                    displayName   = 'Microsoft Edge'
                }
                assignments = @()
            },
            [pscustomobject]@{
                id          = 'android-word'
                payload      = @{
                    '@odata.type' = '#microsoft.graph.managedAndroidStoreApp'
                    displayName   = 'Microsoft Word'
                }
                assignments = @()
            },
            [pscustomobject]@{
                id          = 'android-portal'
                payload      = @{
                    '@odata.type' = '#microsoft.graph.managedAndroidStoreApp'
                    displayName   = 'Company Portal'
                }
                assignments = @()
            }
        )

        $plan = foreach ($app in $apps) {
            [pscustomobject]@{
                Kind    = 'App'
                Action  = 'Create'
                Target  = $app.payload.displayName
                Details = @()
                Data    = $app
            }
            [pscustomobject]@{
                Kind    = 'AppAssignment'
                Action  = 'Update'
                Target  = $app.payload.displayName
                Details = @('required sg-tier-child')
                Data    = [pscustomobject]@{ App = $app }
            }
        }

        $calls = [System.Collections.Generic.List[object]]::new()
        $createdIds = @{
            'Microsoft Edge'  = 'created-edge'
            'Microsoft Word'  = 'created-word'
            'Company Portal'  = 'created-portal'
        }
        $publishingStates = @{
            'created-edge'   = [System.Collections.Generic.Queue[string]]::new()
            'created-word'   = [System.Collections.Generic.Queue[string]]::new()
            'created-portal' = [System.Collections.Generic.Queue[string]]::new()
        }
        @('processing', 'published') | ForEach-Object { $publishingStates['created-edge'].Enqueue($_) }
        @('processing', 'processing', 'processing', 'processing', 'processing', 'processing', 'processing') |
            ForEach-Object { $publishingStates['created-word'].Enqueue($_) }
        @('published') | ForEach-Object { $publishingStates['created-portal'].Enqueue($_) }

        $invoker = {
            param($Method, $Uri, $Body)

            $calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body })

            if ($Method -eq 'POST' -and $Uri -eq 'deviceAppManagement/mobileApps') {
                return [pscustomobject]@{ id = $createdIds[$Body.displayName] }
            }

            if ($Method -eq 'GET' -and $Uri -like 'deviceAppManagement/mobileApps/*') {
                $appId = ($Uri -split '/')[-1]
                return [pscustomobject]@{
                    id              = $appId
                    publishingState = $publishingStates[$appId].Dequeue()
                }
            }

            if ($Method -eq 'POST' -and $Uri -like 'deviceAppManagement/mobileApps/*/assign') {
                return [pscustomobject]@{}
            }

            throw "Unexpected call: $Method $Uri"
        }.GetNewClosure()

        Mock Start-Sleep {} -ModuleName IntuneCaC
        $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config -GraphInvoker $invoker -Confirm:$false

        ($results | Where-Object Action -EQ 'Assign app').Status | Should -Be @('Applied', 'Applied', 'Applied')
        @($calls | Where-Object {
                $_.Method -eq 'GET' -and $_.Uri -eq 'deviceAppManagement/mobileApps/created-edge'
            }).Count | Should -Be 2
        @($calls | Where-Object {
                $_.Method -eq 'GET' -and $_.Uri -eq 'deviceAppManagement/mobileApps/created-word'
            }).Count | Should -Be 7
        @($calls | Where-Object {
                $_.Method -eq 'GET' -and $_.Uri -eq 'deviceAppManagement/mobileApps/created-portal'
            }).Count | Should -Be 1
        @($calls | Where-Object {
                $_.Method -eq 'GET' -and $_.Uri -like 'deviceAppManagement/mobileApps/created-*'
            }).Count | Should -Be 10
        @($calls | Where-Object {
                $_.Method -eq 'POST' -and $_.Uri -like 'deviceAppManagement/mobileApps/*/assign'
            }).Count | Should -Be 3
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

    It 'fails a policy update cleanly when the reviewed action data is missing' {
        $plan = @([pscustomobject]@{
                Kind    = 'Policy'
                Action  = 'Update'
                Target  = 'CaC - iOS - Device Restrictions (Teen)'
                Details = @('payload drift')
            })

        $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config `
            -GraphInvoker { param($Method, $Uri, $Body) throw "Unexpected call: $Method $Uri" } -Confirm:$false

        ($results | Where-Object Action -EQ 'Update policy').Status | Should -Be 'Failed'
        ($results | Where-Object Action -EQ 'Update policy').Message |
            Should -Be 'policy data is missing from the reviewed plan'
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

    Context 'RequiresPortalApply actions (deviceEnrollmentConfigurations manual-apply contract)' {
        BeforeAll {
            $script:EnrollmentPolicy = $script:Config.Policies | Where-Object resource -EQ 'deviceEnrollmentConfigurations' | Select-Object -First 1
            $script:EnrollmentEndpoint = InModuleScope IntuneCaC { Get-CaCResourceMap -Resource 'deviceEnrollmentConfigurations' }

            # Fails the test loudly if Invoke-CaCPlan ever attempts a Graph write for a
            # RequiresPortalApply action - the entire point of the contract is that it never does.
            function New-CaCNoGraphWriteInvoker {
                return {
                    param($Method, $Uri, $Body)
                    if ($Method -ne 'GET') {
                        throw "Unexpected Graph write for a RequiresPortalApply action: $Method $Uri"
                    }
                    [pscustomobject]@{ value = @() }
                }
            }
        }

        It 'never calls Graph and reports ManualActionRequired for a Create action' {
            $plan = @([pscustomobject]@{
                    Kind                = 'Policy'
                    Action              = 'Create'
                    Target              = $script:EnrollmentPolicy.payload.displayName
                    Details             = @('resource: deviceEnrollmentConfigurations')
                    Data                = $script:EnrollmentPolicy
                    RequiresPortalApply = $true
                })

            $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config `
                -GraphInvoker (New-CaCNoGraphWriteInvoker) -Confirm:$false

            $result = $results | Where-Object Target -EQ $script:EnrollmentPolicy.payload.displayName
            $result.Status | Should -Be 'ManualActionRequired'
        }

        It 'never calls Graph and reports ManualActionRequired for an Update action' {
            $plan = @([pscustomobject]@{
                    Kind                = 'Policy'
                    Action              = 'Update'
                    Target              = $script:EnrollmentPolicy.payload.displayName
                    Details             = @('priority: 1 -> 2')
                    Data                = [pscustomobject]@{ Policy = $script:EnrollmentPolicy; Id = 'existing-enrollment-id' }
                    RequiresPortalApply = $true
                })

            $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config `
                -GraphInvoker (New-CaCNoGraphWriteInvoker) -Confirm:$false

            $result = $results | Where-Object Target -EQ $script:EnrollmentPolicy.payload.displayName
            $result.Status | Should -Be 'ManualActionRequired'
            $result.Message | Should -BeLike '*existing-enrollment-id*'
        }

        It 'never calls Graph and reports ManualActionRequired for a create-path Assignment action' {
            $plan = @([pscustomobject]@{
                    Kind                = 'Assignment'
                    Action              = 'Update'
                    Target              = $script:EnrollmentPolicy.payload.displayName
                    Details             = @('include sg-tier-child')
                    Data                = $script:EnrollmentPolicy
                    RequiresPortalApply = $true
                })

            $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config `
                -GraphInvoker (New-CaCNoGraphWriteInvoker) -Confirm:$false

            (($results | Where-Object Target -EQ $script:EnrollmentPolicy.payload.displayName)).Status |
                Should -Be 'ManualActionRequired'
        }

        It 'never calls Graph and reports ManualActionRequired for a drift-path Assignment action' {
            $plan = @([pscustomobject]@{
                    Kind                = 'Assignment'
                    Action              = 'Update'
                    Target              = $script:EnrollmentPolicy.payload.displayName
                    Details             = @('add: sg-tier-teen')
                    Data                = [pscustomobject]@{ Policy = $script:EnrollmentPolicy; Id = 'existing-enrollment-id' }
                    RequiresPortalApply = $true
                })

            $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config `
                -GraphInvoker (New-CaCNoGraphWriteInvoker) -Confirm:$false

            (($results | Where-Object Target -EQ $script:EnrollmentPolicy.payload.displayName)).Status |
                Should -Be 'ManualActionRequired'
        }

        It 'never calls Graph and reports ManualActionRequired for an orphan Delete action, even with -AllowDelete' {
            $plan = @([pscustomobject]@{
                    Kind                = 'Policy'
                    Action              = 'Delete'
                    Target              = 'CaC - Enrollment - Retired Policy'
                    Details             = @('no longer defined in config')
                    Data                = [pscustomobject]@{ Id = 'orphan-enrollment-id'; Endpoint = $script:EnrollmentEndpoint }
                    RequiresPortalApply = $true
                })

            foreach ($allowDelete in @($false, $true)) {
                $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config `
                    -GraphInvoker (New-CaCNoGraphWriteInvoker) -AllowDelete:$allowDelete -Confirm:$false

                $result = $results | Where-Object Target -EQ 'CaC - Enrollment - Retired Policy'
                $result.Status | Should -Be 'ManualActionRequired' -Because "AllowDelete=$allowDelete must not change this outcome"
                $result.Message | Should -BeLike '*orphan-enrollment-id*'
            }
        }

        It 'includes the portal blade path and the confirmed evidence reference in every manual-action message' {
            $plan = @([pscustomobject]@{
                    Kind                = 'Policy'
                    Action              = 'Create'
                    Target              = $script:EnrollmentPolicy.payload.displayName
                    Details             = @('resource: deviceEnrollmentConfigurations')
                    Data                = $script:EnrollmentPolicy
                    RequiresPortalApply = $true
                })

            $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config `
                -GraphInvoker (New-CaCNoGraphWriteInvoker) -Confirm:$false

            $message = ($results | Where-Object Target -EQ $script:EnrollmentPolicy.payload.displayName).Message
            $message | Should -BeLike '*Enrollment restrictions*'
            $message | Should -BeLike '*Microsoft365DSC/Microsoft365DSC#5127*'
            $message | Should -BeLike '*rest of this deployment completed normally*'
        }

        It 'still applies unrelated actions in the same plan alongside a RequiresPortalApply item' {
            $group = $script:Config.Groups[0]
            $plan = @(
                [pscustomobject]@{
                    Kind                = 'Policy'
                    Action              = 'Create'
                    Target              = $script:EnrollmentPolicy.payload.displayName
                    Details             = @('resource: deviceEnrollmentConfigurations')
                    Data                = $script:EnrollmentPolicy
                    RequiresPortalApply = $true
                }
                [pscustomobject]@{
                    Kind    = 'Group'
                    Action  = 'Create'
                    Target  = $group.displayName
                    Details = @()
                    Data    = $group
                }
            )
            $state = New-FakeTenant
            $results = Invoke-CaCPlan -Plan $plan -Configuration $script:Config `
                -GraphInvoker (New-FakeInvoker -State $state) -Confirm:$false

            ($results | Where-Object Target -EQ $script:EnrollmentPolicy.payload.displayName).Status |
                Should -Be 'ManualActionRequired'
            ($results | Where-Object Target -EQ $group.displayName).Status | Should -Be 'Applied'
        }
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
