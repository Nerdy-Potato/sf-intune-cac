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

    $gsa = @($Configuration.Policies | Where-Object name -EQ 'android-defender-gsa-child')
    if ($gsa.Count -ne 1) {
        New-ProtectionFinding 'android-defender-gsa-child' 'Exactly one enabled child Android GSA policy is required.'
    }
    else {
        $policy = $gsa[0]
        $payload = $policy.payload
        if (-not $policy.enabled -or $policy.resource -ne 'mobileAppConfigurations' -or
            $payload.'@odata.type' -ne '#microsoft.graph.androidManagedStoreAppConfiguration' -or
            (Get-CaCProperty $payload 'packageId') -ne 'com.microsoft.scmx' -or
            (Get-CaCProperty $payload 'profileApplicability') -ne 'androidDeviceOwner' -or
            @((Get-CaCProperty $policy 'targetApps')).Count -ne 1 -or
            @((Get-CaCProperty $policy 'targetApps'))[0] -ne 'android-defender' -or
            -not (Test-DeviceAssignment $policy.assignments 'include')) {
            New-ProtectionFinding $policy.name 'GSA must target Defender on Android Device Owner and include child devices without exclusions.'
        }

        try {
            $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
                [string] (Get-CaCProperty $payload 'payloadJson'))) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ((Get-CaCProperty $decoded 'kind') -ne 'androidenterprise#managedConfiguration' -or
                (Get-CaCProperty $decoded 'productId') -ne 'app:com.microsoft.scmx') {
                throw 'The managed configuration must identify the Defender Android product.'
            }
            foreach ($key in @('Global Secure Access', 'GlobalSecureAccessPrivateChannel')) {
                $setting = @((Get-CaCProperty $decoded 'managedProperty') | Where-Object {
                    (Get-CaCProperty $_ 'key') -ceq $key
                })
                if ($setting.Count -ne 1 -or
                    (Get-CaCProperty $setting[0] 'valueString') -isnot [string] -or
                    (Get-CaCProperty $setting[0] 'valueString') -cne '3' -or
                    @($setting[0].Keys | Where-Object { $_ -like 'value*' -and $_ -ne 'valueString' }).Count -ne 0) {
                    throw "'$key' must occur exactly once with valueString='3' and no competing value type."
                }
            }
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
        -not (Test-DeviceAssignment $defender[0].assignments 'required')) {
        New-ProtectionFinding 'android-defender' 'Defender must be a required app for child devices without exclusions or uninstall assignments.'
    }
}
