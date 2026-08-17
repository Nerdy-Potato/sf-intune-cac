BeforeAll {
    $script:RepoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module -Name (Join-Path $script:RepoRoot 'src/IntuneCaC/IntuneCaC.psd1') -Force
    $script:Config = Get-CaCConfiguration -Path (Join-Path $script:RepoRoot 'config')
    $script:Findings = Test-CaCConfiguration -Configuration $script:Config
}

Describe 'Repository configuration' {
    It 'passes schema and safety validation with no errors' {
        $errors = @($script:Findings | Where-Object Severity -EQ 'Error')
        $errors | Should -BeNullOrEmpty -Because ((($errors | ForEach-Object { "$($_.Rule): $($_.Message)" }) -join '; '))
    }

    It 'targets the family tenant and nothing else' {
        $script:Config.Tenant.fallbackDomain | Should -Be 'nerdypotato.onmicrosoft.com'
    }

    It 'defines every account named by the tenant owner' {
        $expected = @(
            'john', 'robin', 'samantha', 'adalynn', 'lucas', 'emmerick', 'broderick', 'cullen',
            'johnspaid', 'mauricemoss', 'bobjohnson'
        )

        ($script:Config.Users.id | Sort-Object) | Should -Be ($expected | Sort-Object)
    }

    It 'keeps break-glass accounts out of every assignment group' {
        $firecall = @($script:Config.Users | Where-Object accountType -EQ 'firecall' | ForEach-Object { $_.upn })

        foreach ($group in $script:Config.Groups | Where-Object purpose -EQ 'assignment') {
            foreach ($account in $firecall) {
                $group.members | Should -Not -Contain $account -Because "$($group.id) is assigned policy"
            }
        }
    }

    It 'places the younger children in the teen tier' {
        ($script:Config.Users | Where-Object id -EQ 'lucas').tier | Should -Be 'teen'
        ($script:Config.Users | Where-Object id -EQ 'adalynn').tier | Should -Be 'teen'
    }

    It 'confirms the three youngest children in the child tier' {
        $youngest = @($script:Config.Users | Where-Object id -in @('emmerick', 'broderick', 'cullen'))
        $youngest.Count | Should -Be 3
        $youngest.tier | Should -Be @('child', 'child', 'child')
        $youngest.ageTierConfirmed | Should -Be @($true, $true, $true)
    }

    It 'defines the assigned Autopilot device preparation group with no static members' {
        $group = $script:Config.Groups | Where-Object id -EQ 'sg-autopilot-device-preparation-child'
        $group.members | Should -BeNullOrEmpty
        $group.membership.source | Should -Be 'explicit'
    }

    It 'keeps adoption explicit, one-time, and scoped to the configured bootstrap objects' {
        $script:Config.Tenant.adoption.oneTime | Should -BeTrue
        $script:Config.Tenant.adoption.enabled | Should -BeTrue
        $script:Config.Tenant.adoption.groups.id | Should -Be 'sg-autopilot-device-preparation-child'
        @($script:Config.Tenant.adoption.apps | ForEach-Object id) | Should -Be @()
    }

    It 'defines one manually managed device group for each age tier' {
        $deviceGroups = @($script:Config.Groups | Where-Object {
            $_ -is [hashtable] -and $_.ContainsKey('memberType') -and $_['memberType'] -eq 'device'
        })
        @($deviceGroups | ForEach-Object { $_['displayName'] }) | Should -Be @('CaC-Devices-Adult', 'CaC-Devices-Teen', 'CaC-Devices-Child')
        @($deviceGroups | ForEach-Object { $_['members'] }) | Should -BeNullOrEmpty
    }

    It 'places Samantha in the adult tier' {
        ($script:Config.Users | Where-Object id -EQ 'samantha').tier | Should -Be 'adult'
    }

    It 'gives the child tier more restrictions than the teen tier' {
        $child = $script:Config.Policies | Where-Object name -EQ 'windows-restrictions-child'
        $teen = $script:Config.Policies | Where-Object name -EQ 'windows-restrictions-teen'

        $child.payload.windowsStoreBlocked | Should -BeTrue
        $teen.payload.windowsStoreBlocked | Should -BeFalse
        $child.payload.Keys.Count | Should -BeGreaterThan $teen.payload.Keys.Count
    }

    It 'always exposes group membership as an array, even for empty or single member tiers' {
        foreach ($group in $script:Config.Groups) {
            , $group.members | Should -BeOfType [System.Object[]]
        }

        ($script:Config.Groups | Where-Object id -EQ 'sg-tier-teen').members.Count | Should -Be 2
    }

    It 'never assigns a policy to all users or all devices' {
        foreach ($policy in $script:Config.Policies) {
            $policy.assignments.group | Should -Not -Contain 'allUsers'
            $policy.assignments.group | Should -Not -Contain 'allDevices'
        }
    }

    It 'marks every policy as managed by this repository' {
        foreach ($policy in $script:Config.Policies) {
            $policy.payload.description | Should -BeLike "*$($script:Config.Tenant.managedMarker)*"
            $policy.payload.displayName | Should -BeLike "$($script:Config.Tenant.namePrefix) - *"
        }
    }

    It 'keeps the child app catalog explicit and scoped only to the child tier' {
        $script:Config.Apps.Count | Should -BeGreaterThan 0
        foreach ($app in $script:Config.Apps) {
            $app.assignments.group | Should -Be @('sg-tier-child')
        }

        $script:Config.Apps.id | Should -Not -Contain 'android-authenticator'
        $script:Config.Apps.id | Should -Not -Contain 'ios-authenticator'
        ($script:Config.Apps | Where-Object id -in @('android-defender', 'ios-defender')).assignments.intent |
            Should -Be @('required', 'required')
    }

    It 'keeps Windows update rings out of the adult tier' {
        $pilot = $script:Config.Policies | Where-Object name -EQ 'windows-update-ring-pilot'
        $broad = $script:Config.Policies | Where-Object name -EQ 'windows-update-ring-broad'

        $pilot.assignments.Where({ $_.intent -eq 'include' }).group | Should -Be 'sg-tier-child'
        $broad.assignments.Where({ $_.intent -eq 'include' }).group | Should -Be @('sg-tier-child', 'sg-tier-teen')
        $broad.payload.qualityUpdatesDeferralPeriodInDays |
            Should -BeGreaterThan $pilot.payload.qualityUpdatesDeferralPeriodInDays
    }

    It 'warns, rather than silently accepting, an unconfirmed age tier' {
        $unconfirmed = @($script:Config.Users | Where-Object { $_.ageTierConfirmed -eq $false })
        $warnings = @($script:Findings | Where-Object Rule -EQ 'identity/age-tier-unconfirmed')

        $warnings.Count | Should -Be 0
        $unconfirmed | Should -BeNullOrEmpty
    }
}

