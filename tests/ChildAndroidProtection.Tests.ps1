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

    It 'forces main GSA on (integer 3), turns unused Private Access off (integer 0) and requires device-tier protection' {
        $settings = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:Gsa.payload.payloadJson)) |
            ConvertFrom-Json -AsHashtable
        $settings.managedProperty.key | Should -Be @('EnableGSA', 'GlobalSecureAccessPrivateChannel')
        $settings.managedProperty.valueInteger | Should -Be @(3, 0)
        foreach ($property in $settings.managedProperty) {
            @($property.Keys | Where-Object { $_ -like 'value*' }) | Should -Be @('valueInteger')
            $property.valueInteger | Should -BeOfType [long]
        }
        @($script:Gsa.assignments | Where-Object intent -EQ 'include').group | Should -Be @('sg-tier-child', 'sg-devices-child')
        @($script:Gsa.assignments | Where-Object intent -EQ 'exclude') | Should -BeNullOrEmpty
        @($script:Defender.assignments | Where-Object intent -EQ 'required').group | Should -Contain 'sg-devices-child'
        @($script:Defender.assignments | Where-Object intent -EQ 'required').group | Should -Contain 'sg-tier-child'
        $script:Vpn.payload.vpnAlwaysOnLockdownMode | Should -BeTrue
        @(Test-CaCConfiguration $script:Config | Where-Object Rule -EQ 'safety/child-android-gsa') | Should -BeNullOrEmpty
    }

    It 'rejects <Key> = <Field>:<Value>' -ForEach @(
        @{ Key = 'EnableGSA'; Field = 'valueInteger'; Value = 0 }
        @{ Key = 'EnableGSA'; Field = 'valueInteger'; Value = 1 }
        @{ Key = 'EnableGSA'; Field = 'valueInteger'; Value = 2 }
        @{ Key = 'GlobalSecureAccessPrivateChannel'; Field = 'valueInteger'; Value = 1 }
        @{ Key = 'GlobalSecureAccessPrivateChannel'; Field = 'valueInteger'; Value = 2 }
        @{ Key = 'GlobalSecureAccessPrivateChannel'; Field = 'valueInteger'; Value = 3 }
        @{ Key = 'EnableGSA'; Field = 'valueString'; Value = '3' }
        @{ Key = 'GlobalSecureAccessPrivateChannel'; Field = 'valueString'; Value = '0' }
        @{ Key = 'EnableGSA'; Field = 'valueBool'; Value = $true }
        @{ Key = 'EnableGSA'; Field = 'valueInteger'; Value = 3.0 }
        @{ Key = 'EnableGSA'; Field = 'valueInteger'; Value = '3' }
    ) {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:Gsa.payload.payloadJson)) |
            ConvertFrom-Json -AsHashtable
        $property = $decoded.managedProperty | Where-Object key -EQ $Key
        $property.Remove('valueInteger')
        $property[$Field] = $Value
        $script:Gsa.payload.payloadJson = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
            ($decoded | ConvertTo-Json -Depth 10 -Compress)))
        @(Test-CaCConfiguration $script:Config | Where-Object Rule -EQ 'safety/child-android-gsa').Count | Should -BeGreaterThan 0
    }

    It 'rejects malformed payloads, missing/duplicate/variant keys, competing value types and wrong product (<Mutation>)' -ForEach @(
        @{ Mutation = 'base64' }, @{ Mutation = 'missing-main' }, @{ Mutation = 'missing-private' }, @{ Mutation = 'duplicate' }
        @{ Mutation = 'competing' }, @{ Mutation = 'case' }, @{ Mutation = 'whitespace' }, @{ Mutation = 'product' }
        @{ Mutation = 'kind' }, @{ Mutation = 'legacy-pa' }, @{ Mutation = 'ios-private' }
    ) {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:Gsa.payload.payloadJson)) |
            ConvertFrom-Json -AsHashtable
        switch ($Mutation) {
            'missing-main' { $decoded.managedProperty = @($decoded.managedProperty[1]) }
            'missing-private' { $decoded.managedProperty = @($decoded.managedProperty[0]) }
            'duplicate' { $decoded.managedProperty += @{ key = 'EnableGSA'; valueInteger = 3 } }
            'competing' { $decoded.managedProperty[0].valueString = '3' }
            'case' { $decoded.managedProperty[0].key = 'enablegsa' }
            'whitespace' { $decoded.managedProperty[0].key = 'EnableGSA ' }
            'product' { $decoded.productId = 'app:com.microsoft.emmx' }
            'kind' { $decoded.kind = 'other' }
            'legacy-pa' { $decoded.managedProperty += @{ key = 'GlobalSecureAccessPA'; valueInteger = 0 } }
            'ios-private' { $decoded.managedProperty += @{ key = 'EnableGSAPrivateChannel'; valueInteger = 0 } }
        }
        $script:Gsa.payload.payloadJson = if ($Mutation -eq 'base64') { 'not-base64!' }
        else { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($decoded | ConvertTo-Json -Depth 10 -Compress))) }
        @(Test-CaCConfiguration $script:Config | Where-Object Rule -EQ 'safety/child-android-gsa').Count | Should -BeGreaterThan 0
    }

    It 'accepts the contract regardless of managedProperty order' {
        $script:Gsa.payload.payloadJson = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
            '{"kind":"androidenterprise#managedConfiguration","productId":"app:com.microsoft.scmx","managedProperty":[{"key":"GlobalSecureAccessPrivateChannel","valueInteger":0},{"key":"EnableGSA","valueInteger":3}]}'))
        @(Test-CaCConfiguration $script:Config | Where-Object Rule -EQ 'safety/child-android-gsa') | Should -BeNullOrEmpty
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

    It 'rejects loss of the child user-tier assignment on the GSA policy' {
        $script:Gsa.assignments = @($script:Gsa.assignments | Where-Object group -NE 'sg-tier-child')
        @(Test-CaCConfiguration $script:Config | Where-Object Rule -EQ 'safety/child-android-gsa').Count | Should -BeGreaterThan 0
    }

    It 'rejects disabling VPN lockdown' {
        $script:Vpn.payload.vpnAlwaysOnLockdownMode = $false
        @(Test-CaCConfiguration $script:Config | Where-Object Rule -EQ 'safety/child-android-gsa').Count | Should -BeGreaterThan 0
    }

    It 'rejects the observed regression using a display label instead of the native EnableGSA key' {
        $script:Gsa.payload.payloadJson = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
            '{"kind":"androidenterprise#managedConfiguration","productId":"app:com.microsoft.scmx","managedProperty":[{"key":"Global Secure Access","valueInteger":3},{"key":"GlobalSecureAccessPrivateChannel","valueInteger":0}]}'))
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
