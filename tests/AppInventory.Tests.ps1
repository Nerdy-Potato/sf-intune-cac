BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $script:Root 'src/IntuneCaC/IntuneCaC.psd1') -Force
}

Describe 'Read-only child Android GSA inventory' {
    BeforeEach {
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
                            '{"managedProperty":[{"key":"Global Secure Access","valueString":"3"},{"key":"GlobalSecureAccessPrivateChannel","valueString":"0"}]}'))
                    }) }
                }
                'deviceAppManagement/mobileAppConfigurations/gsa-id/assignments' {
                    return @{ value = @(@{ target = @{ groupId = 'user-group'; '@odata.type' = '#microsoft.graph.groupAssignmentTarget' } }) }
                }
                'deviceAppManagement/mobileAppConfigurations/gsa-id' {
                    return @{
                        id = 'gsa-id'; packageId = 'com.microsoft.scmx'; targetedMobileApps = @('defender-id')
                        payloadJson = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
                            '{"managedProperty":[{"key":"Global Secure Access","valueString":"3"},{"key":"GlobalSecureAccessPrivateChannel","valueString":"0"}]}'))
                    }
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

    It 'reports the real disabled value, distinguishes assignments, and redacts device status identifiers' {
        $warnings = @()
        $output = & (Join-Path $script:Root 'scripts/bootstrap/Get-CaCAppInventory.ps1') `
            -TenantId 'test-tenant' -ClientId 'test-client' -IncludeChildGsa -WarningAction SilentlyContinue -WarningVariable warnings |
            Out-String
        $output | Should -Match '"GlobalSecureAccessPrivateChannel"'
        $output | Should -Match '"Value": "0"'
        $output | Should -Match '"ForcedOn": false'
        $output | Should -Match '"Included": false'
        $output | Should -Match '"Status": "compliant"'
        $output | Should -Not -Match 'PRIVATE-'
        ($warnings -join ' ') | Should -Match 'Live GSA is not forced on'
        Should -Invoke Connect-CaCGraph -Times 1 -Exactly -ParameterFilter { $ReadOnly }
        Should -Invoke Invoke-CaCGraphRequest -ModuleName IntuneCaC -Times 0 -ParameterFilter { $Method -ne 'GET' }
    }

    It 'surfaces unavailable status evidence rather than treating an error as an empty healthy result' {
        Mock Invoke-CaCGraphRequest -ModuleName IntuneCaC { throw 'Forbidden status read' } -ParameterFilter { $Uri -like '*/deviceStatuses' }
        { & (Join-Path $script:Root 'scripts/bootstrap/Get-CaCAppInventory.ps1') `
            -TenantId 'test-tenant' -ClientId 'test-client' -IncludeChildGsa } | Should -Throw '*Forbidden status read*'
    }
}
