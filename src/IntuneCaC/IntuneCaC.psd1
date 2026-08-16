@{
    RootModule        = 'IntuneCaC.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '0f1d9d4a-9d1a-4f1e-9a4b-3f7c2f6d51a2'
    Author            = 'Nerdy-Potato'
    Description       = 'Configuration-as-code engine for the Nerdy Potato Intune tenant.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Connect-CaCGraph',
        'Get-CaCConfiguration',
        'Test-CaCConfiguration',
        'New-CaCPlan',
        'Format-CaCPlan',
        'Invoke-CaCPlan'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
