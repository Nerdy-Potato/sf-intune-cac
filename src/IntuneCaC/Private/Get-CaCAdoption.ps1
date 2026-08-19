function Get-CaCAdoptionSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Configuration,
        [Parameter(Mandatory)] [ValidateSet('Group', 'App')] [string] $Kind,
        [Parameter(Mandatory)] [string] $Id
    )

    $adoption = Get-CaCProperty -InputObject $Configuration.Tenant -Name 'adoption'
    if (-not $adoption -or (Get-CaCProperty -InputObject $adoption -Name 'enabled') -ne $true) {
        return $null
    }

    # Keep in sync with the guard lists in src/IntuneCaC/Public/Test-CaCConfiguration.ps1.
    $adoptableGroupIds = @(
        'sg-autopilot-device-preparation-child', 'sg-nuclear-family'
    )
    $adoptableAppIds = @(
        'android-authenticator', 'ios-authenticator',
        'android-defender', 'android-copilot', 'android-word', 'android-excel',
        'android-powerpoint', 'android-onenote', 'android-outlook', 'android-teams',
        'android-onedrive', 'android-edge',
        'android-spotify-kids', 'android-moonlight', 'android-steam-link',
        'android-windows-app', 'android-xbox'
    )
    if (($Kind -eq 'Group' -and $Id -notin $adoptableGroupIds) -or
        ($Kind -eq 'App' -and $Id -notin $adoptableAppIds)) {
        return $null
    }

    $property = if ($Kind -eq 'Group') { 'groups' } else { 'apps' }
    return @(
        Get-CaCProperty -InputObject $adoption -Name $property |
            Where-Object { (Get-CaCProperty -InputObject $_ -Name 'id') -eq $Id } |
            Select-Object -First 1
    )
}

function Test-CaCAdoptionGroupShape {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)] $Spec
    )

    # Fully data-driven against the configured adoption spec (config/tenant.json's
    # adoption.groups entries) - no per-group hardcoding here. The spec's own
    # displayName/securityEnabled/mailEnabled/groupTypes fields are the source of
    # truth, matched against the immutable shape of the live remote object.
    foreach ($property in @('displayName', 'securityEnabled', 'mailEnabled', 'groupTypes')) {
        if (-not (Test-CaCHasProperty -InputObject $Object -Name $property)) {
            return $false
        }
        if (-not (Test-CaCHasProperty -InputObject $Spec -Name $property)) {
            return $false
        }
    }

    $actualTypes = @(Get-CaCProperty -InputObject $Object -Name 'groupTypes')
    $expectedTypes = @(Get-CaCProperty -InputObject $Spec -Name 'groupTypes')

    return (
        (Get-CaCProperty -InputObject $Object -Name 'displayName') -eq
            (Get-CaCProperty -InputObject $Spec -Name 'displayName') -and
        [bool](Get-CaCProperty -InputObject $Object -Name 'securityEnabled') -eq
            [bool](Get-CaCProperty -InputObject $Spec -Name 'securityEnabled') -and
        [bool](Get-CaCProperty -InputObject $Object -Name 'mailEnabled') -eq
            [bool](Get-CaCProperty -InputObject $Spec -Name 'mailEnabled') -and
        (($actualTypes | Sort-Object) -join '|') -eq (($expectedTypes | Sort-Object) -join '|')
    )
}

function Test-CaCAdoptionAppIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)] $Spec
    )

    # Fully data-driven against the configured adoption spec (config/tenant.json's
    # adoption.apps entries) - no per-app hardcoding here. The spec's own
    # displayName/odataType/identity fields are the source of truth, matched
    # against the immutable identity of the live remote object.
    $identity = Get-CaCProperty -InputObject $Spec -Name 'identity'
    $identityKind = Get-CaCProperty -InputObject $identity -Name 'kind'
    $identityValue = Get-CaCProperty -InputObject $identity -Name 'value'
    $specODataType = Get-CaCProperty -InputObject $Spec -Name 'odataType'
    $specDisplayName = Get-CaCProperty -InputObject $Spec -Name 'displayName'

    if (-not $identityKind -or -not $identityValue -or -not $specODataType -or -not $specDisplayName) {
        return $false
    }

    return (
        (Get-CaCProperty -InputObject $Object -Name 'displayName') -eq $specDisplayName -and
        (Get-CaCProperty -InputObject $Object -Name '@odata.type') -eq $specODataType -and
        (Get-CaCProperty -InputObject $Object -Name $identityKind) -eq $identityValue
    )
}
