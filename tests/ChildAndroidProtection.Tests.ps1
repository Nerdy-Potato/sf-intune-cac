BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $script:RepoRoot 'src/IntuneCaC/IntuneCaC.psd1') -Force
}

Describe 'Mandatory child Android GSA protection' {
    BeforeEach {
        $script:Config = Get-CaCConfiguration -Path (Join-Path $script:RepoRoot 'config')
        $script:Gsa = $script:Config.Policies | Where-Object name -EQ 'android-defender-gsa-child'
        $script:Vpn = $script:Config.Policies | Where-Object name -EQ 'android-fully-managed-restrictions-child'
        $script:Defender = $script:Config.Apps | Where-Object id -EQ 'android-defender'
    }

    It 'keeps both exact Android keys at string 3 and requires protection by device tier' {
        $settings = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:Gsa.payload.payloadJson)) |
            ConvertFrom-Json -AsHashtable
        $settings.managedProperty.key | Should -Be @('Global Secure Access', 'GlobalSecureAccessPrivateChannel')
        $settings.managedProperty.valueString | Should -Be @('3', '3')
        @($script:Gsa.assignments | Where-Object intent -EQ 'include').group | Should -Contain 'sg-devices-child'
        @($script:Defender.assignments | Where-Object intent -EQ 'required').group | Should -Contain 'sg-devices-child'
        $script:Vpn.payload.vpnAlwaysOnLockdownMode | Should -BeTrue
        @(Test-CaCConfiguration $script:Config | Where-Object Rule -EQ 'safety/child-android-gsa') | Should -BeNullOrEmpty
    }

    It 'rejects <Key> set to <Value>' -ForEach @(
        @{ Key = 'Global Secure Access'; Value = '0' }
        @{ Key = 'Global Secure Access'; Value = '1' }
        @{ Key = 'Global Secure Access'; Value = '2' }
        @{ Key = 'GlobalSecureAccessPrivateChannel'; Value = '0' }
        @{ Key = 'GlobalSecureAccessPrivateChannel'; Value = '1' }
        @{ Key = 'GlobalSecureAccessPrivateChannel'; Value = '2' }
        @{ Key = 'Global Secure Access'; Value = 3 }
    ) {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:Gsa.payload.payloadJson)) |
            ConvertFrom-Json -AsHashtable
        ($decoded.managedProperty | Where-Object key -EQ $Key).valueString = $Value
        $script:Gsa.payload.payloadJson = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
            ($decoded | ConvertTo-Json -Depth 10 -Compress)))
        @(Test-CaCConfiguration $script:Config | Where-Object Rule -EQ 'safety/child-android-gsa').Count | Should -BeGreaterThan 0
    }

    It 'rejects malformed payloads, missing keys, duplicate keys and competing value types' -ForEach @(
        @{ Mutation = 'base64' }, @{ Mutation = 'missing' }, @{ Mutation = 'duplicate' }, @{ Mutation = 'type' }
    ) {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:Gsa.payload.payloadJson)) |
            ConvertFrom-Json -AsHashtable
        switch ($Mutation) {
            'missing' { $decoded.managedProperty = @($decoded.managedProperty[0]) }
            'duplicate' { $decoded.managedProperty += $decoded.managedProperty[1] }
            'type' { $decoded.managedProperty[0].valueInteger = 3 }
        }
        $script:Gsa.payload.payloadJson = if ($Mutation -eq 'base64') { 'not-base64!' }
        else { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($decoded | ConvertTo-Json -Depth 10 -Compress))) }
        @(Test-CaCConfiguration $script:Config | Where-Object Rule -EQ 'safety/child-android-gsa').Count | Should -BeGreaterThan 0
    }

    It 'rejects removal or disabling of either protective policy' -ForEach @(
        @{ Policy = 'android-defender-gsa-child'; Remove = $true }
        @{ Policy = 'android-defender-gsa-child'; Remove = $false }
        @{ Policy = 'android-fully-managed-restrictions-child'; Remove = $true }
        @{ Policy = 'android-fully-managed-restrictions-child'; Remove = $false }
    ) {
        if ($Remove) { $script:Config.Policies = @($script:Config.Policies | Where-Object name -NE $Policy) }
        else { ($script:Config.Policies | Where-Object name -EQ $Policy).enabled = $false }
        @(Test-CaCConfiguration $script:Config | Where-Object Rule -EQ 'safety/child-android-gsa').Count | Should -BeGreaterThan 0
    }

    It 'rejects loss of device-tier coverage even when user-tier assignment remains' -ForEach @(
        @{ Target = 'Gsa' }, @{ Target = 'Vpn' }, @{ Target = 'Defender' }
    ) {
        $item = Get-Variable $Target -Scope Script -ValueOnly
        $item.assignments = @($item.assignments | Where-Object group -NE 'sg-devices-child')
        @(Test-CaCConfiguration $script:Config | Where-Object Rule -EQ 'safety/child-android-gsa').Count | Should -BeGreaterThan 0
    }

    It 'rejects exclusion of protected devices' {
        $script:Gsa.assignments += @{ group = 'sg-tier-teen'; intent = 'exclude' }
        @(Test-CaCConfiguration $script:Config | Where-Object Rule -EQ 'safety/child-android-gsa').Count | Should -BeGreaterThan 0
    }

    It 'rejects disabling VPN lockdown' {
        $script:Vpn.payload.vpnAlwaysOnLockdownMode = $false
        @(Test-CaCConfiguration $script:Config | Where-Object Rule -EQ 'safety/child-android-gsa').Count | Should -BeGreaterThan 0
    }

    It 'rejects the observed live iOS EnableGSA key on an Android policy' {
        $script:Gsa.payload.payloadJson = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
            '{"kind":"androidenterprise#managedConfiguration","productId":"app:com.microsoft.scmx","managedProperty":[{"key":"EnableGSA","valueInteger":3}]}'))
        @(Test-CaCConfiguration $script:Config | Where-Object Rule -EQ 'safety/child-android-gsa').Count | Should -BeGreaterThan 0
    }
}

Describe 'Modern LAPS configuration' {
    It 'uses only modern CSP paths including Entra backup on all three device tiers' {
        $config = Get-CaCConfiguration -Path (Join-Path $script:RepoRoot 'config')
        $laps = $config.Policies | Where-Object name -EQ 'laps-account-management'
        $laps.assignments.group | Should -Be @('sg-devices-adult', 'sg-devices-teen', 'sg-devices-child')
        $expected = @{
            BackupDirectory = 1; PasswordLength = 14; PasswordAgeDays = 30; PasswordComplexity = 4
            AutomaticAccountManagementEnabled = $true; AutomaticAccountManagementEnableAccount = $true
            AutomaticAccountManagementNameOrPrefix = 'x3nc0n'; AutomaticAccountManagementRandomizeName = $false
            AutomaticAccountManagementTarget = 1
        }
        $laps.payload.omaSettings.Count | Should -Be $expected.Count
        foreach ($key in $expected.Keys) {
            $setting = @($laps.payload.omaSettings | Where-Object omaUri -EQ "./Device/Vendor/MSFT/LAPS/Policies/$key")
            $setting.Count | Should -Be 1
            $setting[0].value | Should -Be $expected[$key]
        }
    }
}
