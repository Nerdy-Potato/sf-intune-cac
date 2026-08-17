function Invoke-CaCExtendedPlan {
    <#
    .SYNOPSIS
        Applies a plan produced by New-CaCExtendedPlan to the tenant.
    .DESCRIPTION
        Mirrors the production Invoke-CaCPlan's contract (ShouldProcess-gated, AllowDelete required
        for deletions, GraphInvoker injectable for testing) but executes the per-resource-kind
        strategy described by Get-CaCExtendedResourceMap instead of a single generic PATCH+assign
        path, because these five kinds do not share one shape:

          - settingsCatalogPolicies    : create via POST, update via PUT (204).
          - endpointSecurityIntents    : create by instantiating a template; update via the
                                         dedicated updateSettings action (204), never a PATCH/PUT
                                         of the object itself.
          - conditionalAccessPolicies  : create/update via PATCH (204); update is only ever
                                         reached for changes Test-CaCConditionalAccessSafety has
                                         already approved (conditions.users unchanged).
          - assignmentFilters          : create/update via PATCH (200); never assigned.
          - proactiveRemediationScripts: create/update via PATCH (200); assigned like a normal
                                         policy afterwards.

        -GroupObjectIds maps this repository's logical group ids (config/identity/groups.json) to
        their live Graph object ids. This module does not create or reconcile groups itself - that
        remains the production engine's job - so the caller is expected to have already resolved
        (or created) every group an extended policy assigns to before calling this function.

        DECISION POINT: as with New-CaCExtendedPlan, this function is staged for review and is not
        wired into scripts/Invoke-CaC.ps1. Nothing calls it today.
    .EXAMPLE
        $plan = New-CaCExtendedPlan -Configuration $config -ManagedMarker $marker -BreakGlassGroupObjectId $id
        Invoke-CaCExtendedPlan -Plan $plan -GroupObjectIds $groupObjectIds
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        $Plan,

        [Parameter(Mandatory)]
        [hashtable] $GroupObjectIds,

        [Parameter()]
        [switch] $AllowDelete,

        [Parameter()]
        [scriptblock] $GraphInvoker = { param($Method, $Uri, $Body) Invoke-CaCGraphRequest -Method $Method -Uri $Uri -Body $Body }
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $createdObjectIds = @{}

    function Add-Result {
        param([string] $ActionName, [string] $Target, [string] $Status, [string] $Message = '')
        $null = $results.Add([pscustomobject]@{ Action = $ActionName; Target = $Target; Status = $Status; Message = $Message })
    }

    function Resolve-CaCExtendedObjectId {
        param([string] $Target, $ResourceInfo)

        if ($createdObjectIds.ContainsKey($Target)) { return $createdObjectIds[$Target] }

        $displayNameProperty = if ($ResourceInfo.ContainsKey('DisplayNameProperty')) { $ResourceInfo.DisplayNameProperty } else { 'displayName' }
        $remote = @((& $GraphInvoker 'GET' $ResourceInfo.Path $null).value | Where-Object {
                (Get-CaCProperty -InputObject $_ -Name $displayNameProperty) -eq $Target
            }) | Select-Object -First 1

        if ($remote) { return $remote.id }
        return $null
    }

    foreach ($item in @($Plan | Where-Object { $_.Kind -eq 'ExtendedPolicy' -and $_.Action -eq 'Create' })) {
        $policy = $item.Data
        $resourceInfo = Get-CaCExtendedResourceMap -Resource $policy.resource

        if (-not $PSCmdlet.ShouldProcess($item.Target, "Create $($policy.resource)")) { continue }

        try {
            $created = if ($resourceInfo.ContainsKey('CreateStrategy') -and $resourceInfo.CreateStrategy -eq 'TemplateInstantiate') {
                $templateId = Get-CaCProperty -InputObject $policy -Name 'templateId'
                if ($templateId -in $resourceInfo.UnsupportedTemplateIds) {
                    throw "templateId '$templateId' (Endpoint Detection and Response) is intentionally unsupported by this reference implementation - see DECISIONS.md."
                }
                $createUri = $resourceInfo.CreateTemplatePath -f $templateId
                & $GraphInvoker 'POST' $createUri $policy.payload
            }
            else {
                & $GraphInvoker 'POST' $resourceInfo.Path $policy.payload
            }

            $createdObjectIds[$item.Target] = $created.id
            Add-Result -ActionName 'Create' -Target $item.Target -Status 'Succeeded'
        }
        catch {
            Add-Result -ActionName 'Create' -Target $item.Target -Status 'Failed' -Message $_.Exception.Message
        }
    }

    foreach ($item in @($Plan | Where-Object { $_.Kind -eq 'ExtendedPolicy' -and $_.Action -eq 'Update' })) {
        $policy = $item.Data.Policy
        $id = $item.Data.Id
        $resourceInfo = Get-CaCExtendedResourceMap -Resource $policy.resource

        if (-not $PSCmdlet.ShouldProcess($item.Target, "Update $($policy.resource)")) { continue }

        try {
            if ($resourceInfo.ContainsKey('UpdateStrategy') -and $resourceInfo.UpdateStrategy -eq 'SettingsDelta') {
                $updateUri = $resourceInfo.UpdateSettingsPath -f $id
                $deltaBody = @{ settings = @($policy.payload[$resourceInfo.TreeProperty]) }
                $null = & $GraphInvoker 'POST' $updateUri $deltaBody
            }
            else {
                $null = & $GraphInvoker $resourceInfo.UpdateMethod "$($resourceInfo.Path)/$id" $policy.payload
            }

            Add-Result -ActionName 'Update' -Target $item.Target -Status 'Succeeded'
        }
        catch {
            Add-Result -ActionName 'Update' -Target $item.Target -Status 'Failed' -Message $_.Exception.Message
        }
    }

    foreach ($item in @($Plan | Where-Object { $_.Kind -eq 'ExtendedAssignment' -and $_.Action -eq 'Update' })) {
        $policy = $item.Data
        $resourceInfo = Get-CaCExtendedResourceMap -Resource $policy.resource
        if ($resourceInfo.AssignmentModel -ne 'StandardAssign') { continue }

        $id = Resolve-CaCExtendedObjectId -Target $item.Target -ResourceInfo $resourceInfo
        if (-not $id) {
            Add-Result -ActionName 'Assign' -Target $item.Target -Status 'Failed' -Message 'Could not resolve the object id to assign; it may have failed to create.'
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($item.Target, 'Assign')) { continue }

        try {
            $unresolvedGroups = @($policy.assignments | Where-Object { -not $GroupObjectIds.ContainsKey($_.group) })
            if ($unresolvedGroups) {
                throw "No live object id supplied via -GroupObjectIds for group(s): $(($unresolvedGroups | ForEach-Object { $_.group }) -join ', ')."
            }

            $assignmentBodyName = if ($resourceInfo.ContainsKey('AssignmentBodyName')) { $resourceInfo.AssignmentBodyName } else { 'assignments' }
            $targets = @($policy.assignments | ForEach-Object {
                    @{
                        target = @{
                            '@odata.type' = if ($_.intent -eq 'exclude') {
                                '#microsoft.graph.exclusionGroupAssignmentTarget'
                            }
                            else {
                                '#microsoft.graph.groupAssignmentTarget'
                            }
                            groupId       = $GroupObjectIds[$_.group]
                        }
                    }
                })

            $body = @{ $assignmentBodyName = $targets }
            $null = & $GraphInvoker 'POST' "$($resourceInfo.Path)/$id/$($resourceInfo.AssignAction)" $body
            Add-Result -ActionName 'Assign' -Target $item.Target -Status 'Succeeded'
        }
        catch {
            Add-Result -ActionName 'Assign' -Target $item.Target -Status 'Failed' -Message $_.Exception.Message
        }
    }

    foreach ($item in @($Plan | Where-Object { $_.Kind -eq 'ExtendedPolicy' -and $_.Action -eq 'Delete' })) {
        if (-not $AllowDelete) {
            Add-Result -ActionName 'Delete' -Target $item.Target -Status 'Skipped' -Message '-AllowDelete was not set.'
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($item.Target, 'Delete')) { continue }

        try {
            $null = & $GraphInvoker 'DELETE' "$($item.Data.ResourceInfo.Path)/$($item.Data.Id)" $null
            Add-Result -ActionName 'Delete' -Target $item.Target -Status 'Succeeded'
        }
        catch {
            Add-Result -ActionName 'Delete' -Target $item.Target -Status 'Failed' -Message $_.Exception.Message
        }
    }

    return $results.ToArray()
}
