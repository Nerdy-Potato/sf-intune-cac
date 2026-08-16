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

    foreach ($action in @($Plan | Where-Object { $_.Kind -eq 'Policy' -and $_.Action -in @('Create', 'Update') })) {
        $policy = if ($action.Action -eq 'Create') { $action.Data } else { $action.Data.Policy }
        $endpoint = Get-CaCResourceMap -Resource $policy.resource

        if (-not $PSCmdlet.ShouldProcess($action.Target, "$($action.Action) policy")) { continue }

        if ($action.Action -eq 'Create') {
            $created = & $GraphInvoker 'POST' $endpoint.Path $policy.payload
            $policyIds[$policy.payload.displayName] = $created.id
        }
        else {
            $policyIds[$policy.payload.displayName] = $action.Data.Id
            & $GraphInvoker 'PATCH' "$($endpoint.Path)/$($action.Data.Id)" $policy.payload | Out-Null
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

        & $GraphInvoker 'POST' "$($endpoint.Path)/$policyId/$($endpoint.AssignAction)" @{ assignments = $assignments } | Out-Null
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
