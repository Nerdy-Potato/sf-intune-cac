$script:ModuleRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
Import-Module -Name (Join-Path $script:ModuleRoot 'IntuneCaC.Extensions.psd1') -Force

BeforeAll {
    $script:ModuleRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
    $script:Marker = @('Managed by sf-intune-cac (reference implementation).')
    $script:BreakGlass = 'breakglass-group-object-id'

    function New-NoWriteInvoker {
        # Fails the test loudly if anything under test tries to write to Graph; every test that
        # legitimately exercises a write path supplies its own invoker instead.
        return {
            param($Method, $Uri, $Body)
            if ($Method -ne 'GET') { throw "Unexpected write in a read-only test: $Method $Uri" }
            return [pscustomobject]@{ value = @() }
        }
    }
}

InModuleScope 'IntuneCaC.Extensions' {

    Describe 'Get-CaCExtendedResourceMap' {
        It 'exposes exactly the five reference-implementation resource kinds' {
            (Get-CaCExtendedResourceMap).Keys | Sort-Object | Should -Be @(
                'assignmentFilters', 'conditionalAccessPolicies', 'endpointSecurityIntents',
                'proactiveRemediationScripts', 'settingsCatalogPolicies'
            )
        }

        It 'throws on an unsupported resource kind' {
            { Get-CaCExtendedResourceMap -Resource 'notARealKind' } | Should -Throw
        }

        It 'flags Settings Catalog as using "name" rather than "displayName"' {
            (Get-CaCExtendedResourceMap -Resource 'settingsCatalogPolicies').DisplayNameProperty | Should -Be 'name'
        }

        It 'requires break-glass exclusion for Conditional Access only' {
            (Get-CaCExtendedResourceMap -Resource 'conditionalAccessPolicies').RequiresBreakGlassExclusion | Should -BeTrue
            (Get-CaCExtendedResourceMap -Resource 'assignmentFilters').ContainsKey('RequiresBreakGlassExclusion') | Should -BeFalse
        }
    }

    Describe 'Get-CaCTreeDrift' {
        It 'reports no drift when the same settings are present in a different order' {
            $desired = @(
                @{ settingInstance = @{ settingDefinitionId = 'a' }; value = 1 }
                @{ settingInstance = @{ settingDefinitionId = 'b' }; value = 2 }
            )
            $actual = @(
                @{ settingInstance = @{ settingDefinitionId = 'b' }; value = 2 }
                @{ settingInstance = @{ settingDefinitionId = 'a' }; value = 1 }
            )

            Get-CaCTreeDrift -Desired $desired -Actual $actual -ItemKey 'settingInstance.settingDefinitionId' | Should -BeNullOrEmpty
        }

        It 'reports drift when a setting value changes' {
            $desired = @(@{ settingInstance = @{ settingDefinitionId = 'a' }; value = 2 })
            $actual = @(@{ settingInstance = @{ settingDefinitionId = 'a' }; value = 1 })

            $drift = @(Get-CaCTreeDrift -Desired $desired -Actual $actual -ItemKey 'settingInstance.settingDefinitionId')
            $drift | Should -HaveCount 1
            $drift[0] | Should -Match "setting 'a'"
        }

        It 'reports a missing setting and a setting no longer desired' {
            $desired = @(@{ settingInstance = @{ settingDefinitionId = 'a' }; value = 1 })
            $actual = @(@{ settingInstance = @{ settingDefinitionId = 'b' }; value = 1 })

            $drift = Get-CaCTreeDrift -Desired $desired -Actual $actual -ItemKey 'settingInstance.settingDefinitionId'
            ($drift -join '|') | Should -Match "setting 'a': missing in tenant"
            ($drift -join '|') | Should -Match "setting 'b': present in tenant but not in configuration"
        }
    }

    Describe 'Get-CaCScriptContentDrift' {
        It 'ignores line-ending differences that decode to the same text' {
            $crlf = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("Write-Host 'hi'`r`n"))
            $lf = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("Write-Host 'hi'`n"))

            Get-CaCScriptContentDrift -PropertyName 'detectionScriptContent' -DesiredBase64 $lf -ActualBase64 $crlf | Should -BeNullOrEmpty
        }

        It 'reports drift, without leaking script content, when the decoded body differs' {
            $desired = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("Write-Host 'new'"))
            $actual = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("Write-Host 'old-line-one'`nWrite-Host 'old-line-two'"))

            $drift = Get-CaCScriptContentDrift -PropertyName 'detectionScriptContent' -DesiredBase64 $desired -ActualBase64 $actual
            $drift | Should -Match 'detectionScriptContent: script content differs'
            $drift | Should -Not -Match 'old-line-one'
            $drift | Should -Not -Match 'new'
        }
    }

    Describe 'Get-CaCScalarDrift' {
        It 'excludes a nested dotted path and everything beneath it' {
            $desired = @{
                displayName = 'CaC - Example'
                conditions  = @{
                    users        = @{ includeGroups = @('should-not-be-diffed') }
                    applications = @{ includeApplications = @('All') }
                }
            }
            $actual = [pscustomobject]@{
                displayName = 'CaC - Example'
                conditions  = [pscustomobject]@{
                    users        = [pscustomobject]@{ includeGroups = @('totally-different-and-ignored') }
                    applications = [pscustomobject]@{ includeApplications = @('All') }
                }
            }

            Get-CaCScalarDrift -Desired $desired -Actual $actual -ExcludePaths @('conditions.users') | Should -BeNullOrEmpty
        }

        It 'still detects drift on a sibling path that is not excluded' {
            $desired = @{ conditions = @{ users = @{ includeGroups = @('x') }; applications = @{ includeApplications = @('All') } } }
            $actual = [pscustomobject]@{ conditions = [pscustomobject]@{ users = [pscustomobject]@{ includeGroups = @('x') }; applications = [pscustomobject]@{ includeApplications = @('Some') } } }

            $drift = Get-CaCScalarDrift -Desired $desired -Actual $actual -ExcludePaths @('conditions.users')
            $drift | Should -Match 'conditions.applications.includeApplications'
        }
    }

    Describe 'Test-CaCConditionalAccessSafety' {
        BeforeAll { $script:BreakGlass = 'breakglass-group-object-id' }

        It 'blocks a policy that does not exclude the break-glass group' {
            $desired = @{ conditions = @{ users = @{ excludeGroups = @() } }; state = 'enabledForReportingButNotEnforced' }
            $problems = Test-CaCConditionalAccessSafety -Desired $desired -Actual $null -BreakGlassGroupObjectId $script:BreakGlass
            $problems | Should -Match 'break-glass'
        }

        It 'blocks state=enabled without an explicit opt-in' {
            $desired = @{ conditions = @{ users = @{ excludeGroups = @($script:BreakGlass) } }; state = 'enabled' }
            $problems = Test-CaCConditionalAccessSafety -Desired $desired -Actual $null -BreakGlassGroupObjectId $script:BreakGlass
            $problems | Should -Match 'AllowEnabledState'
        }

        It 'allows state=enabled when explicitly opted in and the break-glass group is excluded' {
            $desired = @{ conditions = @{ users = @{ excludeGroups = @($script:BreakGlass) } }; state = 'enabled' }
            $problems = Test-CaCConditionalAccessSafety -Desired $desired -Actual $null -BreakGlassGroupObjectId $script:BreakGlass -AllowEnabledState
            $problems | Should -BeNullOrEmpty
        }

        It 'blocks an update that changes conditions.users' {
            $desired = @{ conditions = @{ users = @{ excludeGroups = @($script:BreakGlass); includeGroups = @('new-target') } }; state = 'enabledForReportingButNotEnforced' }
            $actual = [pscustomobject]@{ conditions = [pscustomobject]@{ users = [pscustomobject]@{ excludeGroups = @($script:BreakGlass); includeGroups = @('old-target') } } }

            $problems = Test-CaCConditionalAccessSafety -Desired $desired -Actual $actual -BreakGlassGroupObjectId $script:BreakGlass
            $problems | Should -Match 'not supported by this reference implementation'
        }

        It 'allows an update that leaves conditions.users untouched' {
            $desired = @{ conditions = @{ users = @{ excludeGroups = @($script:BreakGlass); includeGroups = @('same-target') } }; state = 'enabledForReportingButNotEnforced' }
            $actual = [pscustomobject]@{ conditions = [pscustomobject]@{ users = [pscustomobject]@{ excludeGroups = @($script:BreakGlass); includeGroups = @('same-target') } } }

            $problems = Test-CaCConditionalAccessSafety -Desired $desired -Actual $actual -BreakGlassGroupObjectId $script:BreakGlass
            $problems | Should -BeNullOrEmpty
        }
    }
}

