@{
    RootModule        = 'IntuneCaC.Extensions.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '7c9e3f2a-4b1d-4e6a-9c2f-6a1d8e5b3c40'
    Author            = 'Nerdy-Potato'
    Description       = 'Reference implementation staging ground for Intune resource kinds not yet ' +
                         'supported by the production IntuneCaC module (Settings Catalog, Endpoint ' +
                         'Security, Conditional Access, Assignment Filters, Proactive Remediation). ' +
                         'See DECISIONS.md before using this against a real tenant. Not wired into ' +
                         'scripts/Invoke-CaC.ps1 or CI; staged for review only.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-CaCExtendedConfiguration',
        'Test-CaCExtendedConfiguration',
        'New-CaCExtendedPlan',
        'Format-CaCExtendedPlan',
        'Invoke-CaCExtendedPlan'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
