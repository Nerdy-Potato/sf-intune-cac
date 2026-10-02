function Test-CaCChildAndroidProtection {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Configuration)

    function New-ProtectionFinding {
        param([string] $Target, [string] $Message)
        [pscustomobject]@{
            Severity = 'Error'
            Rule     = 'safety/child-android-gsa'
            Target   = $Target
            Message  = $Message
        }
    }

    function Test-DeviceAssignment {
        param($Assignments, [string] $Intent)
        return @($Assignments | Where-Object {
            $_.group -eq 'sg-devices-child' -and $_.intent -eq $Intent
        }).Count -eq 1 -and @($Assignments | Where-Object {
            $_.intent -in @('exclude', 'uninstall')
        }).Count -eq 0
    }

    function Test-ChildUserAssignment {
        param($Assignments, [string] $Intent)
        return @($Assignments | Where-Object { $_.group -eq 'sg-tier-child' -and $_.intent -eq $Intent }).Count -eq 1
    }

    $gsa = @($Configuration.Policies | Where-Object name -EQ 'android-defender-gsa-child')
    if ($gsa.Count -ne 1) {
        New-ProtectionFinding 'android-defender-gsa-child' 'Exactly one enabled child Android GSA policy is required.'
    }
    else {
        $policy = $gsa[0]
        $payload = $policy.payload
        if (-not $policy.enabled -or $policy.resource -ne 'mobileAppConfigurations' -or
            $payload.'@odata.type' -ne '#microsoft.graph.androidManagedStoreAppConfiguration' -or
            (Get-CaCProperty $payload 'packageId') -ne 'app:com.microsoft.scmx' -or
            (Get-CaCProperty $payload 'profileApplicability') -ne 'androidDeviceOwner' -or
            @((Get-CaCProperty $policy 'targetApps')).Count -ne 1 -or
            @((Get-CaCProperty $policy 'targetApps'))[0] -ne 'android-defender' -or
            -not (Test-DeviceAssignment $policy.assignments 'include') -or
            -not (Test-ChildUserAssignment $policy.assignments 'include')) {
            New-ProtectionFinding $policy.name 'GSA must target Defender on Android Device Owner and include both child user and device groups without exclusions.'
        }

        # Typed contract: main GSA forced on (valueInteger 3) and Private Access off (valueInteger 0).
        # Private Access is not used; 0 is intended, not a loss of protection.
        try {
            $decoded = ConvertFrom-CaCManagedConfigurationPayload ([string] (Get-CaCProperty $payload 'payloadJson'))
            $contractErrors = @(Test-CaCChildGsaManagedProperties $decoded)
            if ($contractErrors) { throw ($contractErrors -join ' ') }
        }
        catch {
            New-ProtectionFinding $policy.name "Invalid mandatory GSA payload: $($_.Exception.Message)"
        }
    }

    $restrictions = @($Configuration.Policies | Where-Object name -EQ 'android-fully-managed-restrictions-child')
    if ($restrictions.Count -ne 1 -or -not $restrictions[0].enabled -or
        $restrictions[0].resource -ne 'deviceConfigurations' -or
        $restrictions[0].payload.'@odata.type' -ne '#microsoft.graph.androidDeviceOwnerGeneralDeviceConfiguration' -or
        (Get-CaCProperty $restrictions[0].payload 'vpnAlwaysOnPackageIdentifier') -ne 'com.microsoft.scmx' -or
        (Get-CaCProperty $restrictions[0].payload 'vpnAlwaysOnLockdownMode') -cne $true -or
        -not (Test-DeviceAssignment $restrictions[0].assignments 'include')) {
        New-ProtectionFinding 'android-fully-managed-restrictions-child' 'Child devices require Defender always-on VPN with lockdown, without exclusions.'
    }

    $defender = @($Configuration.Apps | Where-Object id -EQ 'android-defender')
    if ($defender.Count -ne 1 -or
        (Get-CaCProperty $defender[0].payload 'packageId') -ne 'com.microsoft.scmx' -or
        -not (Test-DeviceAssignment $defender[0].assignments 'required') -or
        -not (Test-ChildUserAssignment $defender[0].assignments 'required')) {
        New-ProtectionFinding 'android-defender' 'Defender must be a required app for child users and devices without exclusions or uninstall assignments.'
    }
}
