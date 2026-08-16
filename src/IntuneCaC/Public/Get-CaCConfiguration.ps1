function Get-CaCConfiguration {
    <#
    .SYNOPSIS
        Loads the whole desired-state configuration from the config tree.
    .DESCRIPTION
        The repository is the source of truth. This function turns the JSON tree into a single
        object graph: tenant settings, accounts, groups with their calculated membership, and every
        Intune policy definition. It performs no network calls, so it is safe to run anywhere.
    .EXAMPLE
        Get-CaCConfiguration -Path ./config
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $Path = (Join-Path -Path $PSScriptRoot -ChildPath '../../../config')
    )

    $root = (Resolve-Path -Path $Path).Path

    $tenant = Get-Content -Path (Join-Path $root 'tenant.json') -Raw | ConvertFrom-Json -AsHashtable
    $users = (Get-Content -Path (Join-Path $root 'identity/users.json') -Raw | ConvertFrom-Json -AsHashtable).users
    $groups = (Get-Content -Path (Join-Path $root 'identity/groups.json') -Raw | ConvertFrom-Json -AsHashtable).groups
    $apps = [System.Collections.Generic.List[object]]::new()
    $appRoot = Join-Path $root 'apps'
    if (Test-Path -Path $appRoot) {
        foreach ($file in Get-ChildItem -Path $appRoot -Filter '*.json' -Recurse | Sort-Object FullName) {
            $document = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json -AsHashtable
            foreach ($app in $document.apps) {
                $app['sourcePath'] = $file.FullName.Substring($root.Length).TrimStart([char]'/', [char]'\')
                $apps.Add($app)
            }
        }
    }

    $primaryDomain = if ($tenant.primaryDomain) { $tenant.primaryDomain } else { $tenant.fallbackDomain }

    foreach ($user in $users) {
        $domain = if ($user.domain -eq 'fallback') { $tenant.fallbackDomain } else { $primaryDomain }
        $user['upn'] = '{0}@{1}' -f $user.upnLocalPart, $domain
    }

    foreach ($group in $groups) {
        $matched = @(
            switch ($group.membership.source) {
                'tier' { $users | Where-Object { $_.tier -in $group.membership.values } }
                'accountType' { $users | Where-Object { $_.accountType -in $group.membership.values } }
                'explicit' { $users | Where-Object { $_.id -in $group.membership.values } }
            }
        )

        # Always an array: a tier with one member (or none) must not collapse to a scalar or $null.
        $group['members'] = @($matched | ForEach-Object { $_.upn } | Sort-Object)
    }

    $policies = [System.Collections.Generic.List[object]]::new()
    $policyRoot = Join-Path $root 'intune'

    if (Test-Path -Path $policyRoot) {
        foreach ($file in Get-ChildItem -Path $policyRoot -Filter '*.json' -Recurse | Sort-Object FullName) {
            $policy = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json -AsHashtable
            $policy['sourcePath'] = $file.FullName.Substring($root.Length).TrimStart([char]'/', [char]'\')

            if (-not (Test-CaCHasProperty -InputObject $policy -Name 'enabled')) { $policy['enabled'] = $true }

            $policies.Add($policy)
        }
    }

    return [pscustomobject]@{
        Root          = $root
        Tenant        = $tenant
        PrimaryDomain = $primaryDomain
        Users         = $users
        Groups        = $groups
        Apps          = $apps.ToArray()
        Policies      = $policies.ToArray()
    }
}