Describe 'Validation rules' {
    BeforeEach {
        $script:Draft = Get-CaCConfiguration -Path (Join-Path $script:RepoRoot 'config')
    }

    It 'rejects an assignment to a group that does not exist' {
        $script:Draft.Policies[0].assignments = @(@{ group = 'sg-does-not-exist'; intent = 'include' })

        $result = Test-CaCConfiguration -Configuration $script:Draft
        @($result | Where-Object Rule -EQ 'policy/unknown-group') | Should -Not -BeNullOrEmpty
    }

    It 'rejects an assignment to the break-glass exclusion group' {
        $script:Draft.Policies[0].assignments = @(@{ group = 'sg-breakglass'; intent = 'include' })

        $result = Test-CaCConfiguration -Configuration $script:Draft
        @($result | Where-Object Rule -EQ 'safety/exclusion-group-assigned') | Should -Not -BeNullOrEmpty
    }

    It 'rejects an All Users assignment' {
        $script:Draft.Policies[0].assignments = @(@{ group = 'allUsers'; intent = 'include' })

        $result = Test-CaCConfiguration -Configuration $script:Draft
        @($result | Where-Object Rule -EQ 'safety/all-users') | Should -Not -BeNullOrEmpty
    }

    It 'rejects a policy that only has exclusions' {
        $script:Draft.Policies[0].assignments = @(@{ group = 'sg-tier-adult'; intent = 'exclude' })

        $result = Test-CaCConfiguration -Configuration $script:Draft
        @($result | Where-Object Rule -EQ 'policy/assignment-required') | Should -Not -BeNullOrEmpty
    }

    It 'rejects a policy that is not marked as managed by this repository' {
        $script:Draft.Policies[0].payload.description = 'ad hoc change'

        $result = Test-CaCConfiguration -Configuration $script:Draft
        @($result | Where-Object Rule -EQ 'policy/managed-marker') | Should -Not -BeNullOrEmpty
    }

    It 'rejects two policies that share a displayName' {
        $script:Draft.Policies[1].payload.displayName = $script:Draft.Policies[0].payload.displayName

        $result = Test-CaCConfiguration -Configuration $script:Draft
        @($result | Where-Object Rule -EQ 'policy/duplicate-displayname') | Should -Not -BeNullOrEmpty
    }

    It 'rejects an unsupported resource kind' {
        $script:Draft.Policies[0].resource = 'somethingElse'

        $result = Test-CaCConfiguration -Configuration $script:Draft
        @($result | Where-Object Rule -EQ 'policy/resource') | Should -Not -BeNullOrEmpty
    }

    It 'rejects an adoption entry outside the exact Autopilot and Authenticator scope' {
        $script:Draft.Tenant.adoption.groups[0].id = 'sg-tier-adult'

        $result = Test-CaCConfiguration -Configuration $script:Draft
        @($result | Where-Object Rule -EQ 'adoption/group-scope') | Should -Not -BeNullOrEmpty
    }

    It 'rejects an adoption section that is not explicitly one-time' {
        $script:Draft.Tenant.adoption.oneTime = $false

        $result = Test-CaCConfiguration -Configuration $script:Draft
        @($result | Where-Object Rule -EQ 'adoption/one-time') | Should -Not -BeNullOrEmpty
    }
}
