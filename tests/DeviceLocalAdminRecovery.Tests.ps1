BeforeAll {
    $script:RepoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module -Name (Join-Path $script:RepoRoot 'src/IntuneCaC/IntuneCaC.psd1') -Force
    $script:RecoveryScript = Join-Path $script:RepoRoot 'scripts/bootstrap/New-CaCDeviceLocalAdminRecovery.ps1'
    $script:RecoveryConfig = Get-CaCConfiguration -Path (Join-Path $script:RepoRoot 'config')
    $script:RecoveryUserId = '11111111-2222-3333-4444-555555555555'
    $script:RecoveryManagedDeviceId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    $script:RecoveryEntraDeviceId = 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff'
    $script:RecoveryDeviceObjectId = 'cccccccc-dddd-eeee-ffff-000000000000'
    $script:RecoveryGroupId = 'dddddddd-eeee-ffff-0000-111111111111'
    $script:RecoveryPolicyId = 'eeeeeeee-ffff-0000-1111-222222222222'
    $script:RecoveryUpn = 'recovery.user@example.test'
    $global:RecoveryGroupId = $script:RecoveryGroupId
    $global:RecoveryPolicyId = $script:RecoveryPolicyId

    function New-FakeRecoveryTenant {
        $state = @{
            Calls = [System.Collections.Generic.List[object]]::new()
            Users = @(
                [pscustomobject]@{
                    id                = $script:RecoveryUserId
                    userPrincipalName = $script:RecoveryUpn
                    userType          = 'Member'
                    accountEnabled    = $true
                    securityIdentifier = $null
                }
            )
            ManagedDevices = @(
                [pscustomobject]@{
                    id                = $script:RecoveryManagedDeviceId
                    deviceName        = 'RecoveryTestDevice'
                    operatingSystem   = 'Windows'
                    managementState   = 'managed'
                    azureADDeviceId   = $script:RecoveryEntraDeviceId
                    userPrincipalName = $script:RecoveryUpn
                }
            )
            Devices = @(
                [pscustomobject]@{
                    id             = $script:RecoveryDeviceObjectId
                    deviceId       = $script:RecoveryEntraDeviceId
                    displayName    = 'RecoveryTestDevice'
                    accountEnabled = $true
                    trustType      = 'AzureAd'
                }
            )
            Groups = @()
            Members = @{}
            Policies = @()
            Assignments = @{}
            FailUri = $null
        }
        return $state
    }

    function Invoke-CaCGraphRequest {
        param(
            [Parameter(Mandatory)][string] $Method,
            [Parameter(Mandatory)][string] $Uri,
            $Body,
            [string] $ApiVersion = 'v1.0'
        )

        $state = $global:RecoveryFakeState
        $state.Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body; ApiVersion = $ApiVersion }) | Out-Null
        if ($state.FailUri -and $Uri -like $state.FailUri) {
            throw 'Synthetic Graph read failure'
        }

        if ($Method -eq 'GET') {
            if ($Uri -like 'users?*') { return [pscustomobject]@{ value = $state.Users } }
            if ($Uri -like 'deviceManagement/managedDevices?*') { return [pscustomobject]@{ value = $state.ManagedDevices } }
            if ($Uri -like 'devices?*') { return [pscustomobject]@{ value = $state.Devices } }
            if ($Uri -match '^groups\?') { return [pscustomobject]@{ value = $state.Groups } }
            if ($Uri -match '^groups/(?<id>[0-9a-f-]+)/members\?') {
                return [pscustomobject]@{ value = @($state.Members[$Matches.id]) }
            }
            if ($Uri -match '^groups/(?<id>[0-9a-f-]+)\?') {
                return $state.Groups | Where-Object id -EQ $Matches.id | Select-Object -First 1
            }
            if ($Uri -match '^deviceManagement/deviceConfigurations\?') {
                return [pscustomobject]@{ value = $state.Policies }
            }
            if ($Uri -match '^deviceManagement/deviceConfigurations/(?<id>[0-9a-f-]+)/assignments$') {
                return [pscustomobject]@{ value = @($state.Assignments[$Matches.id]) }
            }
            if ($Uri -match '^deviceManagement/deviceConfigurations/(?<id>[0-9a-f-]+)$') {
                return $state.Policies | Where-Object id -EQ $Matches.id | Select-Object -First 1
            }
            throw "Unexpected synthetic Graph read: $Uri"
        }

        if ($Method -eq 'POST' -and $Uri -eq 'groups') {
            $group = [pscustomobject]@{
                id                            = $global:RecoveryGroupId
                displayName                   = $Body.displayName
                description                   = $Body.description
                securityEnabled               = $Body.securityEnabled
                mailEnabled                   = $Body.mailEnabled
                groupTypes                    = @()
                membershipRule                = $null
                membershipRuleProcessingState = $null
                onPremisesSyncEnabled         = $false
            }
            $state.Groups += $group
            $state.Members[$group.id] = @()
            return $group
        }
        if ($Method -eq 'POST' -and $Uri -match '^groups/(?<id>[0-9a-f-]+)/members/\$ref$') {
            $groupId = $Matches.id
            $memberId = [string] (($Body.'@odata.id' -split '/')[-1])
            $state.Members[$groupId] = @($state.Members[$groupId]) + @([pscustomobject]@{ id = $memberId })
            return $null
        }
        if ($Method -eq 'POST' -and $Uri -eq 'deviceManagement/deviceConfigurations') {
            $policy = [pscustomobject]@{
                id          = $global:RecoveryPolicyId
                displayName = $Body.displayName
                description = $Body.description
                '@odata.type' = $Body.'@odata.type'
                omaSettings = $Body.omaSettings
            }
            $state.Policies += $policy
            $state.Assignments[$policy.id] = @()
            return $policy
        }
        if ($Method -eq 'POST' -and $Uri -match '^deviceManagement/deviceConfigurations/(?<id>[0-9a-f-]+)/assign$') {
            $state.Assignments[$Matches.id] = @($Body.assignments)
            return $null
        }

        throw "Unexpected synthetic Graph write: $Method $Uri"
    }
}

