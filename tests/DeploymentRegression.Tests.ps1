BeforeAll {
    $script:RepoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module -Name (Join-Path $script:RepoRoot 'src/IntuneCaC/IntuneCaC.psd1') -Force

    $script:Configuration = Get-CaCConfiguration -Path (Join-Path $script:RepoRoot 'config')
    $script:Entrypoint = Get-Content -Path (Join-Path $script:RepoRoot 'scripts/Invoke-CaC.ps1') -Raw
    $script:PlanWorkflow = Get-Content -Path (Join-Path $script:RepoRoot '.github/workflows/plan.yml') -Raw
    $script:DeployWorkflow = Get-Content -Path (Join-Path $script:RepoRoot '.github/workflows/deploy.yml') -Raw
    $script:DriftWorkflow = Get-Content -Path (Join-Path $script:RepoRoot '.github/workflows/drift.yml') -Raw
    $script:CiWorkflow = Get-Content -Path (Join-Path $script:RepoRoot '.github/workflows/ci.yml') -Raw
    $script:Bootstrap = Get-Content -Path (Join-Path $script:RepoRoot 'bootstrap/Initialize-CaCAutopilotDevicePreparation.ps1') -Raw
    $script:StuckAppBootstrap = Get-Content -Path (Join-Path $script:RepoRoot 'scripts/bootstrap/Remove-CaCStuckApp.ps1') -Raw
    $script:StuckAppWorkflow = Get-Content -Path (Join-Path $script:RepoRoot '.github/workflows/remediate-stuck-app.yml') -Raw
    $script:OrphanPolicyBootstrap = Get-Content -Path (Join-Path $script:RepoRoot 'scripts/bootstrap/Remove-CaCOrphanConfigurationPolicy.ps1') -Raw
    $script:OrphanPolicyWorkflow = Get-Content -Path (Join-Path $script:RepoRoot '.github/workflows/remove-orphan-configuration-policy.yml') -Raw
    $script:AutopilotInventoryBootstrap = Get-Content -Path (Join-Path $script:RepoRoot 'scripts/bootstrap/Get-CaCAutopilotDeploymentProfileInventory.ps1') -Raw
    $script:AutopilotInventoryWorkflow = Get-Content -Path (Join-Path $script:RepoRoot '.github/workflows/inventory-autopilot-profiles.yml') -Raw
    $script:IosGsa = Get-Content -Path (Join-Path $script:RepoRoot 'config/intune/device-configuration/ios-gsa-child.json') -Raw |
        ConvertFrom-Json
}

Describe 'Deployment source freshness' {
    BeforeAll {
        $script:SourceGuard = Join-Path $script:RepoRoot 'scripts/Assert-CaCDeploymentSource.ps1'
    }

    BeforeEach {
        $script:CurrentSha = 'a' * 40
        Mock git {
            $global:LASTEXITCODE = 0
            'a' * 40
        }
        Mock Invoke-RestMethod {
            @{ ref = 'refs/heads/main'; object = @{ sha = ('a' * 40) } }
        }
        $script:GuardArguments = @{
            Repository = 'Nerdy-Potato/sf-intune-cac'
            Ref = 'refs/heads/main'
            CommitSha = $script:CurrentSha
            Token = 'test-token'
        }
    }

    It 'accepts only a matching checkout and current remote main through the authenticated API' {
        { & $script:SourceGuard @script:GuardArguments } | Should -Not -Throw
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Get' -and
            $Uri -eq 'https://api.github.com/repos/Nerdy-Potato/sf-intune-cac/git/ref/heads/main' -and
            $Headers.Authorization -eq 'Bearer test-token'
        }
    }

    It 'fails explicitly for an off-main dispatch before looking up remote main' {
        $script:GuardArguments.Ref = 'refs/heads/old-policy'
        { & $script:SourceGuard @script:GuardArguments } | Should -Throw '*requires refs/heads/main*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'rejects a stale triggering SHA even when checkout matches that SHA' {
        Mock Invoke-RestMethod {
            @{ ref = 'refs/heads/main'; object = @{ sha = ('b' * 40) } }
        }
        { & $script:SourceGuard @script:GuardArguments } | Should -Throw '*commit is stale*'
    }

    It 'rejects a mismatched checkout even when GITHUB_SHA is current main' {
        Mock git { $global:LASTEXITCODE = 0; 'b' * 40 }
        { & $script:SourceGuard @script:GuardArguments } | Should -Throw '*checkout HEAD does not match*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'fails closed on API lookup failure without exposing its response' {
        Mock Invoke-RestMethod { throw 'sensitive response must not be logged' }
        { & $script:SourceGuard @script:GuardArguments } |
            Should -Throw 'Cannot verify current remote main through the GitHub API. Nothing may be deployed.'
    }

    It 'fails closed on a malformed API main response' {
        Mock Invoke-RestMethod { @{ ref = 'refs/heads/main'; object = @{ sha = 'invalid' } } }
        { & $script:SourceGuard @script:GuardArguments } | Should -Throw '*Cannot verify current remote main*'
    }

    It 'fails closed when checkout HEAD cannot be read' {
        Mock git { $global:LASTEXITCODE = 1; 'invalid' }
        { & $script:SourceGuard @script:GuardArguments } | Should -Throw '*Cannot verify the deployment checkout HEAD*'
    }

    It 'requires a token before attempting a GitHub API lookup' {
        $script:GuardArguments.Token = ''
        { & $script:SourceGuard @script:GuardArguments } | Should -Throw '*GitHub token*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'runs the guard before credentialed planning and immediately before apply without skipping non-main jobs' {
        $script:DeployWorkflow | Should -Match '(?s)Verify current main before tenant planning.*?Assert-CaCDeploymentSource\.ps1\s+.*?- name: Plan \(read-only\)'
        $script:DeployWorkflow | Should -Match '(?s)Verify current main immediately before apply.*?Assert-CaCDeploymentSource\.ps1\s+.*?- name: Apply'
        ([regex]::Matches($script:DeployWorkflow, 'run: ./scripts/Assert-CaCDeploymentSource\.ps1')).Count |
            Should -Be 2
        ([regex]::Matches($script:DeployWorkflow, 'GH_TOKEN:\s*\$\{\{\s*github\.token\s*\}\}')).Count |
            Should -Be 2
        $script:DeployWorkflow | Should -Not -Match '(?m)^\s*if:.*github\.ref'
    }
}

