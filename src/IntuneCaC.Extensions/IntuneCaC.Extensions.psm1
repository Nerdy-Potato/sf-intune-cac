Set-StrictMode -Version Latest

# This module is intentionally standalone: it does not import or depend on the production
# IntuneCaC module, so it can be built, tested and staged for review without any risk of
# touching the code path that is already deployed and running against the live tenant. A small
# number of low-level Graph/JSON helpers are duplicated from IntuneCaC/Private (see the header
# comment on each file) rather than imported, for the same reason.

$script:PublicFunctions = @()

foreach ($scope in 'Private', 'Public') {
    $folder = Join-Path -Path $PSScriptRoot -ChildPath $scope
    if (-not (Test-Path -Path $folder)) { continue }

    foreach ($file in Get-ChildItem -Path $folder -Filter '*.ps1' | Sort-Object Name) {
        . $file.FullName
        if ($scope -eq 'Public') { $script:PublicFunctions += $file.BaseName }
    }
}

Export-ModuleMember -Function $script:PublicFunctions
