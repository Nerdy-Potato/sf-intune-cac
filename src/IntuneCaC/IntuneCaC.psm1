Set-StrictMode -Version Latest

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
