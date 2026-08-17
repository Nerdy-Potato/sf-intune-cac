function Format-CaCExtendedPlan {
    <#
    .SYNOPSIS
        Renders an extended plan as Markdown, mirroring the production Format-CaCPlan output shape.
    .EXAMPLE
        New-CaCExtendedPlan -Configuration $config -ManagedMarker $marker -BreakGlassGroupObjectId $id | Format-CaCExtendedPlan
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
        $changes = @($items | Where-Object { $_.Action -notin @('NoChange', 'Info') })
        $blocked = @($items | Where-Object { $_.Action -in @('Skip', 'Blocked') })

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('## Extended (reference implementation) configuration plan')
        $lines.Add('')
        $lines.Add('> This module is staged for review only. It is not wired into `scripts/Invoke-CaC.ps1` ' +
            'or CI, and this plan was not produced against a promise of being applied. See DECISIONS.md.')
        $lines.Add('')

        $counts = $items | Group-Object -Property Action | Sort-Object Name
        $summary = ($counts | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ' | '
        $lines.Add("**$($changes.Count) change(s)**  ($summary)")
        $lines.Add('')

        if ($items | Where-Object { $_.Action -eq 'Blocked' }) {
            $lines.Add('> [!CAUTION]')
            $lines.Add('> One or more definitions were blocked by a safety rail (most likely Conditional Access). See details below.')
            $lines.Add('')
        }

        if ($items | Where-Object { $_.Action -eq 'Delete' }) {
            $lines.Add('> [!WARNING]')
            $lines.Add('> This plan contains deletions.')
            $lines.Add('')
        }

        if ($blocked) {
            $lines.Add('### Blocked / skipped')
            $lines.Add('')
            foreach ($item in $blocked) {
                $lines.Add("- **$($item.Kind) / $($item.Action)** ``$($item.Target)``")
                foreach ($detail in $item.Details) { $lines.Add("  - $detail") }
            }
            $lines.Add('')
        }

        $lines.Add('### All actions')
        $lines.Add('')
        $lines.Add('| Kind | Action | Target | Details |')
        $lines.Add('| --- | --- | --- | --- |')
        foreach ($item in $items) {
            $detailText = ($item.Details -join '<br>') -replace '\|', '\|'
            $lines.Add("| $($item.Kind) | $($item.Action) | ``$($item.Target)`` | $detailText |")
        }

        return ($lines -join [Environment]::NewLine)
    }
}
