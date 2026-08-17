function Get-CaCExtendedResourceMap {
    <#
    .SYNOPSIS
        Maps a logical extended resource kind onto the Graph endpoints and strategies used to
        read, diff, write and assign it.
    .DESCRIPTION
        Every entry here was reverse engineered from IntuneCD's update/Intune modules (MIT
        licensed, github.com/almenscorner/IntuneCD) because none of these five kinds are simple
        "PATCH the whole object" resources the way the six kinds in the production
        Get-CaCResourceMap are. Each one needed a different create/update/assignment strategy:

          - settingsCatalogPolicies   : PUT (not PATCH) on update, settings fetched via a separate
                                        paged sub-resource and merged before diffing.
          - endpointSecurityIntents   : created by instantiating a template, then updated one
                                        setting at a time via a dedicated "updateSettings" action.
          - conditionalAccessPolicies : assignment (conditions.users) is embedded in the object
                                        itself rather than a discrete /assign call, and per
                                        IntuneCD's own source, is NOT safely updatable in place.
          - assignmentFilters         : never assigned themselves; they are referenced BY OTHER
                                        resources' assignments (assignmentFilterId/Type).
          - proactiveRemediationScripts: script bodies are base64 content that must be diffed
                                        separately from the profile metadata.

        DECISION POINT: this map is a reference only. Nothing here is wired into
        Get-CaCResourceMap.ps1, scripts/Invoke-CaC.ps1 or schemas/policy.schema.json. Promoting
        any of these kinds into production is a separate, explicit decision - see DECISIONS.md.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $Resource
    )

    $map = @{
        settingsCatalogPolicies      = @{
            Path                 = 'deviceManagement/configurationPolicies'
            CreateMethod         = 'POST'
            UpdateMethod         = 'PUT'
            UpdateExpectedStatus = 204
            TreeReadPath         = 'settings?$top=1000'
            DiffStrategy         = 'Tree'
            TreeProperty         = 'settings'
            TreeItemKey          = 'settingInstance.settingDefinitionId'
            ExcludePaths         = @('assignments')
            DisplayNameProperty  = 'name'
            AssignAction         = 'assign'
            AssignmentModel      = 'StandardAssign'
            Notes                = 'Mirrors IntuneCD update/Intune/SettingsCatalog.py. Update is PUT+204, not PATCH+200 like every other kind in this repo. Graph uses "name" as the display-name-equivalent property for this type, not "displayName".'
        }
        endpointSecurityIntents      = @{
            Path                   = 'deviceManagement/intents'
            CreateStrategy         = 'TemplateInstantiate'
            CreateTemplatePath     = 'deviceManagement/templates/{0}/createInstance'
            UpdateStrategy         = 'SettingsDelta'
            UpdateSettingsPath     = 'deviceManagement/intents/{0}/updateSettings'
            UpdateExpectedStatus   = 204
            DiffStrategy           = 'Tree'
            TreeProperty           = 'settingsDelta'
            TreeItemKey            = 'definitionId'
            TreeReadPath           = $null # DECISION POINT: the live read shape (categories -> per-category settings, vs a flattened endpoint) has not been confirmed against this tenant yet. Until it is, treat settingsDelta as always-resend (like the production engine already does for other opaque trees) rather than risk a wrong diff. See DECISIONS.md.
            UnsupportedTemplateIds = @('e44c2ca3-2f9a-400a-a113-6cc88efd773d') # Endpoint Detection and Response - see DECISIONS.md
            AssignAction           = 'assign'
            AssignmentModel        = 'StandardAssign'
            Notes                  = 'Mirrors IntuneCD update/Intune/ManagementIntents.py. Create instantiates a template; update pushes one setting object at a time.'
        }
        conditionalAccessPolicies    = @{
            Path                         = 'identity/conditionalAccess/policies'
            CreateMethod                 = 'POST'
            UpdateMethod                 = 'PATCH'
            UpdateExpectedStatus         = 204
            DiffStrategy                 = 'Scalar'
            ExcludePaths                 = @('conditions.users', 'templateId', 'grantControls.authenticationStrength.@odata.context')
            AssignmentModel              = 'EmbeddedConditionsCreateOnly'
            RequiresBreakGlassExclusion  = $true
            DefaultState                 = 'enabledForReportingButNotEnforced'
            Notes                        = 'Mirrors IntuneCD update/Intune/ConditionalAccess.py, which itself does not support updating conditions.users after create ("handle_assignment = False"). This reference implementation makes that limitation explicit and enforced rather than silent - see Test-CaCConditionalAccessSafety.ps1 and DECISIONS.md.'
        }
        assignmentFilters            = @{
            Path                 = 'deviceManagement/assignmentFilters'
            CreateMethod         = 'POST'
            UpdateMethod         = 'PATCH'
            UpdateExpectedStatus = 200
            DiffStrategy         = 'Scalar'
            ExcludePaths         = @('payloads', 'platform')
            AssignmentModel      = 'None'
            Notes                = 'Mirrors IntuneCD update/Intune/Filters.py. Filters are never assigned themselves - other resources reference them by id/type inside their own assignment target.'
        }
        proactiveRemediationScripts  = @{
            Path                    = 'deviceManagement/deviceHealthScripts'
            CreateMethod            = 'POST'
            UpdateMethod            = 'PATCH'
            UpdateExpectedStatus    = 200
            DiffStrategy            = 'ScriptContent'
            ScriptProperties        = @('detectionScriptContent', 'remediationScriptContent')
            ExcludePaths            = @()
            AssignAction            = 'assign'
            AssignmentBodyName      = 'deviceHealthScriptAssignments'
            AssignmentModel         = 'StandardAssign'
            SkipDeleteDetectionWhen = @{ Property = 'publisher'; Value = 'Microsoft' }
            Notes                   = 'Mirrors IntuneCD update/Intune/ProactiveRemediation.py. Script bodies are base64; Microsoft-published built-ins are excluded from delete-detection.'
        }
    }

    if ($PSBoundParameters.ContainsKey('Resource')) {
        if (-not $map.ContainsKey($Resource)) {
            throw "Unsupported extended resource kind '$Resource'. Supported kinds: $($map.Keys -join ', ')."
        }

        return $map[$Resource]
    }

    return $map
}
