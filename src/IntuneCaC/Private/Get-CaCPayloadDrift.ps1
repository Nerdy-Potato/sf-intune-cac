function Get-CaCPayloadDrift {
    <#
    .SYNOPSIS
        Returns a human readable description of every scalar property that differs between the
        desired payload and the object currently in the tenant.
    .DESCRIPTION
        Only scalar values and arrays of primitives are compared. Nested objects (for example the
        scheduled action tree on a compliance policy) carry server generated ids that would produce
        permanent false drift, so they are re-sent on every write instead of being diffed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Desired,
        [Parameter(Mandatory)] $Actual
    )

    $drift = [System.Collections.Generic.List[string]]::new()

    foreach ($name in @($Desired.Keys)) {
        if ($name -in @('@odata.type', 'displayName')) { continue }

        $desiredValue = $Desired[$name]

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
