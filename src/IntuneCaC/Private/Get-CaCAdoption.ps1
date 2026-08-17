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

    if (($Kind -eq 'Group' -and $Id -ne 'sg-autopilot-device-preparation-child') -or
        ($Kind -eq 'App' -and $Id -notin @('android-authenticator', 'ios-authenticator'))) {
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

    foreach ($property in @('displayName', 'securityEnabled', 'mailEnabled', 'groupTypes')) {
        if (-not (Test-CaCHasProperty -InputObject $Object -Name $property)) {
            return $false
        }
    }

    $actualTypes = @(Get-CaCProperty -InputObject $Object -Name 'groupTypes')
    $expectedTypes = @(Get-CaCProperty -InputObject $Spec -Name 'groupTypes')

    return (
        (Get-CaCProperty -InputObject $Spec -Name 'id') -eq 'sg-autopilot-device-preparation-child' -and
        (Get-CaCProperty -InputObject $Object -Name 'displayName') -eq
            (Get-CaCProperty -InputObject $Spec -Name 'displayName') -and
        (Get-CaCProperty -InputObject $Spec -Name 'displayName') -eq
            'CaC-Autopilot-DevicePreparation-Child' -and
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

    $identity = Get-CaCProperty -InputObject $Spec -Name 'identity'
    $identityKind = Get-CaCProperty -InputObject $identity -Name 'kind'
    $identityValue = Get-CaCProperty -InputObject $identity -Name 'value'
    $specId = Get-CaCProperty -InputObject $Spec -Name 'id'
    $expected = @{
        'android-authenticator' = @{
            ODataType = '#microsoft.graph.managedAndroidStoreApp'
            Kind      = 'packageId'
            Value     = 'com.azure.authenticator'
        }
        'ios-authenticator' = @{
            ODataType = '#microsoft.graph.iosStoreApp'
            Kind      = 'bundleId'
            Value     = 'com.microsoft.azureauthenticator'
        }
    }

    if (-not $expected.ContainsKey($specId) -or
        $identityKind -ne $expected[$specId].Kind -or
        $identityValue -ne $expected[$specId].Value -or
        (Get-CaCProperty -InputObject $Spec -Name 'odataType') -ne $expected[$specId].ODataType) {
        return $false
    }

    return (
        (Get-CaCProperty -InputObject $Object -Name 'displayName') -eq
            'Microsoft Authenticator' -and
        (Get-CaCProperty -InputObject $Spec -Name 'displayName') -eq
            'Microsoft Authenticator' -and
        (Get-CaCProperty -InputObject $Object -Name '@odata.type') -eq
            (Get-CaCProperty -InputObject $Spec -Name 'odataType') -and
        (Get-CaCProperty -InputObject $Object -Name $identityKind) -eq $identityValue
    )
}
