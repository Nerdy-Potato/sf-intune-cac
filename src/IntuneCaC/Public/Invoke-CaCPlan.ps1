function Invoke-CaCPlan {
    <#
    .SYNOPSIS
        Applies a plan produced by New-CaCPlan to the tenant.
    .DESCRIPTION
        Groups are created and reconciled first so that every assignment target exists before any
        policy is assigned. Deletions are never carried out unless -AllowDelete is passed, which the
        deployment workflow only sets when a human explicitly asks for it.
    .EXAMPLE
        $plan = New-CaCPlan -Configuration $config
        Invoke-CaCPlan -Plan $plan -Configuration $config
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        $Plan,

        [Parameter(Mandatory)]
        $Configuration,

        [Parameter()]
        [switch] $AllowDelete,

        [Parameter()]
        [scriptblock] $GraphInvoker = { param($Method, $Uri, $Body) Invoke-CaCGraphRequest -Method $Method -Uri $Uri -Body $Body }
    )

    $results = [System.Collections.Generic.List[object]]::new()

    function Add-Result {
        param([string] $Action, [string] $Target, [string] $Status, [string] $Message = '')
        $results.Add([pscustomobject]@{ Action = $Action; Target = $Target; Status = $Status; Message = $Message })
    }

    $userIds = @{}
    function Resolve-UserId {
        param([string] $Upn)
        if (-not $userIds.ContainsKey($Upn)) {
            $user = & $GraphInvoker 'GET' ("users/{0}?`$select=id" -f [uri]::EscapeDataString($Upn)) $null
            $userIds[$Upn] = $user.id
        }
        return $userIds[$Upn]
    }

    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'Group' -and $_.Action -eq 'Create' })) {
        if (-not $PSCmdlet.ShouldProcess($action.Target, 'Create security group')) { continue }

        $group = $action.Data
        $created = & $GraphInvoker 'POST' 'groups' @{
            displayName     = $group.displayName
            mailNickname    = $group.mailNickname
            description     = '{0} {1}' -f $group.description, $Configuration.Tenant.managedMarker
            securityEnabled = $true
            mailEnabled     = $false
            groupTypes      = @()
        }

        foreach ($member in $group.members) {
            & $GraphInvoker 'POST' "groups/$($created.id)/members/`$ref" @{
                '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$(Resolve-UserId -Upn $member)"
            } | Out-Null
        }

        Add-Result -Action 'Create group' -Target $group.displayName -Status 'Applied' -Message "$($group.members.Count) member(s)"
    }

    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'GroupMembership' })) {
        if (-not $PSCmdlet.ShouldProcess($action.Target, 'Reconcile group membership')) { continue }

        foreach ($member in $action.Data.Add) {
            & $GraphInvoker 'POST' "groups/$($action.Data.GroupId)/members/`$ref" @{
                '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$(Resolve-UserId -Upn $member)"
            } | Out-Null
        }

        foreach ($member in $action.Data.Remove) {
            & $GraphInvoker 'DELETE' "groups/$($action.Data.GroupId)/members/$(Resolve-UserId -Upn $member)/`$ref" $null | Out-Null
        }

        Add-Result -Action 'Update membership' -Target $action.Target -Status 'Applied' -Message ($action.Details -join '; ')
    }

    $groupObjectIds = @{}
    $existingGroups = @((& $GraphInvoker 'GET' 'groups?$select=id,displayName' $null).value | Where-Object { $_ })
    foreach ($group in $Configuration.Groups) {
        $remote = $existingGroups | Where-Object { $_.displayName -eq $group.displayName } | Select-Object -First 1
        if ($remote) { $groupObjectIds[$group.id] = $remote.id }
    }

    $policyIds = @{}
    $appIds = @{}

    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'App' -and $_.Action -in @('Create', 'Update') })) {
        $app = if ($action.Action -eq 'Create') { $action.Data } else { $action.Data.App }
        if (-not $PSCmdlet.ShouldProcess($action.Target, "$($action.Action) app")) { continue }

        if ($action.Action -eq 'Create') {
            $created = & $GraphInvoker 'POST' 'deviceAppManagement/mobileApps' $app.payload
            $appIds[$app.id] = $created.id
        }
        else {
            $appIds[$app.id] = $action.Data.Id
            & $GraphInvoker 'PATCH' "deviceAppManagement/mobileApps/$($action.Data.Id)" $app.payload | Out-Null
        }

        Add-Result -Action "$($action.Action) app" -Target $action.Target -Status 'Applied' -Message ($action.Details -join '; ')
    }

    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'AppAssignment' })) {
        $app = if ($action.Data.PSObject.Properties['App']) { $action.Data.App } else { $action.Data }
        $appId = if ($appIds.ContainsKey($app.id)) {
            $appIds[$app.id]
        }
        elseif ($action.Data.PSObject.Properties['Id']) {
            $action.Data.Id
        }
        else {
            $null
        }

        if (-not $appId) {
            Add-Result -Action 'Assign app' -Target $action.Target -Status 'Skipped' -Message 'app id could not be resolved'
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($action.Target, 'Assign app')) { continue }

        $assignments = @($app.assignments | ForEach-Object {
                @{
                    intent = $_.intent
                    target = Get-CaCAssignmentTarget -Assignment $_ -GroupObjectIds $groupObjectIds
                }
            })
        if ($action.Data.PSObject.Properties['PreservedAssignments']) {
            $assignments += @($action.Data.PreservedAssignments)
        }
        & $GraphInvoker 'POST' "deviceAppManagement/mobileApps/$appId/assign" @{ mobileAppAssignments = $assignments } | Out-Null
        Add-Result -Action 'Assign app' -Target $action.Target -Status 'Applied' -Message ($action.Details -join '; ')
    }

    $remoteApps = @((& $GraphInvoker 'GET' 'deviceAppManagement/mobileApps' $null).value | Where-Object { $_ })
    foreach ($app in $Configuration.Apps) {
        if ($appIds.ContainsKey($app.id)) { continue }
        $remote = Find-CaCRemoteApp -App $app -RemoteApps $remoteApps
        if ($remote) { $appIds[$app.id] = $remote.id }
    }

    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'Policy' -and $_.Action -in @('Create', 'Update') })) {
        $policy = if ($action.Action -eq 'Create') { $action.Data } else { $action.Data.Policy }
        $endpoint = Get-CaCResourceMap -Resource $policy.resource

        if (-not $PSCmdlet.ShouldProcess($action.Target, "$($action.Action) policy")) { continue }
        $payload = Get-CaCPolicyPayload -Policy $policy -AppObjectIds $appIds

        if ($action.Action -eq 'Create') {
            $created = & $GraphInvoker 'POST' $endpoint.Path $payload
            $policyIds[$policy.payload.displayName] = $created.id
        }
        else {
            $policyIds[$policy.payload.displayName] = $action.Data.Id
            & $GraphInvoker 'PATCH' "$($endpoint.Path)/$($action.Data.Id)" $payload | Out-Null
        }

        if ($endpoint.SupportsApps -and (Test-CaCHasProperty -InputObject $policy -Name 'apps')) {
            & $GraphInvoker 'POST' "$($endpoint.Path)/$($policyIds[$policy.payload.displayName])/targetApps" @{
                apps = @($policy.apps)
            } | Out-Null
        }

        Add-Result -Action "$($action.Action) policy" -Target $action.Target -Status 'Applied' -Message ($action.Details -join '; ')
    }

    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'Assignment' })) {
        $policy = if ($action.Data.PSObject.Properties['Policy']) { $action.Data.Policy } else { $action.Data }
        $endpoint = Get-CaCResourceMap -Resource $policy.resource

        $policyId = if ($policyIds.ContainsKey($policy.payload.displayName)) {
            $policyIds[$policy.payload.displayName]
        }
        elseif ($action.Data.PSObject.Properties['Id']) {
            $action.Data.Id
        }
        else {
            $null
        }

        if (-not $policyId) {
            Add-Result -Action 'Assign policy' -Target $action.Target -Status 'Skipped' -Message 'policy id could not be resolved'
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($action.Target, 'Assign policy')) { continue }

        $assignments = @($policy.assignments | ForEach-Object {
                @{ target = Get-CaCAssignmentTarget -Assignment $_ -GroupObjectIds $groupObjectIds }
            })

        $assignmentBodyName = if ($endpoint.ContainsKey('AssignmentBodyName')) { $endpoint.AssignmentBodyName } else { 'assignments' }
        $assignmentBody = @{ $assignmentBodyName = $assignments }
        & $GraphInvoker 'POST' "$($endpoint.Path)/$policyId/$($endpoint.AssignAction)" $assignmentBody | Out-Null
        Add-Result -Action 'Assign policy' -Target $action.Target -Status 'Applied' -Message ($action.Details -join '; ')
    }

    foreach ($action in @($Plan | Where-Object { $_.Action -eq 'Delete' })) {
        if (-not $AllowDelete) {
            Add-Result -Action 'Delete policy' -Target $action.Target -Status 'Skipped' -Message 'deletion requires an explicit approval (allow_delete)'
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($action.Target, 'Delete policy')) { continue }

        & $GraphInvoker 'DELETE' "$($action.Data.Endpoint.Path)/$($action.Data.Id)" $null | Out-Null
        Add-Result -Action 'Delete policy' -Target $action.Target -Status 'Applied'
    }

    return $results.ToArray()
}
