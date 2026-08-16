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

function Get-CaCProperty {
    <#
    .SYNOPSIS
        Property accessor that works for both hashtables and PSCustomObjects.
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
