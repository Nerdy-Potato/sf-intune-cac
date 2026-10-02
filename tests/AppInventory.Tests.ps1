BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $script:Root 'src/IntuneCaC/IntuneCaC.psd1') -Force
}

Describe 'Read-only child Android GSA inventory' {
    BeforeEach {
        $global:CaCInventoryGsaPayloadJson = '{"kind":"androidenterprise#managedConfiguration","productId":"app:com.microsoft.scmx","managedProperty":[{"key":"EnableGSA","valueString":"3"},{"key":"GlobalSecureAccessPrivateChannel","valueString":"0"}]}'
        $global:CaCInventorySchemaItems = @(
            @{ schemaItemKey = 'EnableGSA'; displayName = 'Global Secure Access'; dataType = 'integer' },
            @{ schemaItemKey = 'GlobalSecureAccessPrivateChannel'; displayName = 'Private Access'; dataType = 'integer' },
            @{ schemaItemKey = 'antiphishing'; displayName = 'Web protection'; dataType = 'integer' }
        )
        Mock Import-Module {}
        Mock Connect-CaCGraph {}
        Mock Invoke-CaCGraphRequest -ModuleName IntuneCaC {
            param($Method, $Uri, $Body)
            if ($Method -ne 'GET') { throw 'Inventory must never write.' }
            switch -Wildcard ($Uri) {
                'deviceAppManagement/mobileApps' { return @{ value = @() } }
                'deviceAppManagement/mobileAppConfigurations' {
                    return @{ value = @(@{
                        id = 'gsa-id'; displayName = 'CaC - Android - Defender and GSA (Child)'
                        packageId = 'com.microsoft.scmx'
                        payloadJson = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
                            '{"managedProperty":[{"key":"EnableGSA","valueString":"3"},{"key":"GlobalSecureAccessPrivateChannel","valueString":"0"}]}'))
                    }) }
                }
                'deviceAppManagement/mobileAppConfigurations/gsa-id/assignments' {
                    return @{ value = @(@{ target = @{ groupId = 'user-group'; '@odata.type' = '#microsoft.graph.groupAssignmentTarget' } }) }
                }
                'deviceAppManagement/mobileAppConfigurations/gsa-id' {
                    return @{
                        id = 'gsa-id'; packageId = 'com.microsoft.scmx'; targetedMobileApps = @('defender-id')
                        payloadJson = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($global:CaCInventoryGsaPayloadJson))
                    }
                }
                'deviceManagement/androidManagedStoreAppConfigurationSchemas/*' {
                    if ($null -eq $global:CaCInventorySchemaItems) { throw 'Schema not found' }
                    return @{ value = @{ id = 'app:com.microsoft.scmx'; schemaItems = $global:CaCInventorySchemaItems; nestedSchemaItems = @() } }
                }
                'deviceAppManagement/mobileAppConfigurations/gsa-id/deviceStatuses' {
                    return @{ value = @(@{ status = 'compliant'; deviceDisplayName = 'PRIVATE-NAME'; id = 'PRIVATE-DEVICE-ID' }) }
                }
                'groups?*' {
                    $id = if ([uri]::UnescapeDataString($Uri) -match 'CaC-Devices-Child') { 'device-group' } else { 'user-group' }
                    return @{ value = @(@{ id = $id }) }
                }
                'groups/*/members' { return @{ value = @(@{ id = 'PRIVATE-MEMBER-1' }, @{ id = 'PRIVATE-MEMBER-2' }) } }
                default { throw "Unexpected inventory GET: $Uri" }
            }
        }
    }

    It 'reports string-typed live values as not forced on, distinguishes assignments, and redacts device status identifiers' {
        $warnings = @()
        $output = & (Join-Path $script:Root 'scripts/bootstrap/Get-CaCAppInventory.ps1') `
            -TenantId 'test-tenant' -ClientId 'test-client' -IncludeChildGsa -WarningAction SilentlyContinue -WarningVariable warnings |
            Out-String
        $output | Should -Match '"GlobalSecureAccessPrivateChannel"'
        $output | Should -Match '"Desired": "valueInteger:3"'
        $output | Should -Match '"valueString:\\"3\\""'
        $output | Should -Match '"ForcedOn": false'
        $output | Should -Match '"PrivateAccessDisabled": false'
        $output | Should -Match '"ContractSatisfied": false'
        $output | Should -Match '"Included": false'
        $output | Should -Match '"Status": "compliant"'
        $output | Should -Match 'not proof of the on-device GSA toggle'
        $output | Should -Not -Match 'PRIVATE-'
        ($warnings -join ' ') | Should -Match 'Live main GSA is not typed valueInteger 3'
        ($warnings -join ' ') | Should -Not -Match 'Managed Google Play schema'
        Should -Invoke Connect-CaCGraph -Times 1 -Exactly -ParameterFilter { $ReadOnly }
        Should -Invoke Invoke-CaCGraphRequest -ModuleName IntuneCaC -Times 0 -ParameterFilter { $Method -ne 'GET' }
    }

    It 'reports the typed contract (main 3 forced, Private Access 0 off) as satisfied, not as a loss' {
        $global:CaCInventoryGsaPayloadJson = '{"kind":"androidenterprise#managedConfiguration","productId":"app:com.microsoft.scmx","managedProperty":[{"key":"EnableGSA","valueInteger":3},{"key":"GlobalSecureAccessPrivateChannel","valueInteger":0}]}'
        $warnings = @()
        $output = & (Join-Path $script:Root 'scripts/bootstrap/Get-CaCAppInventory.ps1') `
            -TenantId 'test-tenant' -ClientId 'test-client' -IncludeChildGsa -WarningAction SilentlyContinue -WarningVariable warnings |
            Out-String
        $output | Should -Match '"ForcedOn": true'
        $output | Should -Match '"PrivateAccessDisabled": true'
        $output | Should -Match '"ContractSatisfied": true'
        ($warnings -join ' ') | Should -Not -Match 'GSA'
    }

    It 'warns with schema evidence when the live schema does not confirm the key/type contract' -ForEach @(
        @{ Items = $null }
        @{ Items = @(@{ schemaItemKey = 'Global Secure Access'; displayName = 'Global Secure Access'; dataType = 'integer' }) }
    ) {
        $global:CaCInventorySchemaItems = $Items
        $warnings = @()
        $output = & (Join-Path $script:Root 'scripts/bootstrap/Get-CaCAppInventory.ps1') `
            -TenantId 'test-tenant' -ClientId 'test-client' -IncludeChildGsa -WarningAction SilentlyContinue -WarningVariable warnings |
            Out-String
        $output | Should -Match '"Schema"'
        ($warnings -join ' ') | Should -Match 'Managed Google Play schema does not confirm'
    }

    It 'surfaces unavailable status evidence rather than treating an error as an empty healthy result' {
        Mock Invoke-CaCGraphRequest -ModuleName IntuneCaC { throw 'Forbidden status read' } -ParameterFilter { $Uri -like '*/deviceStatuses' }
        { & (Join-Path $script:Root 'scripts/bootstrap/Get-CaCAppInventory.ps1') `
            -TenantId 'test-tenant' -ClientId 'test-client' -IncludeChildGsa } | Should -Throw '*Forbidden status read*'
    }
}
