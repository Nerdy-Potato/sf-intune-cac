function ConvertTo-CaCCanonicalJson {
    <#
    .SYNOPSIS
        Serializes a value to JSON with dictionary/object keys sorted, so two structurally equal
        values always produce identical text regardless of hashtable enumeration order.
    .DESCRIPTION
        Config-loaded values are hashtables (from ConvertFrom-Json -AsHashtable), whose key
        enumeration order is not guaranteed. Values read back from Graph are PSCustomObjects,
        which preserve declaration order. Comparing ConvertTo-Json output directly between the two
        is therefore order-sensitive and can report false drift/false safety for two payloads that
        are actually identical. Sorting keys at every level before serializing removes that
        sensitivity. Array element order is left untouched - only key order is normalized.
    .EXAMPLE
        ConvertTo-CaCCanonicalJson -InputObject $policy.payload
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        $InputObject
    )

    function ConvertTo-CaCCanonicalValue {
        param([AllowNull()] $Value)

        if ($null -eq $Value) { return $null }

        if ($Value -is [System.Collections.IDictionary]) {
            $ordered = [ordered]@{}
            foreach ($key in ($Value.Keys | Sort-Object)) {
                $ordered[[string] $key] = ConvertTo-CaCCanonicalValue -Value $Value[$key]
            }
            return $ordered
        }

        if ($Value -is [System.Management.Automation.PSCustomObject]) {
            $ordered = [ordered]@{}
            foreach ($name in ($Value.PSObject.Properties.Name | Sort-Object)) {
                $ordered[$name] = ConvertTo-CaCCanonicalValue -Value $Value.PSObject.Properties[$name].Value
            }
            return $ordered
        }

        if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
            return @($Value | ForEach-Object { ConvertTo-CaCCanonicalValue -Value $_ })
        }

        return $Value
    }

    return (ConvertTo-CaCCanonicalValue -Value $InputObject) | ConvertTo-Json -Depth 25 -Compress
}
