Set-StrictMode -Version Latest

# The only portal-created recovery policies this retirement flow may delete, and the tier user group
# each one is expected to grant. Anything else - or any other shape - is refused.
$script:CaCLocalAdminRecoveryPolicies = [ordered]@{
    'Recover Adult Admin' = 'CaC-Tier-Adult'
    'Recover Teen Admin'  = 'CaC-Tier-Teen'
}

function Get-CaCRecoveryProperty {
    param($InputObject, [string] $Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-CaCEntraGroupSid {
    <#
    .SYNOPSIS
        Converts an Entra group object ID into the S-1-12-1 SID Windows uses for it locally.
    #>
    param([Parameter(Mandatory)] [string] $ObjectId)

    $bytes = ([guid]::Parse($ObjectId)).ToByteArray()
    $parts = foreach ($index in 0..3) { [System.BitConverter]::ToUInt32($bytes, $index * 4) }
    return 'S-1-12-1-' + ($parts -join '-')
}

function Get-CaCLocalAdminRecoveryGrant {
    <#
    .SYNOPSIS
        Reduces a Settings Catalog settings list to the single local group grant it makes, or
        throws if the policy is anything other than one LocalUsersAndGroups grant.
    #>
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Settings)

    if ($Settings.Count -ne 1) {
        throw "Expected exactly one setting, found $($Settings.Count)."
    }

    $instance = Get-CaCRecoveryProperty -InputObject $Settings[0] -Name 'settingInstance'
    if (-not $instance) { $instance = $Settings[0] }

    $prefix = 'device_vendor_msft_policy_config_localusersandgroups_configure'
    if ((Get-CaCRecoveryProperty -InputObject $instance -Name 'settingDefinitionId') -ne $prefix) {
        throw 'The setting is not LocalUsersAndGroups/Configure.'
    }

    $outer = @(Get-CaCRecoveryProperty -InputObject $instance -Name 'groupSettingCollectionValue')
    if ($outer.Count -ne 1) { throw 'Expected one LocalUsersAndGroups configuration.' }

    $accessGroups = @(Get-CaCRecoveryProperty -InputObject $outer[0] -Name 'children')
    if ($accessGroups.Count -ne 1 -or
        (Get-CaCRecoveryProperty -InputObject $accessGroups[0] -Name 'settingDefinitionId') -ne "$($prefix)_groupconfiguration_accessgroup") {
        throw 'Expected exactly one access group entry.'
    }

    $entries = @(Get-CaCRecoveryProperty -InputObject $accessGroups[0] -Name 'groupSettingCollectionValue')
    if ($entries.Count -ne 1) { throw 'Expected exactly one access group entry.' }

    $group = $null; $action = $null; $selection = $null; $members = @()
    foreach ($child in @(Get-CaCRecoveryProperty -InputObject $entries[0] -Name 'children')) {
        $definition = Get-CaCRecoveryProperty -InputObject $child -Name 'settingDefinitionId'
        switch ($definition) {
            "$($prefix)_groupconfiguration_accessgroup_desc" {
                $values = @(Get-CaCRecoveryProperty -InputObject $child -Name 'choiceSettingCollectionValue')
                $group = @($values | ForEach-Object { Get-CaCRecoveryProperty -InputObject $_ -Name 'value' })
            }
            "$($prefix)_groupconfiguration_accessgroup_action" {
                $action = Get-CaCRecoveryProperty -InputObject (
                    Get-CaCRecoveryProperty -InputObject $child -Name 'choiceSettingValue') -Name 'value'
            }
            "$($prefix)_groupconfiguration_accessgroup_userselectiontype" {
                $choice = Get-CaCRecoveryProperty -InputObject $child -Name 'choiceSettingValue'
                $selection = Get-CaCRecoveryProperty -InputObject $choice -Name 'value'
                foreach ($grandchild in @(Get-CaCRecoveryProperty -InputObject $choice -Name 'children')) {
                    if ((Get-CaCRecoveryProperty -InputObject $grandchild -Name 'settingDefinitionId') -ne "$($prefix)_groupconfiguration_accessgroup_users") {
                        throw 'Unexpected member selection setting.'
                    }
                    $members += @(@(Get-CaCRecoveryProperty -InputObject $grandchild -Name 'simpleSettingCollectionValue') |
                            ForEach-Object { [string] (Get-CaCRecoveryProperty -InputObject $_ -Name 'value') })
                }
            }
            default { throw "Unexpected access group setting '$definition'." }
        }
    }

    return [pscustomobject]@{
        Groups    = @($group)
        Action    = $action
        Selection = $selection
        Members   = @($members)
    }
}

function Assert-CaCLocalAdminRecoveryGrant {
    <#
    .SYNOPSIS
        Fails closed unless the grant is exactly "add (update) <expected SID> to Administrators".
    #>
    param(
        [Parameter(Mandatory)] $Grant,
        [Parameter(Mandatory)] [string] $ExpectedSid,
        [Parameter(Mandatory)] [string] $PolicyName
    )

    $prefix = 'device_vendor_msft_policy_config_localusersandgroups_configure_groupconfiguration_accessgroup'
    $problems = [System.Collections.Generic.List[string]]::new()
    if (@($Grant.Groups).Count -ne 1 -or $Grant.Groups[0] -ne "$($prefix)_desc_administrators") {
        $problems.Add('it does not target only the local Administrators group')
    }
    if ($Grant.Action -ne "$($prefix)_action_add_update") {
        $problems.Add('its action is not Add (Update)')
    }
    if ($Grant.Selection -ne "$($prefix)_userselectiontype_users") {
        $problems.Add('its member selection type is not Users')
    }
    if (@($Grant.Members).Count -ne 1 -or $Grant.Members[0] -ne $ExpectedSid) {
        $problems.Add("its members are not exactly $ExpectedSid")
    }

    if ($problems.Count -gt 0) {
        throw "Refusing to delete '$PolicyName': $($problems -join '; ')."
    }
}
