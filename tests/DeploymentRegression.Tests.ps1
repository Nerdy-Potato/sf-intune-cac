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
    $script:SoloRecoveryBootstrap = Get-Content -Path (Join-Path $script:RepoRoot 'scripts/bootstrap/Invoke-SoloRecoveryDeploy.ps1') -Raw
    $script:StuckAppBootstrap = Get-Content -Path (Join-Path $script:RepoRoot 'scripts/bootstrap/Remove-CaCStuckApp.ps1') -Raw
    $script:StuckAppWorkflow = Get-Content -Path (Join-Path $script:RepoRoot '.github/workflows/remediate-stuck-app.yml') -Raw
    $script:IosGsa = Get-Content -Path (Join-Path $script:RepoRoot 'config/intune/device-configuration/ios-gsa-child.json') -Raw |
        ConvertFrom-Json
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
        $script:DeployWorkflow | Should -Match 'confirm_deploy:'
        $script:DeployWorkflow | Should -Match 'reviewed_sha:'
        $script:DeployWorkflow | Should -Match 'plan_run_id:'
        $script:DeployWorkflow | Should -Match 'Recovery deployment requires confirm_deploy=true'
        $script:DeployWorkflow | Should -Match '(?is)allow_delete:.*?default:\s*false'
        $script:DeployWorkflow | Should -Match '(?m)^\s*contents:\s*read\s*$'
        $script:DeployWorkflow | Should -Match '(?m)^\s*id-token:\s*write\s*$'
        $script:DeployWorkflow | Should -Not -Match 'pull-requests:\s*write'
    }

    It 'fails closed when the reviewed plan artifact is missing or skipped' {
        $script:Entrypoint | Should -Match 'Reviewed plan artifact was not found'
        $script:Entrypoint | Should -Match 'Status -ne ''Ready'''
        $script:Entrypoint | Should -Match 'ExpectedCommitSha is required for apply'
        $script:DeployWorkflow | Should -Match 'Download reviewed plan'
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
}

Describe 'Bootstrap and managed-object safety' {
    It 'documents the solo-maintainer recovery deploy inputs explicitly' {
        $script:SoloRecoveryBootstrap | Should -Match "'workflow',\s*'run',\s*'deploy\.yml'"
        $script:SoloRecoveryBootstrap | Should -Match "confirm_deploy=true"
        $script:SoloRecoveryBootstrap | Should -Match 'reviewed_sha=\$CommitSha'
        $script:SoloRecoveryBootstrap | Should -Match 'plan_run_id=\$\(\$matchingRun\.databaseId\)'
        $script:SoloRecoveryBootstrap | Should -Match 'allow_delete=\$allowDeleteValue'
    }

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
}