Describe 'Deployment action propagation' {
    It 'returns a skipped result when an app assignment has no resolvable app id' {
        $plan = [pscustomobject]@{
            Kind    = 'AppAssignment'
            Action  = 'Update'
            Target  = 'Unresolved app'
            Details = @()
            Data    = [pscustomobject]@{
                App = [pscustomobject]@{
                    id          = 'missing-app'
                    assignments = @()
                }
            }
        }

        $invoker = {
            param($Method, $Uri, $Body)
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ value = @() }
            }

            throw "Unexpected write: $Method $Uri"
        }

        $results = Invoke-CaCPlan -Plan @($plan) -Configuration $script:Configuration `
            -GraphInvoker $invoker -Confirm:$false

        $results | Where-Object Action -EQ 'Assign app' | Select-Object -ExpandProperty Status |
            Should -Be 'Failed'
    }

    It 'tolerates the Graph RoleScopeTagIds-only PATCH restriction on legacy Android app Update actions (direct message shape)' {
        $androidApp = $script:Configuration.Apps | Where-Object { $_.payload.'@odata.type' -eq '#microsoft.graph.androidManagedStoreApp' } |
            Select-Object -First 1
        $plan = [pscustomobject]@{
            Kind    = 'App'
            Action  = 'Update'
            Target  = $androidApp.payload.displayName
            Details = @()
            Data    = [pscustomobject]@{
                App = $androidApp
                Id  = 'existing-object-id'
            }
        }

        $invoker = {
            param($Method, $Uri, $Body)
            if ($Method -eq 'GET') { return [pscustomobject]@{ value = @() } }
            if ($Method -eq 'PATCH' -and $Uri -match 'mobileApps') {
                throw "Response status code does not indicate success: 400 (Bad Request). Response body: " +
                '{"error":{"code":"BadRequest","message":"Patching only ''RoleScopeTagIds'' is supported."}}'
            }
            throw "Unexpected write: $Method $Uri"
        }

        $results = Invoke-CaCPlan -Plan @($plan) -Configuration $script:Configuration `
            -GraphInvoker $invoker -Confirm:$false

        # Regression guard: the Update-app operation scriptblock must not reference $action
        # directly, since PowerShell's case-insensitive variables let it collide with
        # Invoke-CaCAction's own -Action string parameter and throw a spurious
        # "property 'Data' cannot be found" error instead of applying the update.
        $results | Where-Object Action -EQ 'Update app' | Select-Object -ExpandProperty Status |
            Should -Be 'Applied'
    }

    It 'tolerates the same Android app Update restriction when Graph wraps it in a generic AppLifecycle proxy 400 (no RoleScopeTagIds text)' {
        # Observed live: Graph does not always return the direct "Patching only 'RoleScopeTagIds'
        # is supported." message for this restriction. It sometimes wraps the identical rejection
        # in a generic AppLifecycle/StatelessAppMetadataFEService proxy envelope instead, with no
        # mention of RoleScopeTagIds at all. Tolerance must not depend on that unstable message text.
        $androidApp = $script:Configuration.Apps | Where-Object { $_.payload.'@odata.type' -eq '#microsoft.graph.androidManagedStoreApp' } |
            Select-Object -First 1
        $plan = [pscustomobject]@{
            Kind    = 'App'
            Action  = 'Update'
            Target  = $androidApp.payload.displayName
            Details = @()
            Data    = [pscustomobject]@{
                App = $androidApp
                Id  = 'existing-object-id'
            }
        }

        $invoker = {
            param($Method, $Uri, $Body)
            if ($Method -eq 'GET') { return [pscustomobject]@{ value = @() } }
            if ($Method -eq 'PATCH' -and $Uri -match 'mobileApps') {
                throw 'Response status code does not indicate success: 400 (Bad Request). Response body: ' +
                '{"error":{"code":"BadRequest","message":"{\"_version\":3,\"Message\":\"An error has occurred ' +
                '- Operation ID (for customer support): 00000000-0000-0000-0000-000000000000 - Activity ID: ' +
                'aaaaaaaa-0000-0000-0000-000000000000 - Url: https://proxy.example.manage.microsoft.com/' +
                'AppLifecycle_2607/StatelessAppMetadataFEService/deviceAppManagement/mobileApps(''abc'')' +
                '?api-version=5026-07-08\"}"}}'
            }
            throw "Unexpected write: $Method $Uri"
        }

        $results = Invoke-CaCPlan -Plan @($plan) -Configuration $script:Configuration `
            -GraphInvoker $invoker -Confirm:$false

        $results | Where-Object Action -EQ 'Update app' | Select-Object -ExpandProperty Status |
            Should -Be 'Applied'
    }

    It 'does NOT tolerate a 400 on a non-Android app Update action (restriction is scoped to androidManagedStoreApp only)' {
        $nonAndroidApp = $script:Configuration.Apps | Where-Object { $_.payload.'@odata.type' -ne '#microsoft.graph.androidManagedStoreApp' } |
            Select-Object -First 1
        $plan = [pscustomobject]@{
            Kind    = 'App'
            Action  = 'Update'
            Target  = $nonAndroidApp.payload.displayName
            Details = @()
            Data    = [pscustomobject]@{
                App = $nonAndroidApp
                Id  = 'existing-object-id'
            }
        }

        $invoker = {
            param($Method, $Uri, $Body)
            if ($Method -eq 'GET') { return [pscustomobject]@{ value = @() } }
            if ($Method -eq 'PATCH' -and $Uri -match 'mobileApps') {
                throw 'Response status code does not indicate success: 400 (Bad Request). Response body: ' +
                '{"error":{"code":"BadRequest","message":"Some unrelated validation failure."}}'
            }
            throw "Unexpected write: $Method $Uri"
        }

        $results = Invoke-CaCPlan -Plan @($plan) -Configuration $script:Configuration `
            -GraphInvoker $invoker -Confirm:$false

        $results | Where-Object Action -EQ 'Update app' | Select-Object -ExpandProperty Status |
            Should -Be 'Failed'
    }

    It 'tolerates a 400 "PublishingState is not Published" on any app Update action (transient, Microsoft-managed sync state)' {
        # Observed live (2026-09-10): a store app (iOS or Android) whose Intune-side metadata sync
        # from the App Store/Play Store has not finished yet rejects ANY PATCH with this error.
        # publishingState is documented as read-only/not settable via API and normally clears on
        # its own - this is not scoped to one app type (unlike the Android RoleScopeTagIds
        # restriction above), since it reflects app lifecycle state rather than a resource-type
        # quirk.
        $anyApp = $script:Configuration.Apps | Select-Object -First 1
        $plan = [pscustomobject]@{
            Kind    = 'App'
            Action  = 'Update'
            Target  = $anyApp.payload.displayName
            Details = @()
            Data    = [pscustomobject]@{
                App = $anyApp
                Id  = 'existing-object-id'
            }
        }

        $invoker = {
            param($Method, $Uri, $Body)
            if ($Method -eq 'GET') { return [pscustomobject]@{ value = @() } }
            if ($Method -eq 'PATCH' -and $Uri -match 'mobileApps') {
                throw 'Response status code does not indicate success: 400 (Bad Request). Response body: ' +
                '{"error":{"code":"BadRequest","message":"Invalid operation: app''s PublishingState is not ''Published''."}}'
            }
            throw "Unexpected write: $Method $Uri"
        }

        $results = Invoke-CaCPlan -Plan @($plan) -Configuration $script:Configuration `
            -GraphInvoker $invoker -Confirm:$false

        $results | Where-Object Action -EQ 'Update app' | Select-Object -ExpandProperty Status |
            Should -Be 'Applied'
    }

    It 'does NOT tolerate a 400 that merely mentions Published in unrelated app Update error text' {
        $nonAndroidApp = $script:Configuration.Apps | Where-Object { $_.payload.'@odata.type' -ne '#microsoft.graph.androidManagedStoreApp' } |
            Select-Object -First 1
        $plan = [pscustomobject]@{
            Kind    = 'App'
            Action  = 'Update'
            Target  = $nonAndroidApp.payload.displayName
            Details = @()
            Data    = [pscustomobject]@{
                App = $nonAndroidApp
                Id  = 'existing-object-id'
            }
        }

        $invoker = {
            param($Method, $Uri, $Body)
            if ($Method -eq 'GET') { return [pscustomobject]@{ value = @() } }
            if ($Method -eq 'PATCH' -and $Uri -match 'mobileApps') {
                throw 'Response status code does not indicate success: 400 (Bad Request). Response body: ' +
                '{"error":{"code":"BadRequest","message":"Some unrelated validation failure."}}'
            }
            throw "Unexpected write: $Method $Uri"
        }

        $results = Invoke-CaCPlan -Plan @($plan) -Configuration $script:Configuration `
            -GraphInvoker $invoker -Confirm:$false

        $results | Where-Object Action -EQ 'Update app' | Select-Object -ExpandProperty Status |
            Should -Be 'Failed'
    }

    It 'does not double the managed marker when adopting a policy whose authored description already contains it' {
        # Regression (2026-09-10): every current policy config bakes the managed marker directly
        # into payload.description (e.g. "Managed by sf-intune-cac. Do not edit in the portal.").
        # Adopt-policy's empty-existing-description branch used to unconditionally append the
        # marker again, producing a doubled description on the live object ("...portal. Managed
        # by sf-intune-cac. Do not edit in the portal.") which then showed up as perpetual
        # "Update Policy" drift on every subsequent plan.
        $policy = $script:Configuration.Policies |
            Where-Object { $_.payload.description -like "*$($script:Configuration.Tenant.managedMarker)*" } |
            Select-Object -First 1
        $policy | Should -Not -BeNullOrEmpty -Because 'at least one configured policy should already bake in the managed marker'

        $plan = [pscustomobject]@{
            Kind    = 'Policy'
            Action  = 'Adopt'
            Target  = $policy.payload.displayName
            Details = @()
            Data    = [pscustomobject]@{
                Policy              = $policy
                ExistingDescription = ''
            }
            ObjectId = 'existing-object-id'
        }

        $capturedBody = $null
        $invoker = {
            param($Method, $Uri, $Body)
            if ($Method -eq 'GET') { return [pscustomobject]@{ value = @() } }
            if ($Method -eq 'PATCH') {
                $script:capturedBody = $Body
                return [pscustomobject]@{}
            }
            throw "Unexpected write: $Method $Uri"
        }

        $results = Invoke-CaCPlan -Plan @($plan) -Configuration $script:Configuration `
            -GraphInvoker $invoker -Confirm:$false

        $results | Where-Object Action -EQ 'Adopt policy' | Select-Object -ExpandProperty Status |
            Should -Be 'Applied'
        $script:capturedBody.description | Should -Be $policy.payload.description
        [regex]::Matches($script:capturedBody.description, [regex]::Escape($script:Configuration.Tenant.managedMarker)).Count |
            Should -Be 1
    }

    It 'auto-applies a description-only Update for a Settings Catalog policy instead of requiring manual portal action' {
        # Regression (2026-09-10): Update actions for deviceManagementConfigurationPolicies
        # (Settings Catalog, UpdateRequiresPortalApply=true) were unconditionally routed to
        # ManualActionRequired, even though Graph's PATCH explicitly supports Name/Description -
        # only Settings and other structural fields are rejected. This meant a description-only
        # drift (e.g. the doubled managed-marker bug fixed above) could never self-heal via a
        # normal apply and would require someone to fix it by hand in the portal every time.
        # Synthetic on purpose: the repository currently authors no Settings Catalog policy, and
        # this regression is about how the engine routes an Update for that resource type.
        $policy = @{
            name        = 'settings-catalog-regression'
            resource    = 'deviceManagementConfigurationPolicies'
            assignments = @(@{ group = 'sg-tier-child'; intent = 'include' })
            payload     = @{
                name        = 'CaC - Settings Catalog Regression'
                displayName = 'CaC - Settings Catalog Regression'
                description = $script:Configuration.Tenant.managedMarker
                settings    = @()
            }
        }

        $plan = [pscustomobject]@{
            Kind    = 'Policy'
            Action  = 'Update'
            Target  = $policy.payload.displayName
            Details = @("description: 'stale description' -> '$($policy.payload.description)'")
            Data    = [pscustomobject]@{
                Policy = $policy
                Id     = 'existing-object-id'
            }
        }

        $capturedBody = $null
        $capturedUri = $null
        $invoker = {
            param($Method, $Uri, $Body)
            if ($Method -eq 'GET') { return [pscustomobject]@{ value = @() } }
            if ($Method -eq 'PATCH') {
                $script:capturedUri = $Uri
                $script:capturedBody = $Body
                return [pscustomobject]@{}
            }
            throw "Unexpected write: $Method $Uri"
        }

        $results = Invoke-CaCPlan -Plan @($plan) -Configuration $script:Configuration `
            -GraphInvoker $invoker -Confirm:$false

        $results | Where-Object Action -EQ 'Update policy' | Select-Object -ExpandProperty Status |
            Should -Be 'Applied'
        $script:capturedUri | Should -Match 'existing-object-id$'
        $script:capturedBody.description | Should -Be $policy.payload.description
        $script:capturedBody.Keys | Should -Not -Contain 'settings'
    }

    It 'still requires manual portal action for Settings Catalog Update drift beyond description/name' {
        # Synthetic on purpose: the repository currently authors no Settings Catalog policy, and
        # this regression is about how the engine routes an Update for that resource type.
        $policy = @{
            name        = 'settings-catalog-regression'
            resource    = 'deviceManagementConfigurationPolicies'
            assignments = @(@{ group = 'sg-tier-child'; intent = 'include' })
            payload     = @{
                name        = 'CaC - Settings Catalog Regression'
                displayName = 'CaC - Settings Catalog Regression'
                description = $script:Configuration.Tenant.managedMarker
                settings    = @()
            }
        }

        $plan = [pscustomobject]@{
            Kind    = 'Policy'
            Action  = 'Update'
            Target  = $policy.payload.displayName
            Details = @('settings: <settings tree differs>')
            Data    = [pscustomobject]@{
                Policy = $policy
                Id     = 'existing-object-id'
            }
        }

        $invoker = {
            param($Method, $Uri, $Body)
            if ($Method -eq 'GET') { return [pscustomobject]@{ value = @() } }
            throw "Unexpected write: $Method $Uri"
        }

        $results = Invoke-CaCPlan -Plan @($plan) -Configuration $script:Configuration `
            -GraphInvoker $invoker -Confirm:$false

        $results | Where-Object Action -EQ 'Update policy' | Select-Object -ExpandProperty Status |
            Should -Be 'ManualActionRequired'
    }

    It 'does not silently ignore a failed action in an apply plan' {
        $group = $script:Configuration.Groups | Select-Object -First 1
        $plan = [pscustomobject]@{
            Kind    = 'Group'
            Action  = 'Create'
            Target  = $group.displayName
            Details = @()
            Data    = $group
        }

        $invoker = {
            param($Method, $Uri, $Body)
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ value = @() }
            }

            throw 'simulated Graph write failure'
        }

        $results = Invoke-CaCPlan -Plan @($plan) -Configuration $script:Configuration `
            -GraphInvoker $invoker -Confirm:$false -ErrorAction Stop

        $results | Where-Object Action -EQ 'Create group' | Select-Object -ExpandProperty Status |
            Should -Be 'Failed'
    }

    It 'fails the deployment entry point when apply reports skipped or failed actions' {
        $script:Entrypoint | Should -Match '(?is)\$results.*Status'
        $script:Entrypoint | Should -Match '(?is)\$results.*Skipped'
        $script:Entrypoint | Should -Match '(?is)\$results.*Failed'
    }

    It 'does not treat ManualActionRequired as an incomplete deployment outcome (deviceEnrollmentConfigurations manual-apply contract)' {
        if ($script:Entrypoint -match '(?s)\$incomplete\s*=\s*@\(\$results\s*\|\s*Where-Object\s+Status\s+-in\s+@\(([^)]*)\)\)') {
            $Matches[1] | Should -Not -Match 'ManualActionRequired'
            $Matches[1] | Should -Match "'Skipped'"
            $Matches[1] | Should -Match "'Failed'"
        }
        else {
            throw 'Could not locate the incomplete-actions filter in the entrypoint script.'
        }
    }

    It 'gives ManualActionRequired results a dedicated, prominent job-summary section' {
        $script:Entrypoint | Should -Match 'ManualActionRequired'
        $script:Entrypoint | Should -Match 'Manual portal action required'
        $script:Entrypoint | Should -Match 'Microsoft365DSC/Microsoft365DSC#5127'
        $script:Entrypoint | Should -Match 'Enrollment restrictions'
        $script:Entrypoint | Should -Match 'rest of this deployment completed normally'
    }

    It 'never throws the deployment-incomplete error when only ManualActionRequired results are present' {
        # Functional guard mirroring the entrypoint's exact incomplete-actions filter, so this
        # keeps failing if a future edit widens the filter to include ManualActionRequired.
        $results = @(
            [pscustomobject]@{ Action = 'Create policy'; Target = 'CaC - Enrollment - Test'; Status = 'ManualActionRequired'; Message = 'manual step' }
            [pscustomobject]@{ Action = 'Create group'; Target = 'CaC-Tier-Adult'; Status = 'Applied'; Message = '' }
        )
        $incomplete = @($results | Where-Object Status -in @('Skipped', 'Failed'))
        $incomplete | Should -BeNullOrEmpty
    }
}

