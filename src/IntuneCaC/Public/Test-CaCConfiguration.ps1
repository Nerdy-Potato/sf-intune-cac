function Test-CaCConfiguration {
    <#
    .SYNOPSIS
        Validates the desired-state configuration against the JSON schemas and the tenant safety rules.
    .DESCRIPTION
        Runs entirely offline, so it gates every pull request before anything is allowed near the
        tenant. Returns a finding per problem; callers decide what to do with warnings, but any
        Error means the configuration must not be deployed.
    .EXAMPLE
        Test-CaCConfiguration -Configuration (Get-CaCConfiguration)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Configuration,

        [Parameter()]
        [string] $SchemaPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../../schemas')
    )

    $schemas = (Resolve-Path -Path $SchemaPath).Path
    $findings = [System.Collections.Generic.List[object]]::new()

    function Add-Finding {
        param([string] $Severity, [string] $Rule, [string] $Target, [string] $Message)
        $findings.Add([pscustomobject]@{
                Severity = $Severity
                Rule     = $Rule
                Target   = $Target
                Message  = $Message
            })
    }

    function Test-AgainstSchema {
        param([string] $File, [string] $Schema)

        if (-not (Test-Path -Path $File)) {
            Add-Finding -Severity 'Error' -Rule 'schema' -Target $File -Message 'File not found.'
            return
        }

        try {
            $null = Test-Json -Json (Get-Content -Path $File -Raw) -Schema (Get-Content -Path (Join-Path $schemas $Schema) -Raw) -ErrorAction Stop
        }
        catch {
            $relative = $File.Substring($Configuration.Root.Length).TrimStart([char]'/', [char]'\')
            Add-Finding -Severity 'Error' -Rule 'schema' -Target $relative -Message $_.Exception.Message
        }
    }

    Test-AgainstSchema -File (Join-Path $Configuration.Root 'tenant.json') -Schema 'tenant.schema.json'
    Test-AgainstSchema -File (Join-Path $Configuration.Root 'identity/users.json') -Schema 'users.schema.json'
    Test-AgainstSchema -File (Join-Path $Configuration.Root 'identity/groups.json') -Schema 'groups.schema.json'
    foreach ($appFile in @($Configuration.Apps.sourcePath | Sort-Object -Unique)) {
        Test-AgainstSchema -File (Join-Path $Configuration.Root $appFile) -Schema 'apps.schema.json'
    }

    foreach ($policy in $Configuration.Policies) {
        Test-AgainstSchema -File (Join-Path $Configuration.Root $policy.sourcePath) -Schema 'policy.schema.json'
    }

    $tenant = $Configuration.Tenant
    $groupsById = @{}
    foreach ($group in $Configuration.Groups) { $groupsById[$group.id] = $group }
    $appsById = @{}
    foreach ($app in $Configuration.Apps) { $appsById[$app.id] = $app }

    $adoption = Get-CaCProperty -InputObject $tenant -Name 'adoption'
    if ($adoption) {
        if ((Get-CaCProperty -InputObject $adoption -Name 'oneTime') -ne $true) {
            Add-Finding -Severity 'Error' -Rule 'adoption/one-time' -Target 'tenant.json' -Message `
                'The adoption section must be explicitly marked oneTime=true.'
        }

        $allowedGroupId = 'sg-autopilot-device-preparation-child'
        $allowedGroupName = 'CaC-Autopilot-DevicePreparation-Child'
        foreach ($spec in @(Get-CaCProperty -InputObject $adoption -Name 'groups' | Where-Object { $_ })) {
            $specId = Get-CaCProperty -InputObject $spec -Name 'id'
            $group = if ($groupsById.ContainsKey($specId)) { $groupsById[$specId] } else { $null }
            if ($specId -ne $allowedGroupId) {
                Add-Finding -Severity 'Error' -Rule 'adoption/group-scope' -Target ([string] $specId) -Message `
                    ("Only '{0}' may be adopted by display name." -f $allowedGroupId)
                continue
            }

            if (-not $group) {
                Add-Finding -Severity 'Error' -Rule 'adoption/group-config' -Target $specId -Message `
                    'The configured Autopilot adoption group must exist in identity/groups.json.'
                continue
            }

            if ((Get-CaCProperty -InputObject $spec -Name 'displayName') -ne $allowedGroupName -or
                $group.displayName -ne $allowedGroupName -or
                (Get-CaCProperty -InputObject $spec -Name 'securityEnabled') -ne $true -or
                (Get-CaCProperty -InputObject $spec -Name 'mailEnabled') -ne $false -or
                @(Get-CaCProperty -InputObject $spec -Name 'groupTypes').Count -ne 0) {
                Add-Finding -Severity 'Error' -Rule 'adoption/group-shape' -Target $specId -Message `
                    'Autopilot adoption requires the exact configured display name and an assigned security group (securityEnabled=true, mailEnabled=false, groupTypes=[]).'
            }
        }

        $allowedAppIds = @('android-authenticator', 'ios-authenticator')
        foreach ($spec in @(Get-CaCProperty -InputObject $adoption -Name 'apps' | Where-Object { $_ })) {
            $specId = Get-CaCProperty -InputObject $spec -Name 'id'
            if ($specId -notin $allowedAppIds) {
                Add-Finding -Severity 'Error' -Rule 'adoption/app-scope' -Target ([string] $specId) -Message `
                    ("Only the configured Microsoft Authenticator apps may be adopted: {0}." -f ($allowedAppIds -join ', '))
                continue
            }

            $app = if ($appsById.ContainsKey($specId)) { $appsById[$specId] } else { $null }
            if (-not $app) {
                Add-Finding -Severity 'Error' -Rule 'adoption/app-config' -Target $specId -Message `
                    'The configured Microsoft Authenticator adoption app must exist in the approved app catalog.'
                continue
            }

            $identity = Get-CaCProperty -InputObject $spec -Name 'identity'
            $identityKind = Get-CaCProperty -InputObject $identity -Name 'kind'
            $identityValue = Get-CaCProperty -InputObject $identity -Name 'value'
            $configuredIdentity = if ($identityKind -in @('packageId', 'bundleId')) {
                Get-CaCProperty -InputObject $app.payload -Name $identityKind
            }
            else {
                $null
            }
            if ((Get-CaCProperty -InputObject $spec -Name 'displayName') -ne 'Microsoft Authenticator' -or
                (Get-CaCProperty -InputObject $spec -Name 'displayName') -ne $app.payload.displayName -or
                (Get-CaCProperty -InputObject $spec -Name 'odataType') -ne $app.payload.'@odata.type' -or
                $identityKind -notin @('packageId', 'bundleId') -or
                $identityValue -ne $configuredIdentity) {
                Add-Finding -Severity 'Error' -Rule 'adoption/app-identity' -Target $specId -Message `
                    'Authenticator adoption requires the exact configured display name, Graph type, and existing immutable packageId or bundleId.'
            }
        }
    }

    $duplicateAppIds = $Configuration.Apps | Group-Object -Property { $_.id } | Where-Object Count -GT 1
    foreach ($duplicate in $duplicateAppIds) {
        Add-Finding -Severity 'Error' -Rule 'app/duplicate-id' -Target $duplicate.Name -Message 'More than one approved app uses this id.'
    }

    foreach ($app in $Configuration.Apps) {
        $appMarker = 'Managed by sf-intune-cac.'
        if ($app.payload.description -notlike "*$appMarker*") {
            Add-Finding -Severity 'Error' -Rule 'app/managed-marker' -Target $app.id -Message `
                ("description must contain the managed marker '{0}'." -f $appMarker)
        }

        foreach ($assignment in $app.assignments) {
            if (-not $groupsById.ContainsKey($assignment.group)) {
                Add-Finding -Severity 'Error' -Rule 'app/unknown-group' -Target $app.id -Message `
                    ("Assignment references group '{0}', which is not defined in identity/groups.json." -f $assignment.group)
                continue
            }

            if ($groupsById[$assignment.group].purpose -eq 'exclusion') {
                Add-Finding -Severity 'Error' -Rule 'safety/exclusion-group-assigned' -Target $app.id -Message `
                    ("Group '{0}' exists only as an exclusion target and must never have an app assigned to it." -f $assignment.group)
            }
        }
    }

    if (-not $tenant.primaryDomain) {
        Add-Finding -Severity 'Warning' -Rule 'tenant/primary-domain' -Target 'tenant.json' -Message `
        ("primaryDomain is not set, so productivity accounts resolve to {0}. Set it before the first apply if the family uses a vanity domain." -f $tenant.fallbackDomain)
    }

    foreach ($user in $Configuration.Users) {
        if (-not $user.ageTierConfirmed) {
            Add-Finding -Severity 'Warning' -Rule 'identity/age-tier-unconfirmed' -Target $user.id -Message `
            ("Age tier is unconfirmed, so the account sits in the most restrictive tier '{0}'. Confirm the age and move the account deliberately." -f $user.tier)
        }
    }

    $duplicateNames = $Configuration.Policies | Group-Object -Property { $_.name } | Where-Object Count -GT 1
    foreach ($duplicate in $duplicateNames) {
        Add-Finding -Severity 'Error' -Rule 'policy/duplicate-name' -Target $duplicate.Name -Message 'More than one policy definition uses this name.'
    }

    $duplicateDisplayNames = $Configuration.Policies | Group-Object -Property { $_.payload.displayName } | Where-Object Count -GT 1
    foreach ($duplicate in $duplicateDisplayNames) {
        Add-Finding -Severity 'Error' -Rule 'policy/duplicate-displayname' -Target $duplicate.Name -Message `
            'More than one policy definition uses this displayName. displayName is the identity key used to match objects in the tenant.'
    }

    foreach ($policy in $Configuration.Policies) {
        $target = $policy.name

        try {
            $null = Get-CaCResourceMap -Resource $policy.resource
        }
        catch {
            Add-Finding -Severity 'Error' -Rule 'policy/resource' -Target $target -Message $_.Exception.Message
        }

        if (Test-CaCHasProperty -InputObject $policy -Name 'targetApps') {
            foreach ($appId in $policy.targetApps) {
                if ($appId -notin $Configuration.Apps.id) {
                    Add-Finding -Severity 'Error' -Rule 'policy/unknown-target-app' -Target $target -Message `
                        ("Target app '{0}' is not defined in the approved app catalog." -f $appId)
                }
            }
        }

        if ($policy.payload.description -notlike "*$($tenant.managedMarker)*") {
            Add-Finding -Severity 'Error' -Rule 'policy/managed-marker' -Target $target -Message `
            ("description must contain the managed marker '{0}' so that the tenant makes it obvious the object is owned by this repository." -f $tenant.managedMarker)
        }

        if ($policy.payload.displayName -notlike "$($tenant.namePrefix) - *") {
            Add-Finding -Severity 'Error' -Rule 'policy/name-prefix' -Target $target -Message `
            ("displayName must start with '{0} - '. The planner only ever touches objects in that namespace, so an unprefixed policy would be orphaned on the next run." -f $tenant.namePrefix)
        }

        $includes = @($policy.assignments | Where-Object { $_.intent -eq 'include' })
        if ($includes.Count -eq 0) {
            Add-Finding -Severity 'Error' -Rule 'policy/assignment-required' -Target $target -Message 'At least one include assignment is required; a policy with only exclusions applies to nobody.'
        }

        foreach ($assignment in $policy.assignments) {
            if ($tenant.safety.forbidAllUsersAssignment -and $assignment.group -eq 'allUsers' -and $assignment.intent -eq 'include') {
                Add-Finding -Severity 'Error' -Rule 'safety/all-users' -Target $target -Message 'Assigning to All Users is forbidden: it would hit the break-glass accounts as well.'
            }

            if ($tenant.safety.forbidAllDevicesAssignment -and $assignment.group -eq 'allDevices' -and $assignment.intent -eq 'include') {
                Add-Finding -Severity 'Error' -Rule 'safety/all-devices' -Target $target -Message 'Assigning to All Devices is forbidden: scope policies through an explicit group.'
            }

            if ($assignment.group -in @('allUsers', 'allDevices')) { continue }

            if (-not $groupsById.ContainsKey($assignment.group)) {
                Add-Finding -Severity 'Error' -Rule 'policy/unknown-group' -Target $target -Message `
                ("Assignment references group '{0}', which is not defined in identity/groups.json." -f $assignment.group)
                continue
            }

            if ($assignment.intent -eq 'include' -and $groupsById[$assignment.group].purpose -eq 'exclusion') {
                Add-Finding -Severity 'Error' -Rule 'safety/exclusion-group-assigned' -Target $target -Message `
                ("Group '{0}' exists only as an exclusion target and must never have policy assigned to it." -f $assignment.group)
            }
        }
    }

    foreach ($group in $Configuration.Groups) {
        if ($group.purpose -ne 'assignment') { continue }

        $firecall = @($Configuration.Users | Where-Object { $_.accountType -eq 'firecall' -and $_.upn -in $group.members })
        foreach ($account in $firecall) {
            Add-Finding -Severity 'Error' -Rule 'safety/breakglass-in-assignment-group' -Target $group.id -Message `
            ("Break-glass account '{0}' must not be a member of an assignment group." -f $account.id)
        }
    }

    return $findings.ToArray()
}
