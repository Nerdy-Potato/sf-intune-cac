function Test-CaCManagedObject {
    <#
    .SYNOPSIS
        True when a remote object carries this repository's managed marker (and, optionally, its
        display-name prefix).
    .NOTES
        Intentionally duplicated from src/IntuneCaC/Private/Test-CaCManagedObject.ps1. See
        Test-CaCHasProperty.ps1 in this module for the rationale.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)] [string[]] $ManagedMarker,
        [Parameter()] [string] $NamePrefix
    )

    $description = Get-CaCProperty -InputObject $Object -Name 'description'
    $hasMarker = @($ManagedMarker | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and $description -like "*$_*"
        }).Count -gt 0
    if ([string]::IsNullOrWhiteSpace([string] $description) -or -not $hasMarker) {
        return $false
    }

    if ($PSBoundParameters.ContainsKey('NamePrefix')) {
        $displayName = Get-CaCProperty -InputObject $Object -Name 'displayName'
        if ([string]::IsNullOrWhiteSpace([string] $displayName) -or
            $displayName -notlike "$NamePrefix*") {
            return $false
        }
    }

    return $true
}