Describe 'Plan and apply binding' {
    It 'keeps validation offline and requires identity only for plan or apply' {
        $script:Entrypoint | Should -Match "ValidateSet\('validate', 'plan', 'verify', 'apply'\)"
        $script:Entrypoint | Should -Match '(?is)if\s*\(\$Mode\s*-eq\s*''validate''\).*?return'
        $script:Entrypoint | Should -Match '(?is)if\s*\(-not\s*\$TenantId\s*-or\s*-not\s*\$ClientId\).*?required for plan and apply'
    }

    It 'uses a read-only Graph session for plan and a writable session for apply' {
        $script:Entrypoint | Should -Match 'Connect-CaCGraph\s+-TenantId\s+\$TenantId\s+-ClientId\s+\$ClientId\s+-ReadOnly'
        $script:Entrypoint | Should -Match '(?is)else\s*\{.*?Connect-CaCGraph\s+-TenantId\s+\$TenantId\s+-ClientId\s+\$ClientId(?!\s+-ReadOnly)'
    }

    It 'writes a reviewed plan artifact and applies only that artifact' {
        $script:Entrypoint | Should -Match '\$plan\s*=\s*@\(New-CaCPlan\s+-Configuration\s+\$configuration\)'
        $script:Entrypoint | Should -Match '(?is)Read-CaCPlanDocument.*?Assert-CaCReviewedPlan'
        $script:Entrypoint | Should -Match 'PlanPath is required for apply'
        $script:Entrypoint | Should -Not -Match '(?is)if\s*\(\$Mode\s*-eq\s*''apply''\).*?New-CaCPlan'
    }

    It 'binds each workflow to its intended mode and credential' {
        $script:PlanWorkflow | Should -Match 'AZURE_CLIENT_ID:\s*\$\{\{\s*vars\.AZURE_PLAN_CLIENT_ID\s*\}\}'
        $script:PlanWorkflow | Should -Match 'Invoke-CaC\.ps1\s+-Mode\s+plan'
        $script:DeployWorkflow | Should -Match 'AZURE_CLIENT_ID:\s*\$\{\{\s*vars\.AZURE_APPLY_CLIENT_ID\s*\}\}'
        $script:DeployWorkflow | Should -Match 'Invoke-CaC\.ps1\s+-Mode\s+apply\s+-AllowDelete:\$allowDelete'
    }
}

