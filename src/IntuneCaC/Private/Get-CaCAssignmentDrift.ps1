function Get-CaCAssignmentTarget {
    <#
    .SYNOPSIS
        Builds the Graph assignment target for one assignment entry in a policy definition.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Assignment,
        [Parameter(Mandatory)] [hashtable] $GroupObjectIds
    )

    switch ($Assignment.group) {
        'allUsers' { return @{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' } }
        'allDevices' { return @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }
    }

    $objectId = $GroupObjectIds[$Assignment.group]
    if (-not $objectId) {
        throw "Group '$($Assignment.group)' has no object id yet. Groups must be created before policies are assigned."
    }

    $type = if ($Assignment.intent -eq 'exclude') {
        '#microsoft.graph.exclusionGroupAssignmentTarget'
    }
    else {
        '#microsoft.graph.groupAssignmentTarget'
    }

    return @{
        '@odata.type' = $type
        groupId       = $objectId
    }
}

function Get-CaCAssignmentDrift {
    <#
    .SYNOPSIS
        Compares the assignments a policy should have with the ones it currently has in the tenant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)] [string] $RemoteId,
        [Parameter(Mandatory)] $Endpoint,
        [Parameter(Mandatory)] [hashtable] $GroupObjectIds,
        [Parameter(Mandatory)] [scriptblock] $GraphInvoker
    )

    $desired = [System.Collections.Generic.List[string]]::new()
    foreach ($assignment in $Policy.assignments) {
        $objectId = if ($assignment.group -in @('allUsers', 'allDevices')) { $assignment.group } else { $GroupObjectIds[$assignment.group] }

        if (-not $objectId) {
            return @("assignment target '$($assignment.group)' does not exist yet; it will be created first")
        }

        $desired.Add(('{0}:{1}' -f $assignment.intent, $objectId))
    }

    $remoteAssignments = @((& $GraphInvoker 'GET' "$($Endpoint.Path)/$RemoteId/assignments" $null).value | Where-Object { $_ })

    $actual = [System.Collections.Generic.List[string]]::new()
    foreach ($assignment in $remoteAssignments) {
        $target = Get-CaCProperty -InputObject $assignment -Name 'target'
        $type = Get-CaCProperty -InputObject $target -Name '@odata.type'
        $groupId = Get-CaCProperty -InputObject $target -Name 'groupId'

        $intent = if ($type -like '*exclusionGroupAssignmentTarget') { 'exclude' } else { 'include' }
        $identifier = switch -Wildcard ($type) {
            '*allLicensedUsersAssignmentTarget' { 'allUsers' }
            '*allDevicesAssignmentTarget' { 'allDevices' }
            default { $groupId }
        }

        $actual.Add(('{0}:{1}' -f $intent, $identifier))
    }

    $desiredSorted = @($desired | Sort-Object)
    $actualSorted = @($actual | Sort-Object)

    if (($desiredSorted -join '|') -eq ($actualSorted -join '|')) { return @() }

    return @("assignments: [$($actualSorted -join ', ')] -> [$($desiredSorted -join ', ')]")
}
