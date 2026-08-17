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
        param(
            [string] $Kind,
            [string] $Action,
            [string] $Target,
            [string[]] $Details = @(),
            $Data,
            [string] $ObjectId
        )

        $actions.Add([pscustomobject]@{
                Kind    = $Kind
                Action  = $Action
                Target  = $Target
                Details = $Details
                Data    = $Data
                ObjectId = $ObjectId
            })
    }

    $existingGroups = @((& $GraphInvoker 'GET' 'groups?$select=id,displayName,description,securityEnabled,mailEnabled,groupTypes' $null).value | Where-Object { $_ })
    $groupObjectIds = @{}

    foreach ($group in $Configuration.Groups) {
        $groupCandidates = @($existingGroups | Where-Object { $_.displayName -eq $group.displayName })
        $adoptionSpec = Get-CaCAdoptionSpec -Configuration $Configuration -Kind Group -Id $group.id
        if ($adoptionSpec -and $groupCandidates.Count -gt 1) {
            Add-Action -Kind 'Group' -Action 'Skip' -Target $group.displayName -Data $group -Details @(
                'one-time adoption is fail-closed: more than one group has the exact configured display name'
            )
            continue
        }

        $remote = $groupCandidates | Select-Object -First 1

        if (-not $remote) {
            Add-Action -Kind 'Group' -Action 'Create' -Target $group.displayName -Data $group -Details @(
                "members: $($group.members -join ', ')"
            )
            continue
        }

        $adopted = $false
        # Adopted groups are, by definition, allowed a foreign (non-namePrefix) display name, so
        # once the managed marker is present they are "already managed" on marker alone - exactly
        # like adopted apps (see the App loop below, which never applies NamePrefix either).
        # Requiring NamePrefix here too would make adoption never settle for any group whose real
        # display name doesn't happen to start with the configured prefix.
        $alreadyManaged = if ($adoptionSpec) {
            Test-CaCManagedObject -Object $remote -ManagedMarker $marker
        }
        else {
            Test-CaCManagedObject -Object $remote -ManagedMarker $marker -NamePrefix $prefix
        }
        if ($adoptionSpec -and -not $alreadyManaged) {
            if (Test-CaCAdoptionGroupShape -Object $remote -Spec $adoptionSpec) {
                $adopted = $true
                $groupObjectIds[$group.id] = $remote.id
                Add-Action -Kind 'Group' -Action 'Adopt' -Target $group.displayName -Data ([pscustomobject]@{
                        Group          = $group
                        Id             = $remote.id
                        ExistingDescription = Get-CaCProperty -InputObject $remote -Name 'description'
                    }) -ObjectId $remote.id -Details @(
                    'one-time adoption matched the exact configured display name and assigned security-group shape',
                    'establish the repository managed marker; preserve existing membership during adoption'
                )
            }
            else {
                Add-Action -Kind 'Group' -Action 'Skip' -Target $group.displayName -Data $group -Details @(
                    'one-time adoption is fail-closed: exact display name exists but the expected assigned security-group shape did not match'
                )
                continue
            }
        }

        if ($adopted) { continue }

        if (-not $alreadyManaged) {
            Add-Action -Kind 'Group' -Action 'Skip' -Target $group.displayName -Data $group -Details @(
                'an unmanaged group already uses this display name; refusing to take it over'
            )
            continue
        }

        $groupObjectIds[$group.id] = $remote.id

        if ($group.ContainsKey('memberType') -and $group.memberType -eq 'device') {
            Add-Action -Kind 'Group' -Action 'NoChange' -Target $group.displayName -Data $group -ObjectId $remote.id
            continue
        }

        $remoteMembers = @((& $GraphInvoker 'GET' "groups/$($remote.id)/members?`$select=id,userPrincipalName" $null).value | Where-Object { $_ })
        $remoteUpns = @($remoteMembers | ForEach-Object {
                Get-CaCProperty -InputObject $_ -Name 'userPrincipalName'
            } | Where-Object { $_ })

        $toAdd = @($group.members | Where-Object { $_ -notin $remoteUpns })
        $toRemove = @($remoteUpns | Where-Object { $_ -notin $group.members })

        $details = @()
        if ($toAdd) { $details += "add: $($toAdd -join ', ')" }
        if ($toRemove) { $details += "remove: $($toRemove -join ', ')" }

        if ($details) {
            Add-Action -Kind 'GroupMembership' -Action 'Update' -Target $group.displayName -Details $details -Data ([pscustomobject]@{
                    GroupKey = $group.id
                    GroupId  = $remote.id
                    Add      = $toAdd
                    Remove   = $toRemove
                }) -ObjectId $remote.id
        }
        else {
            Add-Action -Kind 'Group' -Action 'NoChange' -Target $group.displayName -Data $group -ObjectId $remote.id
        }
    }

    $remoteApps = @((& $GraphInvoker 'GET' 'deviceAppManagement/mobileApps' $null).value | Where-Object { $_ })
    $appObjectIds = @{}
    $appMarker = 'Managed by sf-intune-cac.'
    foreach ($app in $Configuration.Apps) {
        $remoteCandidates = @(Get-CaCRemoteAppCandidates -App $app -RemoteApps $remoteApps)
        $remote = $remoteCandidates | Select-Object -First 1
        $adoptionSpec = Get-CaCAdoptionSpec -Configuration $Configuration -Kind App -Id $app.id
        $adopted = $false
        $alreadyManaged = $remote -and (Test-CaCManagedObject -Object $remote -ManagedMarker $appMarker)

        if ($adoptionSpec -and -not $alreadyManaged) {
            if ($remoteCandidates.Count -gt 1) {
                Add-Action -Kind 'App' -Action 'Skip' -Target $app.payload.displayName -Data $app -Details @(
                    'one-time adoption is fail-closed: more than one app has the configured immutable package or bundle identity'
                )
                continue
            }

            if ($remote -and (Test-CaCAdoptionAppIdentity -Object $remote -Spec $adoptionSpec)) {
                $adopted = $true
                $appObjectIds[$app.id] = $remote.id
                Add-Action -Kind 'App' -Action 'Adopt' -Target $app.payload.displayName -Data ([pscustomobject]@{
                        App                 = $app
                        Id                  = $remote.id
                        ExistingDescription = Get-CaCProperty -InputObject $remote -Name 'description'
                    }) -ObjectId $remote.id -Details @(
                    'one-time adoption matched the exact configured display name, @odata.type, and immutable package or bundle identity',
                    'establish the repository managed marker without changing existing assignments'
                )
            }
            elseif (@($remoteApps | Where-Object {
                        (Get-CaCProperty -InputObject $_ -Name 'displayName') -eq $adoptionSpec.displayName
                    })) {
                Add-Action -Kind 'App' -Action 'Skip' -Target $app.payload.displayName -Data $app -Details @(
                    'one-time adoption is fail-closed: the configured display name exists but its immutable package or bundle identity/type did not match'
                )
                continue
            }
        }

        if ($remote -and -not $adopted -and -not $alreadyManaged) {
            Add-Action -Kind 'App' -Action 'Skip' -Target $app.payload.displayName -Data $app -Details @(
                'an unmanaged app already uses this package, bundle, or display name; refusing to take it over'
            )
            continue
        }

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
        $drift = @(Get-CaCPayloadDrift -Desired $app.payload -Actual $remote)
        if ($adopted) {
            $drift = @($drift | Where-Object { $_ -notlike 'description:*' })
        }
        if ($drift) {
            Add-Action -Kind 'App' -Action 'Update' -Target $app.payload.displayName -Details $drift -Data ([pscustomobject]@{
                    App = $app
                    Id  = $remote.id
                })
        }
        else {
            Add-Action -Kind 'App' -Action 'NoChange' -Target $app.payload.displayName -Data ([pscustomobject]@{
                    App = $app
                    Id  = $remote.id
                })
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

            if (-not (Test-CaCManagedObject -Object $remote -ManagedMarker $marker -NamePrefix $prefix)) {
                Add-Action -Kind 'Policy' -Action 'Skip' -Target $policy.payload.displayName -Data $policy -Details @(
                    'an unmanaged policy already uses this display name; refusing to take it over'
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
                Add-Action -Kind 'Policy' -Action 'NoChange' -Target $policy.payload.displayName -Data ([pscustomobject]@{
                        Policy = $policy
                        Id     = $remote.id
                    })
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