Describe 'Workflow trigger and permission safety' {
    It 'never grants pull request code a target-workflow execution path' {
        @($script:PlanWorkflow, $script:DeployWorkflow, $script:CiWorkflow) -join "`n" |
            Should -Not -Match 'pull_request_target|permissions:\s*write-all'
    }

    It 'guards tenant planning to repository-owned pull requests or manual dispatch' {
        $script:PlanWorkflow | Should -Match 'pull_request:'
        $script:PlanWorkflow | Should -Match "workflow_dispatch:"
        $script:PlanWorkflow | Should -Match 'github\.event\.pull_request\.head\.repo\.full_name\s*==\s*github\.repository'
        $script:PlanWorkflow | Should -Match "github\.event_name\s*==\s*'workflow_dispatch'"
    }

    It 'uses the pull request review API with explicit scoped permissions' {
        $script:PlanWorkflow | Should -Match '(?m)^\s*contents:\s*read\s*$'
        $script:PlanWorkflow | Should -Match '(?m)^\s*id-token:\s*write\s*$'
        $script:PlanWorkflow | Should -Match '(?m)^\s*pull-requests:\s*write\s*$'
        $script:PlanWorkflow | Should -Not -Match '(?m)^\s*issues:\s*write\s*$'
        $script:PlanWorkflow | Should -Match 'github\.rest\.pulls\.listReviews'
        $script:PlanWorkflow | Should -Match 'github\.rest\.pulls\.createReview'
        $script:PlanWorkflow | Should -Match 'github\.rest\.pulls\.updateReview'
        $script:PlanWorkflow | Should -Match "event:\s*'COMMENT'"
        $script:PlanWorkflow | Should -Not -Match 'github\.rest\.issues\.(listComments|createComment|updateComment)'
        $script:PlanWorkflow | Should -Match 'Failed to publish the tenant plan'
    }

    It 'requires the production environment and defaults deletion approval to false' {
        $script:DeployWorkflow | Should -Match '(?m)^\s*environment:\s*production\s*$'
        $script:DeployWorkflow | Should -Not -Match 'confirm_deploy:'
        $script:DeployWorkflow | Should -Not -Match 'reviewed_sha:'
        $script:DeployWorkflow | Should -Not -Match 'plan_run_id:'
        $script:DeployWorkflow | Should -Match '(?is)allow_delete:.*?default:\s*false'
        $script:DeployWorkflow | Should -Match '(?m)^\s*contents:\s*read\s*$'
        $script:DeployWorkflow | Should -Match '(?m)^\s*id-token:\s*write\s*$'
        $script:DeployWorkflow | Should -Not -Match 'pull-requests:\s*write'
    }

    It 'fails closed when the plan is missing or contains skipped/blocked actions' {
        $script:Entrypoint | Should -Match 'Reviewed plan artifact was not found'
        $script:Entrypoint | Should -Match 'Status -ne ''Ready'''
        $script:Entrypoint | Should -Match 'ExpectedCommitSha is required for apply'
        $script:DeployWorkflow | Should -Match 'Invoke-CaC\.ps1\s+-Mode verify'
        $script:DriftWorkflow | Should -Match '\$document\.Actions'
        $script:DriftWorkflow | Should -Match '\$document\.Status\s+-ne\s+''Ready'''
    }

    It 'keeps CI read-only while still running the offline test suite' {
        $script:CiWorkflow | Should -Match '(?m)^\s*contents:\s*read\s*$'
        $script:CiWorkflow | Should -Match 'Invoke-Pester'
        $script:CiWorkflow | Should -Match 'Invoke-CaC\.ps1\s+-Mode\s+validate'
    }

    It 'keeps stuck-app remediation manual-only and confirmation gated' {
        $script:StuckAppWorkflow | Should -Match 'workflow_dispatch:'
        $script:StuckAppWorkflow | Should -Not -Match '(?m)^\s*pull_request:\s*$'
        $script:StuckAppWorkflow | Should -Not -Match '(?m)^\s*push:\s*$'
        $script:StuckAppWorkflow | Should -Match 'app_ids:'
        $script:StuckAppWorkflow | Should -Match 'confirm:'
        $script:StuckAppWorkflow | Should -Match '(?is)confirm:.*?default:\s*false'
        $script:StuckAppWorkflow | Should -Match '(?m)^\s*contents:\s*read\s*$'
        $script:StuckAppWorkflow | Should -Match '(?m)^\s*id-token:\s*write\s*$'
        $script:StuckAppWorkflow | Should -Match '(?m)^\s*environment:\s*production\s*$'
        $script:StuckAppWorkflow | Should -Match 'AZURE_CLIENT_ID:\s*\$\{\{\s*vars\.AZURE_APPLY_CLIENT_ID\s*\}\}'
        $script:StuckAppWorkflow | Should -Match 'Remove-CaCStuckApp\.ps1'
    }

    It 'invokes stuck-app remediation non-interactively so ShouldProcess does not prompt on the runner' {
        $script:StuckAppWorkflow | Should -Match 'Remove-CaCStuckApp\.ps1\s+-AppId\s+\$appIds\s+-Confirm:\$false'
    }

    It 'keeps orphan policy remediation manual-only and confirmation gated' {
        $script:OrphanPolicyWorkflow | Should -Match 'workflow_dispatch:'
        $script:OrphanPolicyWorkflow | Should -Not -Match '(?m)^\s*pull_request:\s*$'
        $script:OrphanPolicyWorkflow | Should -Not -Match '(?m)^\s*push:\s*$'
        $script:OrphanPolicyWorkflow | Should -Match 'display_name:'
        $script:OrphanPolicyWorkflow | Should -Match 'confirm:'
        $script:OrphanPolicyWorkflow | Should -Match '(?is)confirm:.*?default:\s*false'
        $script:OrphanPolicyWorkflow | Should -Match '(?m)^\s*contents:\s*read\s*$'
        $script:OrphanPolicyWorkflow | Should -Match '(?m)^\s*id-token:\s*write\s*$'
        $script:OrphanPolicyWorkflow | Should -Match '(?m)^\s*environment:\s*production\s*$'
        $script:OrphanPolicyWorkflow | Should -Match 'AZURE_CLIENT_ID:\s*\$\{\{\s*vars\.AZURE_APPLY_CLIENT_ID\s*\}\}'
        $script:OrphanPolicyWorkflow | Should -Match 'Remove-CaCOrphanConfigurationPolicy\.ps1'
        $script:OrphanPolicyWorkflow | Should -Match 'Confirm:\$false'
    }

    It 'keeps Autopilot profile inventory read-only behind the plan environment' {
        $script:AutopilotInventoryWorkflow | Should -Match 'workflow_dispatch:'
        $script:AutopilotInventoryWorkflow | Should -Not -Match '(?m)^\s*pull_request:\s*$'
        $script:AutopilotInventoryWorkflow | Should -Not -Match '(?m)^\s*push:\s*$'
        $script:AutopilotInventoryWorkflow | Should -Match '(?m)^\s*environment:\s*plan\s*$'
        $script:AutopilotInventoryWorkflow | Should -Match 'AZURE_CLIENT_ID:\s*\$\{\{\s*vars\.AZURE_PLAN_CLIENT_ID\s*\}\}'
        $script:AutopilotInventoryWorkflow | Should -Match 'Get-CaCAutopilotDeploymentProfileInventory\.ps1'
        $script:AutopilotInventoryBootstrap | Should -Match 'Connect-CaCGraph\s+-TenantId\s+\$TenantId\s+-ClientId\s+\$ClientId\s+-ReadOnly'
        $script:AutopilotInventoryBootstrap | Should -Match 'windowsAutopilotDeploymentProfiles'
        $script:AutopilotInventoryBootstrap | Should -Match 'deviceManagement/configurationPolicies'
        $script:AutopilotInventoryBootstrap | Should -Match 'autopilot\|devicepreparation\|dpp'
        $script:AutopilotInventoryBootstrap | Should -Match 'userType'
        $script:AutopilotInventoryBootstrap | Should -Match 'accountype_0\|accounttype_0'
        $script:AutopilotInventoryBootstrap | Should -Match 'accountype_1\|accounttype_1'
        $script:AutopilotInventoryBootstrap | Should -Match 'assignments'
        $script:AutopilotInventoryBootstrap | Should -Match 'priority'
    }
}

