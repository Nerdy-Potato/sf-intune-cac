function Get-CaCProperty {
    <#
    .SYNOPSIS
        Property accessor that works for both hashtables and PSCustomObjects.
    .NOTES
        Intentionally duplicated from src/IntuneCaC/Private/Get-CaCProperty.ps1. See
        Test-CaCHasProperty.ps1 in this module for the rationale.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    if (-not (Test-CaCHasProperty -InputObject $InputObject -Name $Name)) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject[$Name] }

    return $InputObject.PSObject.Properties[$Name].Value
}
