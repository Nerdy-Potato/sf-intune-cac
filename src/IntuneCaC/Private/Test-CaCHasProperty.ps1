function Test-CaCHasProperty {
    <#
    .SYNOPSIS
        Property presence test that works for both hashtables and PSCustomObjects.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject.Contains($Name) }

    return $null -ne $InputObject.PSObject.Properties[$Name]
}
