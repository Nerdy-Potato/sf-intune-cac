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
        $null = $results.Add([pscustomobject]@{ Action = $Action; Target = $Target; Status = $Status; Message = $Message })
    }

    function Invoke-CaCAction {
        param(
            [string] $Action,
            [string] $Target,
            [scriptblock] $Operation
        )

        try {
            return [pscustomobject]@{
                Succeeded = $true
                Value     = (& $Operation)
            }
        }
        catch {
            Add-Result -Action $Action -Target $Target -Status 'Failed' -Message $_.Exception.Message
            return [pscustomobject]@{ Succeeded = $false; Value = $null }
        }
    }

    foreach ($action in @($Plan | Where-Object { $_.Action -in @('Skip', 'Prerequisite') })) {
        Add-Result -Action "$($action.Kind) $($action.Action)" -Target $action.Target -Status 'Skipped' `
            -Message ($action.Details -join '; ')
    }

    # A skipped object is an explicit safety boundary. Never discover a replacement id from the
    # live tenant: doing so could turn an unmanaged object into an implicit deployment target.
    $blockedGroupIds = @{}
    $blockedGroupNames = @{}
    $blockedAppIds = @{}
    $blockedPolicyNames = @{}
    $failedGroupIds = @{}
    $failedAppIds = @{}
    $failedPolicyNames = @{}
    foreach ($action in @($Plan | Where-Object { $_.Action -in @('Skip', 'Prerequisite') })) {
        $actionData = if ($action.PSObject.Properties['Data']) { $action.Data } else { $null }
        switch ($action.Kind) {
            'Group' {
                $blockedGroupNames[$action.Target] = $true
                if ($actionData -and $actionData.id) { $blockedGroupIds[$actionData.id] = $true }
                $group = @($Configuration.Groups | Where-Object displayName -EQ $action.Target | Select-Object -First 1)
                if ($group) { $blockedGroupIds[$group.id] = $true }
            }
            'App' {
                if ($actionData -and $actionData.id) { $blockedAppIds[$actionData.id] = $true }
                $app = @($Configuration.Apps | Where-Object { $_.payload.displayName -eq $action.Target } |
                    Select-Object -First 1)
                if ($app) { $blockedAppIds[$app.id] = $true }
            }
            'Policy' {
                $blockedPolicyNames[$action.Target] = $true
                if ($actionData -and $actionData.payload.displayName) {
                    $blockedPolicyNames[$actionData.payload.displayName] = $true
                }
            }
        }
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

    $groupObjectIds = @{}

    # Managed ids are carried by the reviewed plan. This deliberately does not query the tenant.
    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'Group' -and $_.Action -eq 'NoChange' })) {
        if ($action.Data -and $action.Data.id -and $action.ObjectId -and
            -not $blockedGroupIds.ContainsKey($action.Data.id)) {
            $groupObjectIds[$action.Data.id] = $action.ObjectId
        }
    }
    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'GroupMembership' })) {
        if ($action.Data -and $action.Data.GroupKey -and $action.Data.GroupId -and
            -not $blockedGroupIds.ContainsKey($action.Data.GroupKey)) {
            $groupObjectIds[$action.Data.GroupKey] = $action.Data.GroupId
        }
    }

    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'Group' -and $_.Action -eq 'Create' })) {
        if (-not $PSCmdlet.ShouldProcess($action.Target, 'Create security group')) { continue }

        $group = $action.Data
        $operation = Invoke-CaCAction -Action 'Create group' -Target $group.displayName -Operation {
            $created = & $GraphInvoker 'POST' 'groups' @{
                displayName     = $group.displayName
                mailNickname    = $group.mailNickname
                description     = '{0} {1}' -f $group.description, $Configuration.Tenant.managedMarker
                securityEnabled = $true
                mailEnabled     = $false
                groupTypes      = @()
            }
            if (-not $created.id) { throw 'Graph did not return an id for the created group.' }

            foreach ($member in $group.members) {
                & $GraphInvoker 'POST' "groups/$($created.id)/members/`$ref" @{
                    '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$(Resolve-UserId -Upn $member)"
                } | Out-Null
            }

            return $created
        }
        if (-not $operation.Succeeded) {
            $failedGroupIds[$group.id] = $true
            continue
        }

        $created = $operation.Value
        $groupObjectIds[$group.id] = $created.id

        Add-Result -Action 'Create group' -Target $group.displayName -Status 'Applied' -Message "$($group.members.Count) member(s)"
    }

    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'GroupMembership' })) {
        if ($blockedGroupNames.ContainsKey($action.Target) -or
            ($action.Data -and $action.Data.GroupKey -and $blockedGroupIds.ContainsKey($action.Data.GroupKey))) {
            Add-Result -Action 'Update membership' -Target $action.Target -Status 'Failed' `
                -Message 'the assignment target group was skipped by the reviewed plan'
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($action.Target, 'Reconcile group membership')) { continue }

        $membershipData = $action.Data
        $operation = Invoke-CaCAction -Action 'Update membership' -Target $action.Target -Operation {
            foreach ($member in $membershipData.Add) {
                & $GraphInvoker 'POST' "groups/$($membershipData.GroupId)/members/`$ref" @{
                    '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$(Resolve-UserId -Upn $member)"
                } | Out-Null
            }

            foreach ($member in $membershipData.Remove) {
                & $GraphInvoker 'DELETE' "groups/$($membershipData.GroupId)/members/$(Resolve-UserId -Upn $member)/`$ref" $null | Out-Null
            }
        }
        if (-not $operation.Succeeded) {
            if ($membershipData.GroupKey) {
                $failedGroupIds[$membershipData.GroupKey] = $true
                $groupObjectIds.Remove($membershipData.GroupKey)
            }
            continue
        }

        Add-Result -Action 'Update membership' -Target $action.Target -Status 'Applied' -Message ($action.Details -join '; ')
    }

    $policyIds = @{}
    $appIds = @{}

    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'App' -and $_.Action -eq 'NoChange' })) {
        if ($action.Data -and $action.Data.App -and $action.Data.App.id -and $action.Data.Id -and
            -not $blockedAppIds.ContainsKey($action.Data.App.id)) {
            $appIds[$action.Data.App.id] = $action.Data.Id
        }
    }

    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'App' -and $_.Action -in @('Create', 'Update') })) {
        $app = if ($action.Action -eq 'Create') { $action.Data } else { $action.Data.App }
        if ($app -and ($blockedAppIds.ContainsKey($app.id) -or $failedAppIds.ContainsKey($app.id))) {
            Add-Result -Action "$($action.Action) app" -Target $action.Target -Status 'Failed' `
                -Message 'the app was skipped or failed in the reviewed plan'
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($action.Target, "$($action.Action) app")) { continue }

        $appAction = $action.Action
        $operation = Invoke-CaCAction -Action "$($action.Action) app" -Target $action.Target -Operation {
            if ($appAction -eq 'Create') {
                $created = & $GraphInvoker 'POST' 'deviceAppManagement/mobileApps' $app.payload
                if (-not $created.id) { throw 'Graph did not return an id for the created app.' }
                return $created.id
            }

            & $GraphInvoker 'PATCH' "deviceAppManagement/mobileApps/$($action.Data.Id)" $app.payload | Out-Null
            return $action.Data.Id
        }
        if (-not $operation.Succeeded) {
            $failedAppIds[$app.id] = $true
            $appIds.Remove($app.id)
            continue
        }
        $appIds[$app.id] = $operation.Value

        Add-Result -Action "$($action.Action) app" -Target $action.Target -Status 'Applied' -Message ($action.Details -join '; ')
    }

    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'AppAssignment' })) {
        $app = if ($action.Data.PSObject.Properties['App']) { $action.Data.App } else { $action.Data }
        if ($app -and ($blockedAppIds.ContainsKey($app.id) -or $failedAppIds.ContainsKey($app.id))) {
            Add-Result -Action 'Assign app' -Target $action.Target -Status 'Failed' `
                -Message 'the app was skipped or failed in the reviewed plan'
            continue
        }

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
            Add-Result -Action 'Assign app' -Target $action.Target -Status 'Failed' -Message 'app id could not be resolved'
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($action.Target, 'Assign app')) { continue }

        try {
            $assignments = @($app.assignments | ForEach-Object {
                    @{
                        intent = $_.intent
                        target = Get-CaCAssignmentTarget -Assignment $_ -GroupObjectIds $groupObjectIds
                    }
                })
        }
        catch {
            if ($app -and $app.id) { $failedAppIds[$app.id] = $true }
            Add-Result -Action 'Assign app' -Target $action.Target -Status 'Failed' -Message $_.Exception.Message
            continue
        }
        if ($action.Data.PSObject.Properties['PreservedAssignments']) {
            $assignments += @($action.Data.PreservedAssignments)
        }
        $operation = Invoke-CaCAction -Action 'Assign app' -Target $action.Target -Operation {
            & $GraphInvoker 'POST' "deviceAppManagement/mobileApps/$appId/assign" @{ mobileAppAssignments = $assignments } | Out-Null
        }
        if (-not $operation.Succeeded) {
            if ($app -and $app.id) { $failedAppIds[$app.id] = $true }
            continue
        }
        Add-Result -Action 'Assign app' -Target $action.Target -Status 'Applied' -Message ($action.Details -join '; ')
    }

    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'Policy' -and $_.Action -in @('Create', 'Update') })) {
        $policy = if ($action.Action -eq 'Create') { $action.Data } else { $action.Data.Policy }
        if ($policy -and ($blockedPolicyNames.ContainsKey($policy.payload.displayName) -or
                $failedPolicyNames.ContainsKey($policy.payload.displayName))) {
            Add-Result -Action "$($action.Action) policy" -Target $action.Target -Status 'Failed' `
                -Message 'the policy was skipped or failed in the reviewed plan'
            continue
        }

        $endpoint = Get-CaCResourceMap -Resource $policy.resource

        if (-not $PSCmdlet.ShouldProcess($action.Target, "$($action.Action) policy")) { continue }
        try {
            $payload = Get-CaCPolicyPayload -Policy $policy -AppObjectIds $appIds
        }
        catch {
            if ($policy -and $policy.payload.displayName) {
                $failedPolicyNames[$policy.payload.displayName] = $true
            }
            Add-Result -Action "$($action.Action) policy" -Target $action.Target -Status 'Failed' -Message $_.Exception.Message
            continue
        }

        $policyAction = $action.Action
        $operation = Invoke-CaCAction -Action "$($action.Action) policy" -Target $action.Target -Operation {
            if ($policyAction -eq 'Create') {
                $created = & $GraphInvoker 'POST' $endpoint.Path $payload
                if (-not $created.id) { throw 'Graph did not return an id for the created policy.' }
                return $created.id
            }

            & $GraphInvoker 'PATCH' "$($endpoint.Path)/$($action.Data.Id)" $payload | Out-Null
            return $action.Data.Id
        }
        if (-not $operation.Succeeded) {
            $failedPolicyNames[$policy.payload.displayName] = $true
            continue
        }
        $policyIds[$policy.payload.displayName] = $operation.Value

        if ($endpoint.SupportsApps -and (Test-CaCHasProperty -InputObject $policy -Name 'apps')) {
            $operation = Invoke-CaCAction -Action "$($action.Action) policy target apps" -Target $action.Target -Operation {
                & $GraphInvoker 'POST' "$($endpoint.Path)/$($policyIds[$policy.payload.displayName])/targetApps" @{
                    apps = @($policy.apps)
                } | Out-Null
            }
            if (-not $operation.Succeeded) {
                $failedPolicyNames[$policy.payload.displayName] = $true
                continue
            }
        }

        Add-Result -Action "$($action.Action) policy" -Target $action.Target -Status 'Applied' -Message ($action.Details -join '; ')
    }

    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'Assignment' })) {
        $policy = if ($action.Data.PSObject.Properties['Policy']) { $action.Data.Policy } else { $action.Data }
        if ($policy -and ($blockedPolicyNames.ContainsKey($policy.payload.displayName) -or
                $failedPolicyNames.ContainsKey($policy.payload.displayName))) {
            Add-Result -Action 'Assign policy' -Target $action.Target -Status 'Failed' `
                -Message 'the policy was skipped or failed in the reviewed plan'
            continue
        }

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
            Add-Result -Action 'Assign policy' -Target $action.Target -Status 'Failed' -Message 'policy id could not be resolved'
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($action.Target, 'Assign policy')) { continue }

        try {
            $assignments = @($policy.assignments | ForEach-Object {
                    @{ target = Get-CaCAssignmentTarget -Assignment $_ -GroupObjectIds $groupObjectIds }
                })
        }
        catch {
            Add-Result -Action 'Assign policy' -Target $action.Target -Status 'Failed' -Message $_.Exception.Message
            continue
        }

        $assignmentBodyName = if ($endpoint.ContainsKey('AssignmentBodyName')) { $endpoint.AssignmentBodyName } else { 'assignments' }
        $assignmentBody = @{ $assignmentBodyName = $assignments }
        $operation = Invoke-CaCAction -Action 'Assign policy' -Target $action.Target -Operation {
            & $GraphInvoker 'POST' "$($endpoint.Path)/$policyId/$($endpoint.AssignAction)" $assignmentBody | Out-Null
        }
        if (-not $operation.Succeeded) { continue }
        Add-Result -Action 'Assign policy' -Target $action.Target -Status 'Applied' -Message ($action.Details -join '; ')
    }

    foreach ($action in @($Plan | Where-Object { $_.Action -eq 'Delete' })) {
        if (-not $AllowDelete) {
            Add-Result -Action 'Delete policy' -Target $action.Target -Status 'Skipped' -Message 'deletion requires an explicit approval (allow_delete)'
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($action.Target, 'Delete policy')) { continue }

        $deleteUri = "$($action.Data.Endpoint.Path)/$($action.Data.Id)"
        $operation = Invoke-CaCAction -Action 'Delete policy' -Target $action.Target -Operation {
            & $GraphInvoker 'DELETE' $deleteUri $null | Out-Null
        }
        if (-not $operation.Succeeded) { continue }
        Add-Result -Action 'Delete policy' -Target $action.Target -Status 'Applied'
    }

    return $results.ToArray()
}
