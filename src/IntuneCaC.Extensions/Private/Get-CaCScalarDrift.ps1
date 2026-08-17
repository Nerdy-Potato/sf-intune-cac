function Get-CaCScalarDrift {
    <#
    .SYNOPSIS
        Scalar/array-of-primitive drift detector with dotted-path exclusions.
    .DESCRIPTION
        The production Get-CaCPayloadDrift only walks top-level properties, which is enough when
        the only nested trees are server-generated ids that get re-sent unconditionally. Two of
        the extended kinds (Conditional Access, Assignment Filters) need to diff *inside* a nested
        object while still excluding specific dotted paths (for example conditions.users on a
        Conditional Access policy, which is deliberately never diffed - see
        Test-CaCConditionalAccessSafety.ps1). This walks the desired payload recursively and skips
        any path that matches (or is nested under) an entry in -ExcludePaths.

        Arrays that contain nested objects are left alone (same "re-send unconditionally" behaviour
        as the production function) rather than attempting a generic deep-array diff; opaque
        setting trees use Get-CaCTreeDrift instead.
    .EXAMPLE
        Get-CaCScalarDrift -Desired $policy -Actual $remote -ExcludePaths @('conditions.users')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Desired,

        [Parameter(Mandatory)]
        $Actual,

        [Parameter()]
        [string[]] $ExcludePaths = @(),

        [Parameter()]
        [string[]] $IgnoreTopLevelKeys = @('@odata.type', 'displayName')
    )

    function Test-CaCPathExcluded {
        param([string] $Path, [string[]] $ExcludePaths)
        foreach ($excluded in $ExcludePaths) {
            if ($Path -eq $excluded -or $Path.StartsWith("$excluded.")) { return $true }
        }
        return $false
    }

    function Compare-CaCNode {
        param($DesiredNode, $ActualNode, [string] $Path, $Drift, [string[]] $ExcludePaths)

        if (Test-CaCPathExcluded -Path $Path -ExcludePaths $ExcludePaths) { return }

        if ($DesiredNode -is [System.Collections.IDictionary]) {
            foreach ($key in @($DesiredNode.Keys)) {
                $childPath = if ($Path) { "$Path.$key" } else { $key }
                if (Test-CaCPathExcluded -Path $childPath -ExcludePaths $ExcludePaths) { continue }
                $actualChild = Get-CaCProperty -InputObject $ActualNode -Name $key
                Compare-CaCNode -DesiredNode $DesiredNode[$key] -ActualNode $actualChild -Path $childPath -Drift $Drift -ExcludePaths $ExcludePaths
            }
            return
        }

        if ($DesiredNode -is [System.Collections.IEnumerable] -and $DesiredNode -isnot [string]) {
            $items = @($DesiredNode)
            if ($items | Where-Object { $_ -is [System.Collections.IDictionary] }) { return }

            $actualItems = @($ActualNode)
            if ((($items | Sort-Object) -join '|') -ne (($actualItems | Sort-Object) -join '|')) {
                $Drift.Add("$Path`: [$($actualItems -join ', ')] -> [$($items -join ', ')]")
            }
            return
        }

        if ([string] $ActualNode -ne [string] $DesiredNode) {
            $Drift.Add("$Path`: '$ActualNode' -> '$DesiredNode'")
        }
    }

    $drift = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @($Desired.Keys)) {
        if ($key -in $IgnoreTopLevelKeys) { continue }
        Compare-CaCNode -DesiredNode $Desired[$key] -ActualNode (Get-CaCProperty -InputObject $Actual -Name $key) -Path $key -Drift $drift -ExcludePaths $ExcludePaths
    }

    return $drift.ToArray()
}
