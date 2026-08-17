function Test-CaCManagedObject {
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
