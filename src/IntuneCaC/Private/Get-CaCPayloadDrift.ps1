function Get-CaCPayloadDrift {
    <#
    .SYNOPSIS
        Returns a human readable description of every scalar property that differs between the
        desired payload and the object currently in the tenant.
    .DESCRIPTION
        Only scalar values and arrays of primitives are compared. Nested objects (for example the
        scheduled action tree on a compliance policy) carry server generated ids that would produce
        permanent false drift, so they are re-sent on every write instead of being diffed.

        Exception: the Settings Catalog `settings` array (deviceManagementConfigurationPolicies) is
        compared as a single opaque, normalized-JSON blob rather than being skipped like other
        arrays-of-objects. Per design (.squad/decisions/inbox/morpheus-local-admin-settings-catalog-
        design.md) this is a deliberate v1 minimal-risk choice: whole-payload diffing, not per-setting
        deep diff. Without this, changes to `settings` would never be detected as drift.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Desired,
        [Parameter(Mandatory)] $Actual
    )

    $drift = [System.Collections.Generic.List[string]]::new()

    function ConvertTo-CaCSettingsComparable {
        param($Value)

        if ($null -eq $Value) { return $null }

        $metadataKeys = @(
            'auditRuleInformation',
            'settingInstanceTemplateReference',
            'settingValueTemplateReference'
        )

        if ($Value -is [System.Collections.IDictionary]) {
            $ordered = [ordered]@{}
            foreach ($key in @($Value.Keys | Sort-Object)) {
                if ($key -eq 'id') { continue }

                $childValue = $Value[$key]
                if ($key -in $metadataKeys -and $null -eq $childValue) { continue }

                $ordered[$key] = ConvertTo-CaCSettingsComparable -Value $childValue
            }
            return $ordered
        }

        if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
            return , @($Value | ForEach-Object { ConvertTo-CaCSettingsComparable -Value $_ })
        }

        if ($Value -is [pscustomobject]) {
            $ordered = [ordered]@{}
            foreach ($property in @($Value.PSObject.Properties.Name | Sort-Object)) {
                if ($property -eq 'id') { continue }

                $childValue = $Value.$property
                if ($property -in $metadataKeys -and $null -eq $childValue) { continue }

                $ordered[$property] = ConvertTo-CaCSettingsComparable -Value $childValue
            }
            return $ordered
        }

        return $Value
    }

    foreach ($name in @($Desired.Keys)) {
        if ($name -in @('@odata.type', 'displayName')) { continue }

        $desiredValue = $Desired[$name]

        if ($name -eq 'settings' -and $desiredValue -is [System.Collections.IEnumerable] -and $desiredValue -isnot [string]) {
            $actualValue = Get-CaCProperty -InputObject $Actual -Name $name
            $desiredJson = (ConvertTo-CaCSettingsComparable -Value @($desiredValue) | ConvertTo-Json -Depth 50 -Compress)
            $actualJson = (ConvertTo-CaCSettingsComparable -Value @($actualValue) | ConvertTo-Json -Depth 50 -Compress)
            if ($desiredJson -ne $actualJson) {
                $drift.Add("settings: <settings tree differs>")
            }
            continue
        }

        if ($desiredValue -is [System.Collections.IDictionary]) { continue }
        if ($desiredValue -is [System.Collections.IEnumerable] -and $desiredValue -isnot [string]) {
            $items = @($desiredValue)
            if ($items | Where-Object { $_ -is [System.Collections.IDictionary] }) { continue }

            $actualItems = @(Get-CaCProperty -InputObject $Actual -Name $name)
            if ((($items | Sort-Object) -join '|') -ne (($actualItems | Sort-Object) -join '|')) {
                $drift.Add(("{0}: [{1}] -> [{2}]" -f $name, ($actualItems -join ', '), ($items -join ', ')))
            }

            continue
        }

        $actualValue = Get-CaCProperty -InputObject $Actual -Name $name

        if ([string] $actualValue -ne [string] $desiredValue) {
            $drift.Add(("{0}: '{1}' -> '{2}'" -f $name, $actualValue, $desiredValue))
        }
    }

    return $drift.ToArray()
}
