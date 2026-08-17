function Get-CaCAppAssignmentDrift {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)] [string] $RemoteId,
        [Parameter(Mandatory)] [hashtable] $GroupObjectIds,
        [Parameter(Mandatory)] [scriptblock] $GraphInvoker
    )

    $desired = [System.Collections.Generic.List[string]]::new()
    foreach ($assignment in $App.assignments) {
        $objectId = $GroupObjectIds[$assignment.group]
        if (-not $objectId) {
            return @("assignment target '$($assignment.group)' does not exist yet; it will be created first")
        }

        $desired.Add(('{0}:{1}' -f $assignment.intent, $objectId))
    }

    $remoteAssignments = @((& $GraphInvoker 'GET' "deviceAppManagement/mobileApps/$RemoteId/assignments" $null).value | Where-Object { $_ })

    $actual = @($remoteAssignments | ForEach-Object {
            $target = Get-CaCProperty -InputObject $_ -Name 'target'
            $groupId = Get-CaCProperty -InputObject $target -Name 'groupId'
            if ($groupId -notin @($App.assignments | ForEach-Object { $GroupObjectIds[$_.group] })) { return }
            '{0}:{1}' -f (Get-CaCProperty -InputObject $_ -Name 'intent'), $groupId
        } | Sort-Object)
    $desiredSorted = @($desired | Sort-Object)

    if (($desiredSorted -join '|') -eq ($actual -join '|')) { return @() }
    return @("assignments: [$($actual -join ', ')] -> [$($desiredSorted -join ', ')]")
}

function Get-CaCPreservedAppAssignments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)] [string] $RemoteId,
        [Parameter(Mandatory)] [hashtable] $GroupObjectIds,
        [Parameter(Mandatory)] [scriptblock] $GraphInvoker
    )

    $managedGroupIds = @($App.assignments | ForEach-Object { $GroupObjectIds[$_.group] } | Where-Object { $_ })
    $remoteAssignments = @((& $GraphInvoker 'GET' "deviceAppManagement/mobileApps/$RemoteId/assignments" $null).value | Where-Object { $_ })

    return @($remoteAssignments | Where-Object {
            $target = Get-CaCProperty -InputObject $_ -Name 'target'
            (Get-CaCProperty -InputObject $target -Name 'groupId') -notin $managedGroupIds
        } | ForEach-Object {
            $body = @{
                intent = Get-CaCProperty -InputObject $_ -Name 'intent'
                target = Get-CaCProperty -InputObject $_ -Name 'target'
            }
            $settings = Get-CaCProperty -InputObject $_ -Name 'settings'
            if ($settings) { $body['settings'] = $settings }
            $body
        })
}

function Find-CaCRemoteApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $RemoteApps
    )

    $matchesIdentity = switch ($App.source) {
        'managedGooglePlay' {
            $RemoteApps | Where-Object {
                (Get-CaCProperty -InputObject $_ -Name 'packageId') -eq $App.payload.packageId
            }
        }
        'iosStore' {
            $RemoteApps | Where-Object {
                (Get-CaCProperty -InputObject $_ -Name 'bundleId') -eq $App.payload.bundleId
            }
        }
        'existing' {
            $RemoteApps | Where-Object {
                (Get-CaCProperty -InputObject $_ -Name 'displayName') -eq $App.payload.displayName
            }
        }
    }

    return $matchesIdentity | Select-Object -First 1
}