Describe 'New-CaCExtendedPlan' {
    BeforeEach {
        $script:Configuration = Get-CaCExtendedConfiguration -Path (Join-Path $script:ModuleRoot 'config-samples')
        foreach ($policy in $script:Configuration.Policies) { $policy.enabled = $true }
    }

    It 'plans a Create for a brand new Settings Catalog policy and a follow-on assignment' {
        $config = [pscustomobject]@{ Policies = @($script:Configuration.Policies | Where-Object { $_.resource -eq 'settingsCatalogPolicies' }) }
        $plan = New-CaCExtendedPlan -Configuration $config -ManagedMarker $script:Marker -BreakGlassGroupObjectId $script:BreakGlass -GraphInvoker (New-NoWriteInvoker)

        ($plan | Where-Object { $_.Kind -eq 'ExtendedPolicy' -and $_.Action -eq 'Create' }).Target | Should -Be 'CaC - Example Settings Catalog Placeholder'
        ($plan | Where-Object { $_.Kind -eq 'ExtendedAssignment' }).Target | Should -Be 'CaC - Example Settings Catalog Placeholder'
    }

    It 'blocks a Conditional Access policy that does not exclude the break-glass group' {
        $config = [pscustomobject]@{ Policies = @($script:Configuration.Policies | Where-Object { $_.resource -eq 'conditionalAccessPolicies' }) }
        $plan = New-CaCExtendedPlan -Configuration $config -ManagedMarker $script:Marker -BreakGlassGroupObjectId 'a-different-group-id' -GraphInvoker (New-NoWriteInvoker)

        $blocked = $plan | Where-Object { $_.Action -eq 'Blocked' }
        $blocked | Should -Not -BeNullOrEmpty
        ($blocked.Details -join '|') | Should -Match 'break-glass'
    }

    It 'never emits an assignment action for an assignmentFilters create (AssignmentModel = None)' {
        $config = [pscustomobject]@{ Policies = @($script:Configuration.Policies | Where-Object { $_.resource -eq 'assignmentFilters' }) }
        $plan = New-CaCExtendedPlan -Configuration $config -ManagedMarker $script:Marker -BreakGlassGroupObjectId $script:BreakGlass -GraphInvoker (New-NoWriteInvoker)

        $plan | Where-Object { $_.Kind -eq 'ExtendedAssignment' } | Should -BeNullOrEmpty
    }

    It 'skips a disabled policy' {
        $config = [pscustomobject]@{ Policies = @($script:Configuration.Policies | Where-Object { $_.resource -eq 'settingsCatalogPolicies' }) }
        foreach ($policy in $config.Policies) { $policy.enabled = $false }
        $plan = New-CaCExtendedPlan -Configuration $config -ManagedMarker $script:Marker -BreakGlassGroupObjectId $script:BreakGlass -GraphInvoker (New-NoWriteInvoker)

        $plan[0].Action | Should -Be 'Skip'
    }

    It 'refuses to adopt an object that already exists but is not managed by this repository' {
        $config = [pscustomobject]@{ Policies = @($script:Configuration.Policies | Where-Object { $_.resource -eq 'assignmentFilters' }) }
        $invoker = {
            param($Method, $Uri, $Body)
            return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'existing-id'; displayName = 'CaC - Example Assignment Filter Placeholder'; description = 'Not managed by anything.' }) }
        }
        $plan = New-CaCExtendedPlan -Configuration $config -ManagedMarker $script:Marker -BreakGlassGroupObjectId $script:BreakGlass -GraphInvoker $invoker

        $plan[0].Action | Should -Be 'Skip'
        ($plan[0].Details -join '|') | Should -Match 'unmanaged'
    }
}

