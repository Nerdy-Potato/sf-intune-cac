function Get-CaCTreeDrift {
    <#
    .SYNOPSIS
        Structural drift detector for opaque setting trees (Settings Catalog "settings" arrays and
        Endpoint Security "settingsDelta" arrays).
    .DESCRIPTION
        Get-CaCPayloadDrift (the production diff engine) deliberately skips nested objects and
        arrays-of-objects, because most of the six production resource kinds only ever carry
        server-generated ids in those trees. Settings Catalog and Endpoint Security are different:
        the entire desired state IS a tree of nested setting instances, so skipping them would
        mean never detecting drift at all for these two kinds.

        This function compares the desired and actual trees item-by-item, keyed by a stable
        identifier (TreeItemKey, e.g. settingInstance.settingDefinitionId for Settings Catalog or
        definitionId for Endpoint Security) rather than by array position, so re-ordering the same
        settings never produces false drift. Only the item's own encoded value is compared; ids,
        odata type echoes on the wrapper, and similar server metadata are ignored by walking the
        item as JSON and comparing normalized text, which is intentionally coarse - see
        DECISIONS.md for why a coarser-grained "whole item differs" result was chosen over a
        recursive field-by-field tree diff for the first version of this reference implementation.
    .EXAMPLE
        Get-CaCTreeDrift -Desired $desiredSettings -Actual $actualSettings -ItemKey 'settingInstance.settingDefinitionId'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Desired,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Actual,

        [Parameter(Mandatory)]
        [string] $ItemKey
    )

    function Get-NestedProperty {
        param($InputObject, [string] $Path)
        $current = $InputObject
        foreach ($segment in $Path -split '\.') {
            if ($null -eq $current) { return $null }
            $current = Get-CaCProperty -InputObject $current -Name $segment
        }
        return $current
    }

    $drift = [System.Collections.Generic.List[string]]::new()

    $desiredByKey = @{}
    foreach ($item in $Desired) {
        $key = [string] (Get-NestedProperty -InputObject $item -Path $ItemKey)
        if ([string]::IsNullOrWhiteSpace($key)) {
            throw "Every desired setting item must have a non-empty '$ItemKey'; found one without it."
        }
        $desiredByKey[$key] = $item
    }

    $actualByKey = @{}
    foreach ($item in $Actual) {
        $key = [string] (Get-NestedProperty -InputObject $item -Path $ItemKey)
        if (-not [string]::IsNullOrWhiteSpace($key)) { $actualByKey[$key] = $item }
    }

    foreach ($key in ($desiredByKey.Keys | Sort-Object)) {
        if (-not $actualByKey.ContainsKey($key)) {
            $drift.Add("setting '$key': missing in tenant, will be added")
            continue
        }

        if ((ConvertTo-CaCCanonicalJson -InputObject $desiredByKey[$key]) -ne (ConvertTo-CaCCanonicalJson -InputObject $actualByKey[$key])) {
            $drift.Add("setting '$key': value differs")
        }
    }

    foreach ($key in ($actualByKey.Keys | Sort-Object)) {
        if (-not $desiredByKey.ContainsKey($key)) {
            $drift.Add("setting '$key': present in tenant but not in configuration, will be removed")
        }
    }

    return $drift.ToArray()
}
