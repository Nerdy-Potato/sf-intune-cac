function Get-CaCExtendedConfiguration {
    <#
    .SYNOPSIS
        Loads reference-implementation policy definitions for the five extended resource kinds.
    .DESCRIPTION
        Deliberately reads from this module's own config-samples/ tree by default, never from the
        repository's real config/ tree, so loading this module can never accidentally pick up (or
        be mistaken for) the live desired-state configuration that the production IntuneCaC module
        deploys. Point -Path at a different folder once real tenant scenarios are being designed.
    .EXAMPLE
        Get-CaCExtendedConfiguration
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $Path = (Join-Path -Path $PSScriptRoot -ChildPath 'config-samples')
    )

    $root = (Resolve-Path -Path $Path).Path
    $policies = [System.Collections.Generic.List[object]]::new()

    if (Test-Path -Path $root) {
        foreach ($file in Get-ChildItem -Path $root -Filter '*.json' -Recurse | Sort-Object FullName) {
            $policy = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json -AsHashtable
            $policy['sourcePath'] = $file.FullName.Substring($root.Length).TrimStart([char]'/', [char]'\')

            if (-not (Test-CaCHasProperty -InputObject $policy -Name 'enabled')) { $policy['enabled'] = $true }

            $policies.Add($policy)
        }
    }

    return [pscustomobject]@{
        Root     = $root
        Policies = $policies.ToArray()
    }
}
