function New-CaCPlan {
    <#
    .SYNOPSIS
        Compares the desired state in this repository with the live tenant and returns the work to do.
    .DESCRIPTION
        Read-only. Nothing here mutates the tenant, so the plan can be produced from a pull request
        using a read-only app registration and reviewed before anybody approves a deployment.

        Matching is by displayName inside the managed namespace (the tenant namePrefix). Objects
        outside that namespace are never returned as drift or as deletions, so anything created by
        hand in the portal is left strictly alone.

        Complex payload members (arrays of objects, such as compliance scheduled actions) are not
        diffed - they are sent on every create and update instead. Only scalar properties and arrays
        of primitives produce drift entries.
    .EXAMPLE
        New-CaCPlan -Configuration (Get-CaCConfiguration)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Configuration,

        [Parameter()]
        [scriptblock] $GraphInvoker = { param($Method, $Uri, $Body) Invoke-CaCGraphRequest -Method $Method -Uri $Uri -Body $Body }
    )

    $actions = [System.Collections.Generic.List[object]]::new()
    $prefix = $Configuration.Tenant.namePrefix
    $marker = $Configuration.Tenant.managedMarker

    function Add-Action {
        param([string] $Kind, [string] $Action, [string] $Target, [string[]] $Details = @(), $Data)
        $actions.Add([pscustomobject]@{
                Kind    = $Kind
                Action  = $Action
                Target  = $Target
                Details = $Details
                Data    = $Data
            })
    }

    $existingGroups = @((& $GraphInvoker 'GET' 'groups?$select=id,displayName,description' $null).value | Where-Object { $_ })
    $groupObjectIds = @{}

    foreach ($group in $Configuration.Groups) {
        $remote = $existingGroups | Where-Object { $_.displayName -eq $group.displayName } | Select-Object -First 1

        if (-not $remote) {
            Add-Action -Kind 'Group' -Action 'Create' -Target $group.displayName -Data $group -Details @(
                "members: $($group.members -join ', ')"
            )
            continue
        }

        $groupObjectIds[$group.id] = $remote.id

        $remoteMembers = @((& $GraphInvoker 'GET' "groups/$($remote.id)/members?`$select=id,userPrincipalName" $null).value | Where-Object { $_ })
        $remoteUpns = @($remoteMembers | ForEach-Object { $_.userPrincipalName } | Where-Object { $_ })

        $toAdd = @($group.members | Where-Object { $_ -notin $remoteUpns })
        $toRemove = @($remoteUpns | Where-Object { $_ -notin $group.members })

        $details = @()
        if ($toAdd) { $details += "add: $($toAdd -join ', ')" }
        if ($toRemove) { $details += "remove: $($toRemove -join ', ')" }

        if ($details) {
            Add-Action -Kind 'GroupMembership' -Action 'Update' -Target $group.displayName -Details $details -Data ([pscustomobject]@{
                    GroupId = $remote.id
                    Add     = $toAdd
                    Remove  = $toRemove
                })
        }
        else {
            Add-Action -Kind 'Group' -Action 'NoChange' -Target $group.displayName -Data $group
        }
    }

    $remoteApps = @((& $GraphInvoker 'GET' 'deviceAppManagement/mobileApps' $null).value | Where-Object { $_ })
    $appObjectIds = @{}
    foreach ($app in $Configuration.Apps) {
        $remote = Find-CaCRemoteApp -App $app -RemoteApps $remoteApps

        if (-not $remote) {
            if ($app.source -eq 'existing') {
                Add-Action -Kind 'App' -Action 'Prerequisite' -Target $app.payload.displayName -Data $app -Details @(
                    'package must be added to Intune before deployment can assign it'
                )
                continue
            }

            Add-Action -Kind 'App' -Action 'Create' -Target $app.payload.displayName -Data $app -Details @(
                "source: $($app.source)"
            )
            Add-Action -Kind 'AppAssignment' -Action 'Update' -Target $app.payload.displayName -Data $app -Details @(
                ($app.assignments | ForEach-Object { "$($_.intent) $($_.group)" })
            )
            continue
        }

        $appObjectIds[$app.id] = $remote.id
        $drift = Get-CaCPayloadDrift -Desired $app.payload -Actual $remote
        if ($drift) {
            Add-Action -Kind 'App' -Action 'Update' -Target $app.payload.displayName -Details $drift -Data ([pscustomobject]@{
                    App = $app
                    Id  = $remote.id
                })
        }
        else {
            Add-Action -Kind 'App' -Action 'NoChange' -Target $app.payload.displayName
        }

        $assignmentDrift = Get-CaCAppAssignmentDrift -App $app -RemoteId $remote.id -GroupObjectIds $groupObjectIds -GraphInvoker $GraphInvoker
        if ($assignmentDrift) {
            Add-Action -Kind 'AppAssignment' -Action 'Update' -Target $app.payload.displayName -Details $assignmentDrift -Data ([pscustomobject]@{
                    App                  = $app
                    Id                   = $remote.id
                    PreservedAssignments = @(Get-CaCPreservedAppAssignments -App $app -RemoteId $remote.id -GroupObjectIds $groupObjectIds -GraphInvoker $GraphInvoker)
                })
        }
    }

    $resourceMap = Get-CaCResourceMap
    $policiesByResource = $Configuration.Policies | Group-Object -Property { $_.resource }

    foreach ($resourceGroup in $policiesByResource) {
        $resource = $resourceGroup.Name
        $endpoint = Get-CaCResourceMap -Resource $resource
        $remoteObjects = @((& $GraphInvoker 'GET' $endpoint.Path $null).value | Where-Object { $_ })

        foreach ($policy in $resourceGroup.Group) {
            if (-not $policy.enabled) {
                Add-Action -Kind 'Policy' -Action 'Skip' -Target $policy.payload.displayName -Details @('disabled in configuration')
                continue
            }

            $remote = $remoteObjects | Where-Object { $_.displayName -eq $policy.payload.displayName } | Select-Object -First 1

            if (-not $remote) {
                Add-Action -Kind 'Policy' -Action 'Create' -Target $policy.payload.displayName -Data $policy -Details @("resource: $resource")
                Add-Action -Kind 'Assignment' -Action 'Update' -Target $policy.payload.displayName -Data $policy -Details @(
                    ($policy.assignments | ForEach-Object { "$($_.intent) $($_.group)" })
                )
                continue
            }

            $targetResolutionError = $null
            $desiredPayload = try {
                Get-CaCPolicyPayload -Policy $policy -AppObjectIds $appObjectIds
            }
            catch {
                $targetResolutionError = $_.Exception.Message
                $policy.payload
            }
            $drift = if ($targetResolutionError) {
                @("target app dependency: $targetResolutionError")
            }
            else {
                Get-CaCPayloadDrift -Desired $desiredPayload -Actual $remote
            }

            if ($drift) {
                Add-Action -Kind 'Policy' -Action 'Update' -Target $policy.payload.displayName -Details $drift -Data ([pscustomobject]@{
                        Policy = $policy
                        Id     = $remote.id
                    })
            }
            else {
                Add-Action -Kind 'Policy' -Action 'NoChange' -Target $policy.payload.displayName
            }

            $assignmentDrift = Get-CaCAssignmentDrift -Policy $policy -RemoteId $remote.id -Endpoint $endpoint -GroupObjectIds $groupObjectIds -GraphInvoker $GraphInvoker
            if ($assignmentDrift) {
                Add-Action -Kind 'Assignment' -Action 'Update' -Target $policy.payload.displayName -Details $assignmentDrift -Data ([pscustomobject]@{
                        Policy = $policy
                        Id     = $remote.id
                    })
            }
        }

        $desiredNames = @($resourceGroup.Group | Where-Object { $_.enabled } | ForEach-Object { $_.payload.displayName })
        foreach ($remote in $remoteObjects) {
            if ($remote.displayName -in $desiredNames) { continue }
            if ($remote.displayName -notlike "$prefix - *") { continue }
            if ((Get-CaCProperty -InputObject $remote -Name 'description') -notlike "*$marker*") { continue }

            Add-Action -Kind 'Policy' -Action 'Delete' -Target $remote.displayName -Details @(
                'exists in the tenant, is marked as managed by this repository, and is no longer defined in config'
            ) -Data ([pscustomobject]@{
                    Id       = $remote.id
                    Endpoint = $endpoint
                })
        }
    }

    foreach ($resource in $resourceMap.Keys) {
        if ($resource -in @($policiesByResource | ForEach-Object { $_.Name })) { continue }
        Write-Verbose "No policies defined for resource '$resource'; the tenant is not inspected for it."
    }

    return $actions.ToArray()
}
