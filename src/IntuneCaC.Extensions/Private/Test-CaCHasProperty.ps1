function Test-CaCHasProperty {
    <#
    .SYNOPSIS
        Property presence test that works for both hashtables and PSCustomObjects.
    .NOTES
        Intentionally duplicated from src/IntuneCaC/Private/Test-CaCHasProperty.ps1 to keep this
        staging module fully standalone (see IntuneCaC.Extensions.psm1 header). Keep in sync by
        hand if the production version changes; do not import the production module here.
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
