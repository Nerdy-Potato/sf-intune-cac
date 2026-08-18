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
            Path                = 'deviceManagement/deviceEnrollmentConfigurations'
            AssignAction        = 'assign'
            AssignmentBodyName  = 'enrollmentConfigurationAssignments'
            SupportsApps        = $false
            # Microsoft Graph permanently blocks app-only/service-principal WRITES (create/update/
            # delete/assign) to this resource type - by design, confirmed by Microsoft support
            # (Microsoft365DSC/Microsoft365DSC#5127). Reads are unaffected, so this repository keeps
            # planning/diffing this resource normally; Invoke-CaCPlan uses this flag to skip the
            # Graph write and report a manual portal step instead of attempting (and permanently
            # failing) the call. See .squad/decisions.md (2026-08-18: manual-apply contract).
            RequiresPortalApply = $true
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