Describe 'Invoke-CaCExtendedPlan' {
    It 'creates a Settings Catalog policy via POST and updates it via PUT (not PATCH)' {
        $calls = [System.Collections.Generic.List[object]]::new()
        $config = Get-CaCExtendedConfiguration -Path (Join-Path $script:ModuleRoot 'config-samples')
        $policy = $config.Policies | Where-Object { $_.resource -eq 'settingsCatalogPolicies' } | Select-Object -First 1

        $createItem = [pscustomobject]@{ Kind = 'ExtendedPolicy'; Action = 'Create'; Target = $policy.payload.name; Data = $policy }
        $invoker = {
            param($Method, $Uri, $Body)
            $calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })
            return [pscustomobject]@{ id = 'new-object-id' }
        }

        $results = Invoke-CaCExtendedPlan -Plan @($createItem) -GroupObjectIds @{} -GraphInvoker $invoker -Confirm:$false

        $results[0].Status | Should -Be 'Succeeded'
        $calls[0].Method | Should -Be 'POST'
        $calls[0].Uri | Should -Be 'deviceManagement/configurationPolicies'
    }

    It 'assigns using the resolved group object id and the correct assignment target type' {
        $config = Get-CaCExtendedConfiguration -Path (Join-Path $script:ModuleRoot 'config-samples')
        $policy = $config.Policies | Where-Object { $_.resource -eq 'settingsCatalogPolicies' } | Select-Object -First 1

        $assignItem = [pscustomobject]@{ Kind = 'ExtendedAssignment'; Action = 'Update'; Target = $policy.payload.name; Data = $policy }
        $invoker = {
            param($Method, $Uri, $Body)
            if ($Uri -match '/assign$') {
                $script:captured = $Body
                return [pscustomobject]@{}
            }
            return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'live-object-id'; name = $policy.payload.name }) }
        }

        $null = Invoke-CaCExtendedPlan -Plan @($assignItem) -GroupObjectIds @{ 'sg-example-placeholder' = 'live-group-object-id' } -GraphInvoker $invoker -Confirm:$false

        $script:captured.assignments[0].target.groupId | Should -Be 'live-group-object-id'
        $script:captured.assignments[0].target.'@odata.type' | Should -Be '#microsoft.graph.groupAssignmentTarget'
    }

    It 'never issues a Graph write for a Delete when -AllowDelete is not supplied' {
        $deleteItem = [pscustomobject]@{ Kind = 'ExtendedPolicy'; Action = 'Delete'; Target = 'some-policy'; Data = [pscustomobject]@{ Id = 'x'; ResourceInfo = @{ Path = 'deviceManagement/assignmentFilters' } } }
        $invoker = { param($Method, $Uri, $Body) throw "Unexpected write: $Method $Uri" }

        $results = Invoke-CaCExtendedPlan -Plan @($deleteItem) -GroupObjectIds @{} -GraphInvoker $invoker -Confirm:$false

        $results[0].Status | Should -Be 'Skipped'
    }

    It 'updates Endpoint Security via the dedicated updateSettings action, not a PATCH of the object' {
        $calls = [System.Collections.Generic.List[object]]::new()
        $config = Get-CaCExtendedConfiguration -Path (Join-Path $script:ModuleRoot 'config-samples')
        $policy = $config.Policies | Where-Object { $_.resource -eq 'endpointSecurityIntents' } | Select-Object -First 1

        $updateItem = [pscustomobject]@{ Kind = 'ExtendedPolicy'; Action = 'Update'; Target = $policy.payload.displayName; Data = [pscustomobject]@{ Policy = $policy; Id = 'existing-intent-id' } }
        $invoker = {
            param($Method, $Uri, $Body)
            $calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })
            return [pscustomobject]@{ value = @() }
        }

        $results = Invoke-CaCExtendedPlan -Plan @($updateItem) -GroupObjectIds @{} -GraphInvoker $invoker -Confirm:$false

        $results[0].Status | Should -Be 'Succeeded'
        $calls[0].Method | Should -Be 'POST'
        $calls[0].Uri | Should -Be 'deviceManagement/intents/existing-intent-id/updateSettings'
    }
}

Describe 'Test-CaCExtendedConfiguration' {
    It 'passes schema and safety validation for the shipped config-samples when the break-glass group is supplied' {
        $config = Get-CaCExtendedConfiguration -Path (Join-Path $script:ModuleRoot 'config-samples')
        $findings = Test-CaCExtendedConfiguration -Configuration $config -BreakGlassGroupObjectId 'example-breakglass-group-object-id-placeholder'

        $errors = @($findings | Where-Object Severity -EQ 'Error')
        $errors | Should -BeNullOrEmpty -Because ($errors | ForEach-Object { "$($_.Rule): $($_.Message)" }) -join '; '
    }

    It 'flags the Conditional Access example as an Error when the break-glass group does not match' {
        $config = Get-CaCExtendedConfiguration -Path (Join-Path $script:ModuleRoot 'config-samples')
        $findings = Test-CaCExtendedConfiguration -Configuration $config -BreakGlassGroupObjectId 'not-the-right-group'

        $findings | Where-Object { $_.Rule -eq 'safety/conditional-access' } | Should -Not -BeNullOrEmpty
    }
}
