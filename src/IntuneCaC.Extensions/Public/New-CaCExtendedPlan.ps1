function New-CaCExtendedPlan {
    <#
    .SYNOPSIS
        Compares desired extended-kind policies with the live tenant and returns the work to do.
    .DESCRIPTION
        Read-only, mirroring the production New-CaCPlan's contract exactly (nothing here mutates
        the tenant). Matching is by display name inside the managed namespace, same as production.

        Each resource kind's diff strategy comes from Get-CaCExtendedResourceMap:
          - Tree          : structural, key-based diff (Get-CaCTreeDrift) - only when the kind's
                            TreeReadPath is known; otherwise the item is always treated as
                            'Update' (unconditional resend), same fallback the production engine
                            already uses for opaque trees it cannot safely diff.
          - Scalar        : dotted-path diff with exclusions (Get-CaCScalarDrift).
          - ScriptContent : decoded script body diff (Get-CaCScriptContentDrift) plus a Scalar
                            diff over everything else.

        Conditional Access additionally never reaches a plan action at all unless
        Test-CaCConditionalAccessSafety passes - an unsafe CA definition becomes a 'Blocked'
        action instead of a 'Create'/'Update' one.
    .EXAMPLE
        New-CaCExtendedPlan -Configuration (Get-CaCExtendedConfiguration) -ManagedMarker 'Managed by sf-intune-cac (reference implementation).' -BreakGlassGroupObjectId $id
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Configuration,

        [Parameter(Mandatory)]
        [string[]] $ManagedMarker,

        [Parameter(Mandatory)]
        [string] $BreakGlassGroupObjectId,

        [Parameter()]
        [scriptblock] $GraphInvoker = { param($Method, $Uri, $Body) Invoke-CaCGraphRequest -Method $Method -Uri $Uri -Body $Body }
    )

    $actions = [System.Collections.Generic.List[object]]::new()

    function Add-Action {
        param(
            [string] $Kind,
            [string] $Action,
            [string] $Target,
            [string[]] $Details = @(),
            $Data,
            [string] $ObjectId
        )

        $actions.Add([pscustomobject]@{
                Kind     = $Kind
                Action   = $Action
                Target   = $Target
                Details  = $Details
                Data     = $Data
                ObjectId = $ObjectId
            })
    }

    $policiesByResource = $Configuration.Policies | Group-Object -Property { $_.resource }

    foreach ($resourceGroup in $policiesByResource) {
        $resource = $resourceGroup.Name
        $resourceInfo = Get-CaCExtendedResourceMap -Resource $resource
        $displayNameProperty = if ($resourceInfo.ContainsKey('DisplayNameProperty')) { $resourceInfo.DisplayNameProperty } else { 'displayName' }

        $remoteObjects = @((& $GraphInvoker 'GET' $resourceInfo.Path $null).value | Where-Object { $_ })

        foreach ($policy in $resourceGroup.Group) {
            $displayName = [string] $policy.payload[$displayNameProperty]

            if (-not $policy.enabled) {
                Add-Action -Kind 'ExtendedPolicy' -Action 'Skip' -Target $displayName -Details @('disabled in configuration')
                continue
            }

            $remote = $remoteObjects | Where-Object { (Get-CaCProperty -InputObject $_ -Name $displayNameProperty) -eq $displayName } | Select-Object -First 1

            $safetyProblems = @()
            if ($resourceInfo.ContainsKey('RequiresBreakGlassExclusion') -and $resourceInfo.RequiresBreakGlassExclusion) {
                $allowEnabled = $policy.ContainsKey('allowEnabledState') -and $policy.allowEnabledState
                $safetyProblems = @(Test-CaCConditionalAccessSafety -Desired $policy.payload -Actual $remote -BreakGlassGroupObjectId $BreakGlassGroupObjectId -AllowEnabledState:$allowEnabled)
            }

            if ($safetyProblems) {
                Add-Action -Kind 'ExtendedPolicy' -Action 'Blocked' -Target $displayName -Details $safetyProblems -Data $policy
                continue
            }

            if (-not $remote) {
                Add-Action -Kind 'ExtendedPolicy' -Action 'Create' -Target $displayName -Data $policy -Details @("resource: $resource")

                switch ($resourceInfo.AssignmentModel) {
                    'StandardAssign' {
                        Add-Action -Kind 'ExtendedAssignment' -Action 'Update' -Target $displayName -Data $policy -Details @(
                            ($policy.assignments | ForEach-Object { "$($_.intent) $($_.group)" })
                        )
                    }
                    'EmbeddedConditionsCreateOnly' {
                        Add-Action -Kind 'ExtendedPolicy' -Action 'Info' -Target $displayName -Details @(
                            'assignment (conditions.users) is embedded in the create payload itself; there is no separate assignment step for this resource kind'
                        )
                    }
                }
                continue
            }

            if (-not (Test-CaCManagedObject -Object $remote -ManagedMarker $ManagedMarker)) {
                Add-Action -Kind 'ExtendedPolicy' -Action 'Skip' -Target $displayName -Data $policy -Details @(
                    'an unmanaged object already uses this display name; refusing to take it over'
                )
                continue
            }

            $drift = switch ($resourceInfo.DiffStrategy) {
                'Tree' {
                    if ([string]::IsNullOrWhiteSpace($resourceInfo.TreeReadPath)) {
                        @("$($resourceInfo.TreeProperty): read shape not yet confirmed for this tenant, treating as always-update (resend) - see DECISIONS.md")
                    }
                    else {
                        $desiredItems = @($policy.payload[$resourceInfo.TreeProperty])
                        $actualItems = @((& $GraphInvoker 'GET' "$($resourceInfo.Path)/$($remote.id)/$($resourceInfo.TreeReadPath)" $null).value)
                        Get-CaCTreeDrift -Desired $desiredItems -Actual $actualItems -ItemKey $resourceInfo.TreeItemKey
                    }
                }
                'ScriptContent' {
                    $scriptDrift = [System.Collections.Generic.List[string]]::new()
                    foreach ($scriptProperty in $resourceInfo.ScriptProperties) {
                        $line = Get-CaCScriptContentDrift -PropertyName $scriptProperty `
                            -DesiredBase64 $policy.payload[$scriptProperty] `
                            -ActualBase64 (Get-CaCProperty -InputObject $remote -Name $scriptProperty)
                        if ($line) { $scriptDrift.Add($line) }
                    }
                    $metadataExcludes = @($resourceInfo.ScriptProperties) + @($resourceInfo.ExcludePaths)
                    $scriptDrift.AddRange(@(Get-CaCScalarDrift -Desired $policy.payload -Actual $remote -ExcludePaths $metadataExcludes))
                    $scriptDrift.ToArray()
                }
                default {
                    Get-CaCScalarDrift -Desired $policy.payload -Actual $remote -ExcludePaths @($resourceInfo.ExcludePaths)
                }
            }

            if ($drift) {
                Add-Action -Kind 'ExtendedPolicy' -Action 'Update' -Target $displayName -Details $drift -Data ([pscustomobject]@{
                        Policy = $policy
                        Id     = $remote.id
                    })
            }
            else {
                Add-Action -Kind 'ExtendedPolicy' -Action 'NoChange' -Target $displayName -Data ([pscustomobject]@{
                        Policy = $policy
                        Id     = $remote.id
                    })
            }

            if ($resourceInfo.AssignmentModel -eq 'StandardAssign') {
                $remoteAssignments = @((& $GraphInvoker 'GET' "$($resourceInfo.Path)/$($remote.id)/assignments" $null).value | Where-Object { $_ })
                $desiredCount = @($policy.assignments).Count
                if ($remoteAssignments.Count -ne $desiredCount) {
                    Add-Action -Kind 'ExtendedAssignment' -Action 'Update' -Target $displayName -Details @(
                        "tenant has $($remoteAssignments.Count) assignment(s), configuration declares $desiredCount"
                    ) -Data ([pscustomobject]@{ Policy = $policy; Id = $remote.id })
                }
            }
        }

        $desiredNames = @($resourceGroup.Group | Where-Object { $_.enabled } | ForEach-Object { $_.payload[$displayNameProperty] })
        foreach ($remote in $remoteObjects) {
            $remoteName = Get-CaCProperty -InputObject $remote -Name $displayNameProperty
            if ($remoteName -in $desiredNames) { continue }
            if (-not (Test-CaCManagedObject -Object $remote -ManagedMarker $ManagedMarker)) { continue }

            Add-Action -Kind 'ExtendedPolicy' -Action 'Delete' -Target $remoteName -Details @(
                'exists in the tenant, is marked as managed, and is no longer defined in configuration'
            ) -Data ([pscustomobject]@{ Id = $remote.id; ResourceInfo = $resourceInfo })
        }
    }

    return $actions.ToArray()
}
