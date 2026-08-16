#Requires -Version 7.2
<#
.SYNOPSIS
    Single entry point used by the GitHub Actions workflows (and by humans, locally).
.DESCRIPTION
    Modes:
      validate - schema and safety validation only, no tenant access at all.
      plan     - read-only comparison of this repository with the tenant.
      apply    - plan, then write the differences to the tenant.
.EXAMPLE
    ./scripts/Invoke-CaC.ps1 -Mode validate
.EXAMPLE
    ./scripts/Invoke-CaC.ps1 -Mode plan -TenantId $env:AZURE_TENANT_ID -ClientId $env:AZURE_CLIENT_ID
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('validate', 'plan', 'apply')]
    [string] $Mode,

    [Parameter()]
    [string] $TenantId = $env:AZURE_TENANT_ID,

    [Parameter()]
    [string] $ClientId = $env:AZURE_CLIENT_ID,

    [Parameter()]
    [switch] $AllowDelete,

    [Parameter()]
    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
Import-Module -Name (Join-Path $repoRoot 'src/IntuneCaC/IntuneCaC.psd1') -Force

$configuration = Get-CaCConfiguration -Path (Join-Path $repoRoot 'config')

Write-Host "Tenant: $($configuration.Tenant.displayName) ($($configuration.Tenant.fallbackDomain))"
Write-Host "Accounts: $($configuration.Users.Count) | Groups: $($configuration.Groups.Count) | Policies: $($configuration.Policies.Count)"

$findings = Test-CaCConfiguration -Configuration $configuration
foreach ($finding in $findings) {
    $line = "[$($finding.Severity)] $($finding.Rule) :: $($finding.Target) :: $($finding.Message)"
    if ($finding.Severity -eq 'Error') { Write-Host "::error::$line" } else { Write-Host "::warning::$line" }
}

if (@($findings | Where-Object Severity -EQ 'Error')) {
    throw 'Configuration validation failed. Nothing was sent to the tenant.'
}

if ($Mode -eq 'validate') {
    Write-Host 'Validation succeeded.'
    return
}

if (-not $TenantId -or -not $ClientId) {
    throw 'TenantId and ClientId are required for plan and apply. Set the AZURE_TENANT_ID and AZURE_CLIENT_ID variables.'
}

Connect-CaCGraph -TenantId $TenantId -ClientId $ClientId -ReadOnly:($Mode -eq 'plan')

$plan = New-CaCPlan -Configuration $configuration
$markdown = $plan | Format-CaCPlan

New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
$markdown | Set-Content -Path (Join-Path $OutputPath 'plan.md') -Encoding utf8
$plan | Select-Object Kind, Action, Target, Details | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $OutputPath 'plan.json') -Encoding utf8

Write-Host $markdown

if ($env:GITHUB_STEP_SUMMARY) {
    $markdown | Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

if ($Mode -eq 'plan') { return }

$results = Invoke-CaCPlan -Plan $plan -Configuration $configuration -AllowDelete:$AllowDelete -Confirm:$false
$results | Format-Table -AutoSize | Out-String | Write-Host

if ($env:GITHUB_STEP_SUMMARY) {
    "`n### Applied`n" | Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8
    ($results | ForEach-Object { "- $($_.Status): $($_.Action) - $($_.Target) $($_.Message)" }) -join "`n" |
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8
}
