function Get-CaCResourceMap {
    <#
    .SYNOPSIS
        Maps a logical resource kind from a policy definition onto the Graph endpoints used to
        read, write and assign it.
    .DESCRIPTION
        Keeping this in one place means a new policy type is a data change rather than a code
        change, and it keeps the planner honest about which endpoints it is allowed to touch.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $Resource
    )

    $map = @{
        deviceCompliancePolicies     = @{
            Path         = 'deviceManagement/deviceCompliancePolicies'
            AssignAction = 'assign'
            SupportsApps = $false
        }
        deviceConfigurations         = @{
            Path         = 'deviceManagement/deviceConfigurations'
            AssignAction = 'assign'
            SupportsApps = $false
        }
        deviceEnrollmentConfigurations = @{
            Path               = 'deviceManagement/deviceEnrollmentConfigurations'
            AssignAction       = 'assign'
            AssignmentBodyName = 'enrollmentConfigurationAssignments'
            SupportsApps       = $false
        }
        iosManagedAppProtections     = @{
            Path         = 'deviceAppManagement/iosManagedAppProtections'
            AssignAction = 'assign'
            SupportsApps = $true
        }
        androidManagedAppProtections = @{
            Path         = 'deviceAppManagement/androidManagedAppProtections'
            AssignAction = 'assign'
            SupportsApps = $true
        }
        mobileAppConfigurations      = @{
            Path               = 'deviceAppManagement/mobileAppConfigurations'
            AssignAction       = 'assign'
            SupportsApps       = $false
            SupportsTargetApps = $true
        }
    }

    if ($PSBoundParameters.ContainsKey('Resource')) {
        if (-not $map.ContainsKey($Resource)) {
            throw "Unsupported resource kind '$Resource'. Supported kinds: $($map.Keys -join ', ')."
        }

        return $map[$Resource]
    }

    return $map
}