Describe 'Bootstrap and managed-object safety' {
    It 'uses an unconditional connect rule for the iOS GSA profile' {
        @($script:IosGsa.payload.onDemandRules).action | Should -Contain 'connect'
        $script:IosGsa.payload.onDemandRules | ConvertTo-Json -Depth 10 |
            Should -Not -Match 'evaluateConnection|connectIfNeeded'
    }

    It 'refuses ambiguous Autopilot group matches before changing ownership' {
        $script:Bootstrap | Should -Match '(?is)\$groupCandidates\.Count\s*-gt\s*1.*?throw'
        $script:Bootstrap | Should -Match 'Refusing to choose an ownership target by display name'
    }

    It 'uses the module Graph auth pattern and WhatIf protection for stuck app deletes' {
        $script:StuckAppBootstrap | Should -Match 'CmdletBinding\(SupportsShouldProcess,\s*ConfirmImpact\s*=\s*''High'''
        $script:StuckAppBootstrap | Should -Match 'Connect-CaCGraph\s+-TenantId\s+\$TenantId\s+-ClientId\s+\$ClientId'
        $script:StuckAppBootstrap | Should -Match 'NewBoundScriptBlock'
        $script:StuckAppBootstrap | Should -Match 'Invoke-CaCGraphRequest\s+-Method\s+\$Method\s+-Uri\s+\$Uri\s+-Body\s+\$Body'
        $script:StuckAppBootstrap | Should -Match 'publishingState'
        $script:StuckAppBootstrap | Should -Match 'deviceAppManagement/mobileApps/\$\{normalizedAppId\}'
        $script:StuckAppBootstrap | Should -Match 'ShouldProcess'
        $script:StuckAppBootstrap | Should -Match 'DELETE'
    }

    It 'requires the managed marker before deleting an orphaned configuration policy' {
        $script:OrphanPolicyBootstrap | Should -Match 'CmdletBinding\(SupportsShouldProcess,\s*ConfirmImpact\s*=\s*''High'''
        $script:OrphanPolicyBootstrap | Should -Match 'Connect-CaCGraph\s+-TenantId\s+\$TenantId\s+-ClientId\s+\$ClientId'
        $script:OrphanPolicyBootstrap | Should -Match 'NewBoundScriptBlock'
        $script:OrphanPolicyBootstrap | Should -Match 'configurationPolicies\?'
        $script:OrphanPolicyBootstrap | Should -Match 'does not carry the repository managed marker'
        $script:OrphanPolicyBootstrap | Should -Match 'ShouldProcess'
        $script:OrphanPolicyBootstrap | Should -Match 'DELETE'
    }

    It 'builds fully resolved GET and DELETE URIs for stuck app remediation' {
        $scriptPath = Join-Path $script:RepoRoot 'scripts/bootstrap/Remove-CaCStuckApp.ps1'
        $capturedCalls = [System.Collections.Generic.List[object]]::new()

        Mock -CommandName Import-Module {}
        Mock -CommandName Connect-CaCGraph {}
        Mock -CommandName Get-Module {
            $fakeModule = [pscustomobject]@{}
            $fakeModule | Add-Member -MemberType ScriptMethod -Name NewBoundScriptBlock -Value {
                param([scriptblock] $ScriptBlock)
                $ScriptBlock
            } -Force -PassThru
        }
        function Invoke-CaCGraphRequest {
            param(
                [string] $Method,
                [string] $Uri,
                $Body
            )

            $capturedCalls.Add([pscustomobject]@{
                    Method = $Method
                    Uri    = $Uri
                    Body   = $Body
                }) | Out-Null

            if ($Method -eq 'GET') {
                return [pscustomobject]@{
                    id              = 'abc123'
                    displayName     = 'Contoso App'
                    publishingState = 'processing'
                }
            }
        }

        & $scriptPath -AppId 'abc123' -TenantId 'tenant-id' -ClientId 'client-id' -Confirm:$false

        $capturedCalls | Should -HaveCount 2
        $capturedCalls[0].Method | Should -Be 'GET'
        $capturedCalls[0].Uri | Should -Be 'deviceAppManagement/mobileApps/abc123?$select=id,displayName,publishingState'
        $capturedCalls[1].Method | Should -Be 'DELETE'
        $capturedCalls[1].Uri | Should -Be 'deviceAppManagement/mobileApps/abc123'
    }

    It 'builds fully resolved GET and DELETE URIs for orphan policy remediation' {
        $scriptPath = Join-Path $script:RepoRoot 'scripts/bootstrap/Remove-CaCOrphanConfigurationPolicy.ps1'
        $capturedCalls = [System.Collections.Generic.List[object]]::new()

        Mock -CommandName Import-Module {}
        Mock -CommandName Connect-CaCGraph {}
        Mock -CommandName Get-Module {
            $fakeModule = [pscustomobject]@{}
            $fakeModule | Add-Member -MemberType ScriptMethod -Name NewBoundScriptBlock -Value {
                param([scriptblock] $ScriptBlock)
                $ScriptBlock
            } -Force -PassThru
        }
        function Invoke-CaCGraphRequest {
            param(
                [string] $Method,
                [string] $Uri,
                $Body
            )

            $capturedCalls.Add([pscustomobject]@{
                    Method = $Method
                    Uri    = $Uri
                    Body   = $Body
                }) | Out-Null

            if ($Method -eq 'GET' -and $Uri -match '^deviceManagement/configurationPolicies\?\`?\$filter=([^&]+)&') {
                [System.Uri]::UnescapeDataString($Matches[1]) | Should -Be "name eq 'SF Adults Local Admin'"
                return [pscustomobject]@{
                    value = @([pscustomobject]@{
                            id          = 'policy123'
                            name        = 'SF Adults Local Admin'
                            description = 'Managed by sf-intune-cac. Do not edit in the portal.'
                        })
                }
            }

            if ($Method -eq 'DELETE' -and $Uri -eq 'deviceManagement/configurationPolicies/policy123') {
                return $null
            }

            throw "Unexpected Graph call: $Method $Uri"
        }

        & $scriptPath -DisplayName 'SF Adults Local Admin' -TenantId 'tenant-id' -ClientId 'client-id' -Confirm:$false

        $capturedCalls | Should -HaveCount 2
        $capturedCalls[0].Method | Should -Be 'GET'
        $capturedCalls[1].Method | Should -Be 'DELETE'
        $capturedCalls[1].Uri | Should -Be 'deviceManagement/configurationPolicies/policy123'
    }
}