Describe 'Device local administrator recovery' {
    BeforeEach {
        $script:RecoveryFakeState = New-FakeRecoveryTenant
        $global:RecoveryFakeState = $script:RecoveryFakeState
        Mock -CommandName Import-Module {}
        Mock -CommandName Connect-CaCGraph {}
        Mock -CommandName Get-Module {
            $fakeModule = [pscustomobject]@{}
            $fakeModule | Add-Member -MemberType ScriptMethod -Name NewBoundScriptBlock -Value {
                param([scriptblock] $ScriptBlock)
                $ScriptBlock
            } -Force -PassThru
        }
    }

    It 'creates an exact single-device additive policy and verifies the group-only assignment' {
        $result = & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
            -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
            -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false

        $groupCreate = @($script:RecoveryFakeState.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -eq 'groups' })
        $groupCreate | Should -HaveCount 1
        $groupCreate[0].ApiVersion | Should -Be 'v1.0'
        $groupCreate[0].Body.securityEnabled | Should -BeTrue
        $groupCreate[0].Body.mailEnabled | Should -BeFalse
        @($groupCreate[0].Body.groupTypes) | Should -HaveCount 0

        $memberAdd = @($script:RecoveryFakeState.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/members/\$ref$' })
        $memberAdd | Should -HaveCount 1
        $memberAdd[0].Body.'@odata.id' | Should -Be "https://graph.microsoft.com/v1.0/devices/$($script:RecoveryDeviceObjectId)"

        $policyCreate = @($script:RecoveryFakeState.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -eq 'deviceManagement/deviceConfigurations' })
        $policyCreate | Should -HaveCount 1
        $policyCreate[0].Body.'@odata.type' | Should -Be '#microsoft.graph.windows10CustomConfiguration'
        $policyCreate[0].Body.omaSettings | Should -HaveCount 1
        $policyCreate[0].Body.omaSettings[0].'@odata.type' | Should -Be '#microsoft.graph.omaSettingString'
        $policyCreate[0].Body.omaSettings[0].omaUri | Should -Be './Device/Vendor/MSFT/Policy/Config/LocalUsersAndGroups/Configure'
        $policyCreate[0].Body.omaSettings[0].value | Should -Be (
            '<GroupConfiguration><accessgroup desc="S-1-5-32-544"><group action="U" /><add member="{0}" /></accessgroup></GroupConfiguration>' -f
            'S-1-12-1-286331153-858989090-1431651396-1431655765'
        )
        $policyCreate[0].Body.omaSettings[0].value | Should -Not -Match '<remove\b|action="R"|<clear\b'

        $assign = @($script:RecoveryFakeState.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/assign$' })
        $assign | Should -HaveCount 1
        $assign[0].Body.assignments | Should -HaveCount 1
        $assign[0].Body.assignments[0].target.'@odata.type' | Should -Be '#microsoft.graph.groupAssignmentTarget'
        $assign[0].Body.assignments[0].target.groupId | Should -Be $script:RecoveryGroupId
        $result.Status | Should -Be 'AppliedAndVerifiedInGraph'
        $result.GroupObjectId | Should -Be $script:RecoveryGroupId
        $result.PolicyObjectId | Should -Be $script:RecoveryPolicyId
        $result.EndpointSuccessVerified | Should -BeFalse
        $result.Scope | Should -Match 'exactly the selected Entra device object'
    }

    It 'performs no writes in WhatIf mode' {
        $result = & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
            -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
            -ClientId '00000000-0000-0000-0000-000000000002' -WhatIf -Confirm:$false

        @($script:RecoveryFakeState.Calls | Where-Object Method -NE 'GET') | Should -HaveCount 0
        $result.Status | Should -Be 'WhatIf'
        $result.PlannedChanges | Should -HaveCount 4
        $result.EndpointSuccessVerified | Should -BeFalse
    }

    It 'runs the actual workflow recovery block with named arguments and confirmation <Confirmation>' -TestCases @(
        @{ Confirmation = 'false'; ExpectedStatus = 'WhatIf'; Writes = 0 }
        @{ Confirmation = 'true'; ExpectedStatus = 'AppliedAndVerifiedInGraph'; Writes = 4 }
    ) {
        param($Confirmation, $ExpectedStatus, $Writes)

        $workflow = Get-Content (Join-Path $script:RepoRoot '.github/workflows/deploy-local-admin-remediation.yml') -Raw
        $deployStep = ($workflow -split '- name: Deploy proactive remediation', 2)[1]
        $runBlock = ($deployStep -split '(?m)^\s*run:\s*\|\s*', 2)[1]
        $values = @{
            REMEDIATION_MODE = 'single-device-recovery'
            RECOVERY_DEVICE_NAME = 'RecoveryTestDevice'
            RECOVERY_USER_PRINCIPAL_NAME = $script:RecoveryUpn
            RECOVERY_CONFIRM = $Confirmation
            AZURE_TENANT_ID = '00000000-0000-0000-0000-000000000001'
            AZURE_CLIENT_ID = '00000000-0000-0000-0000-000000000002'
        }
        $original = @{}
        foreach ($key in $values.Keys) {
            $original[$key] = [Environment]::GetEnvironmentVariable($key)
            [Environment]::SetEnvironmentVariable($key, $values[$key])
        }
        Push-Location $script:RepoRoot
        try {
            $result = & ([scriptblock]::Create($runBlock))
            $result.Status | Should -Be $ExpectedStatus
            @($script:RecoveryFakeState.Calls | Where-Object Method -NE 'GET') | Should -HaveCount $Writes
        }
        finally {
            Pop-Location
            foreach ($key in $original.Keys) {
                [Environment]::SetEnvironmentVariable($key, $original[$key])
            }
        }
    }

    It 'is idempotent when the exact group, setting, and assignment already exist' {
        $first = & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
            -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
            -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false
        $writesAfterFirstRun = @($script:RecoveryFakeState.Calls | Where-Object Method -NE 'GET').Count

        $second = & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
            -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
            -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false

        @($script:RecoveryFakeState.Calls | Where-Object Method -NE 'GET').Count | Should -Be $writesAfterFirstRun
        $first.Status | Should -Be 'AppliedAndVerifiedInGraph'
        $second.Status | Should -Be 'AppliedAndVerifiedInGraph'
        $second.PlannedChanges | Should -HaveCount 0
    }

    It 'refuses an ambiguous user and does not write' {
        $script:RecoveryFakeState.Users += $script:RecoveryFakeState.Users[0]

        {
            & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
                -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
                -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false
        } | Should -Throw '*Expected exactly one Entra user*'
        @($script:RecoveryFakeState.Calls | Where-Object Method -NE 'GET') | Should -HaveCount 0
    }

    It 'refuses a missing or ambiguous Windows managed-device match' {
        $script:RecoveryFakeState.ManagedDevices = @()
        {
            & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
                -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
                -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false
        } | Should -Throw '*Expected exactly one Windows managed device*'

        $script:RecoveryFakeState = New-FakeRecoveryTenant
        $global:RecoveryFakeState = $script:RecoveryFakeState
        $script:RecoveryFakeState.ManagedDevices += $script:RecoveryFakeState.ManagedDevices[0]
        {
            & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
                -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
                -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false
        } | Should -Throw '*Expected exactly one Windows managed device*'
        @($script:RecoveryFakeState.Calls | Where-Object Method -NE 'GET') | Should -HaveCount 0
    }

    It 'fails safely when the selected UPN differs from the managed-device user' {
        $script:RecoveryFakeState.ManagedDevices[0].userPrincipalName = 'other.user@example.test'

        {
            & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
                -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
                -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false
        } | Should -Throw '*differs from the managed device*'
        @($script:RecoveryFakeState.Calls | Where-Object Method -NE 'GET') | Should -HaveCount 0
    }

    It 'refuses to reuse a group containing any other member' {
        $marker = $script:RecoveryConfig.Tenant.managedMarker
        $script:RecoveryFakeState.Groups = @(
            [pscustomobject]@{
                id                            = $script:RecoveryGroupId
                displayName                   = "CaC - Device Local Admin Recovery - Device-$($script:RecoveryDeviceObjectId.ToLowerInvariant())"
                description                   = "owned $marker"
                securityEnabled               = $true
                mailEnabled                   = $false
                groupTypes                    = @()
                membershipRule                = $null
                membershipRuleProcessingState = $null
                onPremisesSyncEnabled         = $false
            }
        )
        $script:RecoveryFakeState.Members[$script:RecoveryGroupId] = @(
            [pscustomobject]@{ id = $script:RecoveryDeviceObjectId },
            [pscustomobject]@{ id = '99999999-8888-7777-6666-555555555555' }
        )

        {
            & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
                -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
                -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false
        } | Should -Throw '*not exclusive to the selected Entra device*'
        @($script:RecoveryFakeState.Calls | Where-Object Method -NE 'GET') | Should -HaveCount 0
    }

    It 'refuses a second user recovery policy for the same device' {
        $first = & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
            -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
            -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false
        $script:RecoveryFakeState.Policies[0].displayName = "CaC - Device Local Admin Recovery - Device-$($script:RecoveryDeviceObjectId.ToLowerInvariant()) - User-99999999-8888-7777-6666-555555555555"

        {
            & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
                -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
                -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false
        } | Should -Throw '*different user*'
        $first.Status | Should -Be 'AppliedAndVerifiedInGraph'
        @($script:RecoveryFakeState.Calls | Where-Object Method -NE 'GET').Count | Should -Be 4
    }

    It 'refuses a pre-existing policy assignment outside the exact device group' {
        & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
            -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
            -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false | Out-Null
        $script:RecoveryFakeState.Assignments[$script:RecoveryPolicyId][0].target =
            [pscustomobject]@{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' }
        $writesAfterFirstRun = @($script:RecoveryFakeState.Calls | Where-Object Method -NE 'GET').Count

        {
            & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
                -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
                -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false
        } | Should -Throw '*assignment outside the exact static device group*'
        @($script:RecoveryFakeState.Calls | Where-Object Method -NE 'GET').Count | Should -Be $writesAfterFirstRun
    }

    It 'refuses to reuse a target-specific policy without the repository managed marker' {
        & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
            -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
            -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false | Out-Null
        $script:RecoveryFakeState.Policies[0].description = 'unowned policy'
        $writesAfterFirstRun = @($script:RecoveryFakeState.Calls | Where-Object Method -NE 'GET').Count

        {
            & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
                -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
                -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false
        } | Should -Throw '*does not carry the repository managed marker*'
        @($script:RecoveryFakeState.Calls | Where-Object Method -NE 'GET').Count | Should -Be $writesAfterFirstRun
    }

    It 'refuses ambiguous linked Entra device objects' {
        $script:RecoveryFakeState.Devices += $script:RecoveryFakeState.Devices[0]

        {
            & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
                -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
                -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false
        } | Should -Throw '*Expected exactly one Entra device object*'
        @($script:RecoveryFakeState.Calls | Where-Object Method -NE 'GET') | Should -HaveCount 0
    }

    It 'surfaces Graph read failures and never converts them into a success-shaped result' {
        $script:RecoveryFakeState.FailUri = 'devices?*'

        {
            & $script:RecoveryScript -DeviceName 'RecoveryTestDevice' `
                -UserPrincipalName $script:RecoveryUpn -TenantId '00000000-0000-0000-0000-000000000001' `
                -ClientId '00000000-0000-0000-0000-000000000002' -Confirm:$false
        } | Should -Throw '*Synthetic Graph read failure*'
        @($script:RecoveryFakeState.Calls | Where-Object Method -NE 'GET') | Should -HaveCount 0
    }
}
