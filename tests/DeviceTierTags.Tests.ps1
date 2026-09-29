BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Migration = Join-Path $script:Root 'scripts/bootstrap/Convert-CaCDeviceTierGroupsToDynamic.ps1'
    $script:Setter = Join-Path $script:Root 'scripts/bootstrap/Set-CaCDeviceTierTag.ps1'
    Import-Module (Join-Path $script:Root 'src/IntuneCaC/IntuneCaC.psd1') -Force
    $script:Credentials = @{ TenantId = '00000000-0000-0000-0000-000000000001'; ClientId = '00000000-0000-0000-0000-000000000002' }
    $global:TierIds = @(
        '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222',
        '33333333-3333-3333-3333-333333333333'
    )
    $global:GroupIds = @(
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        'cccccccc-cccc-cccc-cccc-cccccccccccc'
    )
    function New-TierTenant {
        $configuration = Get-CaCConfiguration -Path (Join-Path $script:Root 'config')
        $marker = [string] $configuration.Tenant.managedMarker
        $names = @('Adult', 'Teen', 'Child')
        $groups = @{}
        $members = @{}
        for ($i = 0; $i -lt 3; $i++) {
            $tier = $names[$i]
            $spec = $configuration.Groups | Where-Object id -EQ "sg-devices-$($tier.ToLowerInvariant())"
            $id = $global:GroupIds[$i]
            $groups[$id] = [pscustomobject]@{
                id = $id; displayName = $spec.displayName; mailNickname = $spec.mailNickname
                description = "$($spec.description) $marker"; securityEnabled = $true
                mailEnabled = $false; groupTypes = @(); membershipRule = $null
                membershipRuleProcessingState = $null; onPremisesSyncEnabled = $false
                isAssignableToRole = $false
            }
            $members[$id] = @()
        }
        $devices = @{}
        for ($i = 0; $i -lt 3; $i++) {
            $id = $global:TierIds[$i]
            $devices[$id] = [pscustomobject]@{
                id = $id; operatingSystem = $(if ($i -eq 2) { 'Android' } else { 'Windows' })
                extensionAttributes = [pscustomobject]@{ extensionAttribute1 = $null; extensionAttribute2 = 'preserve' }
            }
            $members[$global:GroupIds[$i]] = @([pscustomobject]@{ id = $id; '@odata.type' = '#microsoft.graph.device' })
        }
        $android = '44444444-4444-4444-4444-444444444444'
        $devices[$android] = [pscustomobject]@{
            id = $android; operatingSystem = 'Android'
            extensionAttributes = [pscustomobject]@{ extensionAttribute1 = $null; extensionAttribute2 = 'preserve' }
        }
        $members[$global:GroupIds[2]] += [pscustomobject]@{ id = $android; '@odata.type' = '#microsoft.graph.device' }
        return @{ Groups = $groups; Members = $members; Devices = $devices
            Calls = [System.Collections.Generic.List[object]]::new(); FailTag = $null }
    }
    function Invoke-CaCGraphRequest {
        param([string] $Method, [string] $Uri, $Body, [string] $ApiVersion)
        $state = $global:TierTenant
        $state.Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body; ApiVersion = $ApiVersion })
        if ($Method -eq 'GET' -and $Uri -match '^groups\?\$filter=') {
            $filterValue = (($Uri -split '\$filter=')[1] -split '&')[0]
            $name = [uri]::UnescapeDataString($filterValue)
            $matching = @($state.Groups.Values | Where-Object { $name -eq "displayName eq '$($_.displayName)'" })
            return [pscustomobject]@{ value = $matching }
        }
        if ($Method -eq 'GET' -and $Uri -match '^groups/([0-9a-f-]+)/members$') {
            return [pscustomobject]@{ value = @($state.Members[$Matches[1]]) }
        }
        if ($Method -eq 'GET' -and $Uri -eq 'devices?$select=id,extensionAttributes,operatingSystem') {
            return [pscustomobject]@{ value = @($state.Devices.Values) }
        }
        if ($Uri -match '^devices/([0-9a-f-]+)(?:\?|$)') {
            $id = $Matches[1]
            if (-not $state.Devices.ContainsKey($id)) { throw "Unknown device $id" }
            if ($Method -eq 'GET') { return $state.Devices[$id] }
            if ($Method -eq 'PATCH') {
                if ($state.FailTag -eq $id) { throw "Synthetic device PATCH failure $id" }
                $state.Devices[$id].extensionAttributes.extensionAttribute1 = $Body.extensionAttributes.extensionAttribute1
                return
            }
        }
        if ($Uri -match '^groups/([0-9a-f-]+)(?:\?|$)') {
            $id = $Matches[1]
            if ($Method -eq 'GET') { return $state.Groups[$id] }
            if ($Method -eq 'PATCH') {
                $state.Groups[$id].groupTypes = @($Body.groupTypes)
                $state.Groups[$id].membershipRule = $Body.membershipRule
                $state.Groups[$id].membershipRuleProcessingState = $Body.membershipRuleProcessingState
                return
            }
        }
        throw "Unexpected Graph request: $Method $Uri"
    }
}
Describe 'Device tier tag migration and admin setter' {
    BeforeEach {
        $global:TierTenant = New-TierTenant
        Mock Import-Module {}
        Mock Connect-CaCGraph {}
        Mock Get-Module {
            $module = [pscustomobject]@{}
            $module | Add-Member ScriptMethod NewBoundScriptBlock { param([scriptblock] $Block) $Block } -PassThru
        }
    }
    It 'stamps both Android child members before retaining all three group IDs and rules' {
        $result = & $script:Migration @script:Credentials -Confirm:$false
        $result.Status | Should -Be 'ConfigurationVerifiedMembershipPending'
        $result.GroupIds | Should -HaveCount 3
        $result.TaggedDevices | Should -Be 4
        $writes = @($global:TierTenant.Calls | Where-Object Method -EQ 'PATCH')
        $writes | Should -HaveCount 7
        @($writes | Where-Object { $_.Uri -like 'devices/*' -and $_.Body.extensionAttributes.extensionAttribute1 -eq 'Child' }) | Should -HaveCount 2
        $firstGroup = @($writes | Where-Object Uri -Like 'groups/*')[0]
        @($writes | Where-Object Uri -Like 'devices/*')[-1] | Should -Not -BeNullOrEmpty
        $writes.IndexOf($firstGroup) | Should -Be 4
        foreach ($groupId in $global:GroupIds) {
            $group = $global:TierTenant.Groups[$groupId]
            $group.groupTypes | Should -Contain 'DynamicMembership'
            $group.membershipRule | Should -Match '^[(]device.extensionAttribute1 -eq "(Adult|Teen|Child)"[)]$'
        }
        @($global:TierTenant.Calls | Where-Object { $_.Method -in @('POST', 'DELETE') }) | Should -HaveCount 0
        $global:TierTenant.Devices[$global:TierIds[2]].extensionAttributes.extensionAttribute2 | Should -Be 'preserve'
    }
    It 'has no writes in WhatIf and reads every group and inventory first' {
        $result = & $script:Migration @script:Credentials -WhatIf
        $result.Status | Should -Be 'WhatIf'
        @($global:TierTenant.Calls | Where-Object Method -NE 'GET') | Should -HaveCount 0
        @($global:TierTenant.Calls | Where-Object Uri -Like 'groups/*/members') | Should -HaveCount 3
    }
    It 'refuses conflicting membership, unknown member, occupied tag, and tagged outsider before writes' -TestCases @(
        @{ Case = 'duplicate' }, @{ Case = 'unknown' }, @{ Case = 'occupied' }, @{ Case = 'outsider' }
    ) {
        param($Case)
        switch ($Case) {
            duplicate { $global:TierTenant.Members[$global:GroupIds[1]] += $global:TierTenant.Members[$global:GroupIds[0]][0] }
            unknown { $global:TierTenant.Members[$global:GroupIds[2]] += [pscustomobject]@{ id = '99999999-9999-9999-9999-999999999999'; '@odata.type' = '#microsoft.graph.device' } }
            occupied { $global:TierTenant.Devices[$global:TierIds[0]].extensionAttributes.extensionAttribute1 = 'Other' }
            outsider {
                $global:TierTenant.Members[$global:GroupIds[2]] = @($global:TierTenant.Members[$global:GroupIds[2]][0])
                $global:TierTenant.Devices['44444444-4444-4444-4444-444444444444'].extensionAttributes.extensionAttribute1 = 'Child'
            }
        }
        { & $script:Migration @script:Credentials -Confirm:$false } | Should -Throw
        @($global:TierTenant.Calls | Where-Object Method -NE 'GET') | Should -HaveCount 0
    }
    It 'does not convert any group after a tag failure and resumes safely' {
        $global:TierTenant.FailTag = $global:TierIds[1]
        { & $script:Migration @script:Credentials -Confirm:$false } | Should -Throw
        @($global:TierTenant.Calls | Where-Object Uri -Like 'groups/*' | Where-Object Method -EQ 'PATCH') | Should -HaveCount 0
        $global:TierTenant.FailTag = $null
        & $script:Migration @script:Credentials -Confirm:$false | Out-Null
        $before = @($global:TierTenant.Calls | Where-Object Method -EQ 'PATCH').Count
        $again = & $script:Migration @script:Credentials -Confirm:$false
        $again.ConvertedGroups | Should -Be 0
        $again.TaggedDevices | Should -Be 0
        @($global:TierTenant.Calls | Where-Object Method -EQ 'PATCH').Count | Should -Be $before
    }
    It 'accepts an exact already dynamic tier while converting the remaining groups' {
        $adult = $global:TierTenant.Groups[$global:GroupIds[0]]
        $adult.groupTypes = @('DynamicMembership')
        $adult.membershipRule = '(device.extensionAttribute1 -eq "Adult")'
        $adult.membershipRuleProcessingState = 'On'
        $global:TierTenant.Devices[$global:TierIds[0]].extensionAttributes.extensionAttribute1 = 'Adult'
        $result = & $script:Migration @script:Credentials -Confirm:$false
        $result.ConvertedGroups | Should -Be 2
        @($global:TierTenant.Calls | Where-Object {
            $_.Method -eq 'PATCH' -and $_.Uri -eq "groups/$($global:GroupIds[0])"
        }) | Should -HaveCount 0
    }
    It 'rejects a paused dynamic group and non-device member without writes' -TestCases @(
        @{ Case = 'paused' }, @{ Case = 'user' }
    ) {
        param($Case)
        if ($Case -eq 'paused') {
            $group = $global:TierTenant.Groups[$global:GroupIds[0]]
            $group.groupTypes = @('DynamicMembership')
            $group.membershipRule = '(device.extensionAttribute1 -eq "Adult")'
            $group.membershipRuleProcessingState = 'Paused'
        }
        else {
            $global:TierTenant.Members[$global:GroupIds[2]][0].'@odata.type' = '#microsoft.graph.user'
        }
        { & $script:Migration @script:Credentials -Confirm:$false } | Should -Throw
        @($global:TierTenant.Calls | Where-Object Method -NE 'GET') | Should -HaveCount 0
    }
    It 'permits an empty assigned tier only without tagged outsiders' {
        $global:TierTenant.Members[$global:GroupIds[1]] = @()
        & $script:Migration @script:Credentials -Confirm:$false | Out-Null
        $global:TierTenant.Groups[$global:GroupIds[1]].groupTypes | Should -Contain 'DynamicMembership'
    }
    It 'tags only the exact requested object and rejects overwrite by default' {
        $id = $global:TierIds[2]
        $first = & $script:Setter @script:Credentials -DeviceObjectId $id -Tier Child -Confirm:$false
        $first.Status | Should -Be 'TagVerifiedMembershipPending'
        $patches = @($global:TierTenant.Calls | Where-Object Method -EQ 'PATCH')
        $patches | Should -HaveCount 1
        $patches[0].Uri | Should -Be "devices/$id"
        @($patches[0].Body.extensionAttributes.Keys) | Should -Be @('extensionAttribute1')
        { & $script:Setter @script:Credentials -DeviceObjectId $id -Tier Teen -Confirm:$false } | Should -Throw
        { & $script:Setter @script:Credentials -DeviceObjectId 'not-a-uuid' -Tier Adult -Confirm:$false } | Should -Throw
        & $script:Setter @script:Credentials -DeviceObjectId $id -Tier Teen -AllowTierChange -Confirm:$false | Out-Null
        $global:TierTenant.Devices[$id].extensionAttributes.extensionAttribute1 | Should -Be 'Teen'
    }
    It 'refuses an occupied extensionAttribute1 outside the supported tiers even with -AllowTierChange' {
        $id = $global:TierIds[0]
        $global:TierTenant.Devices[$id].extensionAttributes.extensionAttribute1 = 'ServiceNowAssetTag'

        foreach ($allowChange in @($false, $true)) {
            { & $script:Setter @script:Credentials -DeviceObjectId $id -Tier Adult `
                    -AllowTierChange:$allowChange -Confirm:$false } |
                Should -Throw '*not one of the supported tiers Adult, Teen, or Child*'
        }

        @($global:TierTenant.Calls | Where-Object Method -NE 'GET') | Should -HaveCount 0
        $global:TierTenant.Devices[$id].extensionAttributes.extensionAttribute1 |
            Should -Be 'ServiceNowAssetTag'
    }
    It 'still permits a known tier to known tier reassignment under -AllowTierChange' {
        $id = $global:TierIds[0]
        $global:TierTenant.Devices[$id].extensionAttributes.extensionAttribute1 = 'Teen'

        & $script:Setter @script:Credentials -DeviceObjectId $id -Tier Adult -AllowTierChange -Confirm:$false |
            Out-Null

        $global:TierTenant.Devices[$id].extensionAttributes.extensionAttribute1 | Should -Be 'Adult'
    }
    It 'does not write in setter WhatIf mode' {
        $result = & $script:Setter @script:Credentials -DeviceObjectId $global:TierIds[2] -Tier Child -WhatIf
        $result.Status | Should -Be 'WhatIf'
        @($global:TierTenant.Calls | Where-Object Method -NE 'GET') | Should -HaveCount 0
    }
}

Describe 'Shared Graph client collection paging' {
    It 'follows absolute next links for group members and device inventory' {
        InModuleScope IntuneCaC {
            $script:GraphToken = 'synthetic'
            $script:GraphReadOnly = $true
            Mock Invoke-RestMethod {
                if ($Uri -like '*skiptoken=next') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'page-two' }) }
                }
                $path = ([uri] $Uri).AbsolutePath
                return [pscustomobject]@{
                    value = @([pscustomobject]@{ id = 'page-one' })
                    '@odata.nextLink' = "https://graph.microsoft.com$($path)?skiptoken=next"
                }
            }
            foreach ($endpoint in @('devices?$select=id', 'groups/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/members')) {
                $result = Invoke-CaCGraphRequest -Method GET -Uri $endpoint -ApiVersion 'v1.0'
                $result.value | Should -HaveCount 2
                $result.value[1].id | Should -Be 'page-two'
            }
            Should -Invoke Invoke-RestMethod -Times 4 -Exactly
        }
    }
}
