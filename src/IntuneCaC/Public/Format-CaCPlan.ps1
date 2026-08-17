function Format-CaCPlan {
    <#
    .SYNOPSIS
        Renders a plan as Markdown for the pull request comment and the job summary.
    .EXAMPLE
        New-CaCPlan -Configuration $config | Format-CaCPlan
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyCollection()]
        $Plan
    )

    begin { $items = [System.Collections.Generic.List[object]]::new() }
    process { foreach ($item in @($Plan)) { $items.Add($item) } }

    end {
        $changes = @($items | Where-Object { $_.Action -ne 'NoChange' })
        $blocked = @($items | Where-Object { $_.Action -in @('Skip', 'Prerequisite') })
        $adoptions = @($items | Where-Object { $_.Action -eq 'Adopt' })

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('## Intune configuration plan')
        $lines.Add('')

        $counts = $items | Group-Object -Property Action | Sort-Object Name
        $summary = ($counts | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ' | '
        $lines.Add("**$($changes.Count) change(s)**  ($summary)")
        $lines.Add('')

        if ($items | Where-Object { $_.Action -eq 'Delete' }) {
            $lines.Add('> [!WARNING]')
            $lines.Add('> This plan contains deletions. They are only carried out when the deployment is run with `allow_delete`.')
            $lines.Add('')
        }

        if ($blocked) {
            $lines.Add('> [!CAUTION]')
            $lines.Add('> This plan contains skipped or prerequisite actions. Deployment is blocked until they are resolved.')
            $lines.Add('')
        }

        if ($adoptions) {
            $lines.Add('> [!WARNING]')
            $lines.Add('> This plan contains one-time adoption actions. Verify the exact identity and shape, then remove the adoption section from `config/tenant.json` after the successful apply.')
            $lines.Add('')
        }

        if (-not $changes) {
            $lines.Add('No changes. The tenant matches this repository.')
            return ($lines -join "`n")
        }

        $lines.Add('| Action | Kind | Target | Detail |')
        $lines.Add('| --- | --- | --- | --- |')

        foreach ($item in $changes) {
            $detail = (@($item.Details) -join '<br>')
            if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 497) + '...' }
            $lines.Add("| $($item.Action) | $($item.Kind) | $($item.Target) | $detail |")
        }

        return ($lines -join "`n")
    }
}