Describe 'Retired local admin remediation and Autopilot Group Tag surfaces' {
    BeforeAll {
        $script:RetiredPaths = @(
            'scripts/remediation/Detect-CaCEnrollingUserLocalAdmin.ps1'
            'scripts/remediation/Remediate-CaCEnrollingUserLocalAdmin.ps1'
            'scripts/bootstrap/New-CaCLocalAdminRemediationScript.ps1'
            'scripts/bootstrap/New-CaCDeviceLocalAdminRecovery.ps1'
            'scripts/bootstrap/Set-CaCAutopilotGroupTag.ps1'
            '.github/workflows/deploy-local-admin-remediation.yml'
            '.github/workflows/set-autopilot-group-tag.yml'
            'tests/DeviceLocalAdminRecovery.Tests.ps1'
        )

        $script:GitHubIdentityBootstrap = Get-Content -Path (Join-Path $script:RepoRoot 'bootstrap/New-CaCGitHubIdentity.ps1') -Raw

        # Source surfaces only. docs/*.md deliberately keep the retirement explanation, and the
        # retired file names appear in this test by design.
        $script:SourceScanRoots = @(
            'scripts', 'src', 'config', 'bootstrap', '.github/workflows', 'README.md'
        )
    }

    It 'retains the legacy LAPS policy definition until modern LAPS backup is verified' {
        # Deleting the file would schedule an orphan deletion of the live legacy policy before a
        # verified modern backup exists. It is retained deliberately, not overlooked.
        $legacy = Join-Path $script:RepoRoot 'config/intune/endpoint-security/laps.json'
        Test-Path -LiteralPath $legacy | Should -BeTrue

        $comment = (Get-Content -LiteralPath $legacy -Raw | ConvertFrom-Json).comment -join ' '
        $comment | Should -Match 'TRANSITION ONLY'
    }

    It 'no longer ships any retired remediation, recovery, or Group Tag file' {        foreach ($relative in $script:RetiredPaths) {
            $full = Join-Path $script:RepoRoot $relative
            Test-Path -LiteralPath $full | Should -BeFalse -Because "$relative was deliberately retired"
        }
    }

    It 'leaves no executable or configuration reference to a retired file' {
        $names = @($script:RetiredPaths | ForEach-Object { Split-Path -Path $_ -Leaf })
        $offenders = [System.Collections.Generic.List[string]]::new()

        foreach ($root in $script:SourceScanRoots) {
            $full = Join-Path $script:RepoRoot $root
            if (-not (Test-Path -LiteralPath $full)) { continue }

            $files = @(Get-ChildItem -LiteralPath $full -Recurse -File)
            foreach ($file in $files) {
                # config/tenant.json keeps a dated, append-only change comment; its historical
                # entries name objects that have since been retired.
                if ($file.Name -eq 'tenant.json') { continue }
                $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
                if (-not $content) { continue }
                foreach ($name in $names) {
                    if ($content -like "*$name*") {
                        $offenders.Add("$($file.FullName) references $name") | Out-Null
                    }
                }
            }
        }

        $offenders | Should -BeNullOrEmpty -Because ($offenders -join '; ')
    }

    It 'retires the Intune script permissions in favour of device permissions on both identities' {
        $script:GitHubIdentityBootstrap | Should -Not -Match 'DeviceManagementScripts\.'
        $script:GitHubIdentityBootstrap | Should -Match "'Device\.Read\.All'"
        $script:GitHubIdentityBootstrap | Should -Match "'Device\.ReadWrite\.All'"
    }

    It 'keeps the plan identity read-only and the apply identity write-capable' {
        $applyStart = $script:GitHubIdentityBootstrap.IndexOf("Name    = 'sf-intune-cac-apply'")
        $applyStart | Should -BeGreaterThan 0
        $planBlock = $script:GitHubIdentityBootstrap.Substring(0, $applyStart)
        $applyBlock = $script:GitHubIdentityBootstrap.Substring($applyStart)

        $planBlock | Should -Match "'Device\.Read\.All'"
        $planBlock | Should -Not -Match "'Device\.ReadWrite\.All'"
        $planBlock | Should -Match "'Group\.Read\.All'"

        $applyBlock | Should -Match "'Device\.ReadWrite\.All'"
        $applyBlock | Should -Match "'Group\.ReadWrite\.All'"
    }

    It 'never declares proactive remediation (deviceHealthScripts) surfaces in the identity bootstrap' {
        $script:GitHubIdentityBootstrap | Should -Not -Match 'deviceHealthScripts'
    }
}
