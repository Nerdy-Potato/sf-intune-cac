BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ScriptPath = Join-Path $script:Root 'scripts/bootstrap/Remove-CaCLocalAdminRecoveryPolicy.ps1'
    Import-Module (Join-Path $script:Root 'src/IntuneCaC/IntuneCaC.psd1') -Force
    . (Join-Path $script:Root 'scripts/bootstrap/LocalAdminRecoveryPolicy.Common.ps1')

    # Real tenant shape, read from the live 'Recover Teen Admin' policy.
    $global:TeenGroupId = '0b6f1bf2-882b-4b60-a857-6e539d2b0b4f'
    $script:TeenSid = 'S-1-12-1-191831026-1264617515-1399740328-1326132125'
    $global:AdultGroupId = '4ed5dd72-7786-4495-acc5-6c7fe6155c09'

    function New-RecoverySettings {
        param(
            [string] $Sid,
            [string] $Action = 'add_update',
            [string[]] $Groups = @('administrators'),
            [int] $Copies = 1
        )
        $p = 'device_vendor_msft_policy_config_localusersandgroups_configure'
        $setting = @{
            settingInstance = @{
                '@odata.type'               = '#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance'
                settingDefinitionId         = $p
                groupSettingCollectionValue = @(@{
                        children = @(@{
                                settingDefinitionId         = "$($p)_groupconfiguration_accessgroup"
                                groupSettingCollectionValue = @(@{
                                        children = @(
                                            @{
                                                settingDefinitionId          = "$($p)_groupconfiguration_accessgroup_desc"
                                                choiceSettingCollectionValue = @($Groups | ForEach-Object { @{ value = "$($p)_groupconfiguration_accessgroup_desc_$_"; children = @() } })
                                            },
                                            @{
                                                settingDefinitionId = "$($p)_groupconfiguration_accessgroup_action"
                                                choiceSettingValue  = @{ value = "$($p)_groupconfiguration_accessgroup_action_$Action"; children = @() }
                                            },
                                            @{
                                                settingDefinitionId = "$($p)_groupconfiguration_accessgroup_userselectiontype"
                                                choiceSettingValue  = @{
                                                    value    = "$($p)_groupconfiguration_accessgroup_userselectiontype_users"
                                                    children = @(@{
                                                            settingDefinitionId          = "$($p)_groupconfiguration_accessgroup_users"
                                                            simpleSettingCollectionValue = @(@{ value = $Sid })
                                                        })
                                                }
                                            }
                                        )
                                    })
                            })
                    })
            }
        }
        return @(1..$Copies | ForEach-Object { $setting })
    }

    function Invoke-Retirement {
        param([hashtable] $Policies, [string[]] $Name)

        $global:RecoveryCalls = [System.Collections.Generic.List[object]]::new()
        $global:RecoveryPolicies = $Policies

        Mock -CommandName Import-Module {}
        Mock -CommandName Connect-CaCGraph {}
        Mock -CommandName Write-Host {}
        Mock -CommandName Get-Module {
            $fake = [pscustomobject]@{}
            $fake | Add-Member -MemberType ScriptMethod -Name NewBoundScriptBlock -Value {
                param([scriptblock] $ScriptBlock) $ScriptBlock
            } -Force -PassThru
        }
        function global:Invoke-CaCGraphRequest {
            param([string] $Method, [string] $Uri, $Body)
            $global:RecoveryCalls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri }) | Out-Null

            if ($Method -eq 'GET' -and $Uri -match '^deviceManagement/configurationPolicies\?\$filter=([^&]+)&') {
                $filter = [System.Uri]::UnescapeDataString($Matches[1])
                $policyName = ($filter -replace "^name eq '", '') -replace "'$", ''
                $found = $global:RecoveryPolicies[$policyName]
                if (-not $found) { return @{ value = @() } }
                return @{ value = @($found.Matches) }
            }
            if ($Method -eq 'GET' -and $Uri -match '^groups\?\$filter=([^&]+)&') {
                $filter = [System.Uri]::UnescapeDataString($Matches[1])
                if ($filter -eq "displayName eq 'CaC-Tier-Teen'") { return @{ value = @(@{ id = $global:TeenGroupId }) } }
                if ($filter -eq "displayName eq 'CaC-Tier-Adult'") { return @{ value = @(@{ id = $global:AdultGroupId }) } }
                return @{ value = @() }
            }
            if ($Method -eq 'GET' -and $Uri -match '^deviceManagement/configurationPolicies/([^/]+)/settings$') {
                $id = $Matches[1]
                $entry = $global:RecoveryPolicies.Values | Where-Object { $_.Matches[0].id -eq $id } | Select-Object -First 1
                return @{ value = @($entry.Settings) }
            }
            if ($Method -eq 'DELETE') { return $null }
            throw "Unexpected Graph call: $Method $Uri"
        }

        $arguments = @{ TenantId = 'tenant'; ClientId = 'client'; Confirm = $false }
        if ($Name) { $arguments.Name = $Name }
        try {
            & $script:ScriptPath @arguments
        }
        finally {
            Remove-Item -Path function:global:Invoke-CaCGraphRequest -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Local admin recovery policy retirement' {
    It 'derives the SID Windows uses for an Entra group object ID' {
        ConvertTo-CaCEntraGroupSid -ObjectId $global:TeenGroupId | Should -Be $script:TeenSid
    }

    It 'deletes both recovery policies once each is proven to grant only its tier group' {
        $adultSid = ConvertTo-CaCEntraGroupSid -ObjectId $global:AdultGroupId
        Invoke-Retirement -Policies @{
            'Recover Adult Admin' = @{ Matches = @(@{ id = 'adult-policy'; name = 'Recover Adult Admin' }); Settings = New-RecoverySettings -Sid $adultSid }
            'Recover Teen Admin'  = @{ Matches = @(@{ id = 'teen-policy'; name = 'Recover Teen Admin' }); Settings = New-RecoverySettings -Sid $script:TeenSid }
        }

        $deletes = @($global:RecoveryCalls | Where-Object Method -EQ 'DELETE')
        $deletes.Uri | Should -Be @(
            'deviceManagement/configurationPolicies/adult-policy',
            'deviceManagement/configurationPolicies/teen-policy'
        )
    }

    It 'is a no-op when the recovery policy no longer exists' {
        Invoke-Retirement -Policies @{} -Name 'Recover Teen Admin'
        @($global:RecoveryCalls | Where-Object Method -EQ 'DELETE') | Should -BeNullOrEmpty
    }

    It 'refuses ambiguous names without deleting anything' {
        $policies = @{
            'Recover Teen Admin' = @{
                Matches  = @(@{ id = 'one'; name = 'Recover Teen Admin' }, @{ id = 'two'; name = 'Recover Teen Admin' })
                Settings = New-RecoverySettings -Sid $script:TeenSid
            }
        }
        { Invoke-Retirement -Policies $policies -Name 'Recover Teen Admin' } | Should -Throw '*more than one*'
        @($global:RecoveryCalls | Where-Object Method -EQ 'DELETE') | Should -BeNullOrEmpty
    }

    It 'refuses a policy whose grant is <Case> and deletes nothing, even the valid one' -ForEach @(
        @{ Case = 'a different SID'; Sid = 'S-1-12-1-1-2-3-4'; Action = 'add_update'; Groups = @('administrators'); Copies = 1; Expect = '*members are not exactly*' }
        @{ Case = 'a Replace action'; Sid = $null; Action = 'add_replace'; Groups = @('administrators'); Copies = 1; Expect = '*not Add (Update)*' }
        @{ Case = 'a different local group'; Sid = $null; Action = 'add_update'; Groups = @('users'); Copies = 1; Expect = '*only the local Administrators*' }
        @{ Case = 'carrying extra settings'; Sid = $null; Action = 'add_update'; Groups = @('administrators'); Copies = 2; Expect = '*exactly one setting*' }
    ) {
        $teenSid = if ($Sid) { $Sid } else { $script:TeenSid }
        $adultSid = ConvertTo-CaCEntraGroupSid -ObjectId $global:AdultGroupId
        $policies = @{
            'Recover Adult Admin' = @{ Matches = @(@{ id = 'adult-policy'; name = 'Recover Adult Admin' }); Settings = New-RecoverySettings -Sid $adultSid }
            'Recover Teen Admin'  = @{ Matches = @(@{ id = 'teen-policy'; name = 'Recover Teen Admin' }); Settings = New-RecoverySettings -Sid $teenSid -Action $Action -Groups $Groups -Copies $Copies }
        }

        { Invoke-Retirement -Policies $policies } | Should -Throw $Expect
        @($global:RecoveryCalls | Where-Object Method -EQ 'DELETE') | Should -BeNullOrEmpty
    }

    It 'only accepts the two known recovery policy names' {
        { & $script:ScriptPath -Name 'CaC - Windows LAPS' -TenantId t -ClientId c -Confirm:$false } |
            Should -Throw '*does not belong to the set*'
    }
}
