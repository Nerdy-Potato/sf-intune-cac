function Test-CaCExtendedConfiguration {
    <#
    .SYNOPSIS
        Validates extended policy definitions against the draft schema and the same class of
        safety rules enforced by the production Test-CaCConfiguration.
    .DESCRIPTION
        Runs entirely offline. Returns a finding per problem; any Error means the configuration
        must not be planned or applied. This intentionally re-checks the Conditional Access safety
        rail (break-glass exclusion, safe default state) at validation time as well as at apply
        time, so a bad Conditional Access definition is caught during PR review rather than only
        at the moment someone runs an apply.
    .EXAMPLE
        Test-CaCExtendedConfiguration -Configuration (Get-CaCExtendedConfiguration) -BreakGlassGroupObjectId $id
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Configuration,

        [Parameter()]
        [string] $SchemaPath = (Join-Path -Path $PSScriptRoot -ChildPath '../schemas'),

        [Parameter()]
        [string] $BreakGlassGroupObjectId = ''
    )

    $schemas = (Resolve-Path -Path $SchemaPath).Path
    $findings = [System.Collections.Generic.List[object]]::new()

    function Add-Finding {
        param([string] $Severity, [string] $Rule, [string] $Target, [string] $Message)
        $findings.Add([pscustomobject]@{ Severity = $Severity; Rule = $Rule; Target = $Target; Message = $Message })
    }

    foreach ($policy in $Configuration.Policies) {
        $file = Join-Path $Configuration.Root $policy.sourcePath
        try {
            $null = Test-Json -Json (Get-Content -Path $file -Raw) -Schema (Get-Content -Path (Join-Path $schemas 'policy.extended.schema.json') -Raw) -ErrorAction Stop
        }
        catch {
            Add-Finding -Severity 'Error' -Rule 'schema' -Target $policy.sourcePath -Message $_.Exception.Message
            continue
        }

        $target = $policy.name

        try {
            $resourceInfo = Get-CaCExtendedResourceMap -Resource $policy.resource
        }
        catch {
            Add-Finding -Severity 'Error' -Rule 'policy/resource' -Target $target -Message $_.Exception.Message
            continue
        }

        if ($resourceInfo.ContainsKey('RequiresBreakGlassExclusion') -and $resourceInfo.RequiresBreakGlassExclusion) {
            $problems = @(Test-CaCConditionalAccessSafety -Desired $policy.payload -Actual $null -BreakGlassGroupObjectId $BreakGlassGroupObjectId -AllowEnabledState:($policy.ContainsKey('allowEnabledState') -and $policy.allowEnabledState))
            foreach ($problem in $problems) {
                Add-Finding -Severity 'Error' -Rule 'safety/conditional-access' -Target $target -Message $problem
            }
        }

        if ($policy.resource -eq 'endpointSecurityIntents') {
            $templateId = Get-CaCProperty -InputObject $policy -Name 'templateId'
            if ([string]::IsNullOrWhiteSpace([string] $templateId)) {
                Add-Finding -Severity 'Error' -Rule 'policy/template-required' -Target $target -Message `
                    'endpointSecurityIntents policies must specify templateId; intents are created by instantiating a template, not by posting the object directly.'
            }
            elseif ($templateId -in $resourceInfo.UnsupportedTemplateIds) {
                Add-Finding -Severity 'Error' -Rule 'policy/unsupported-template' -Target $target -Message `
                    "templateId '$templateId' (Endpoint Detection and Response) is intentionally unsupported by this reference implementation, matching IntuneCD - see DECISIONS.md."
            }
        }
    }

    $duplicateNames = $Configuration.Policies | Group-Object -Property { $_.name } | Where-Object Count -GT 1
    foreach ($duplicate in $duplicateNames) {
        Add-Finding -Severity 'Error' -Rule 'policy/duplicate-name' -Target $duplicate.Name -Message 'More than one extended policy definition uses this name.'
    }

    return $findings.ToArray()
}
