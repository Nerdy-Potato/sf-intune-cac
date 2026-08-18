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
        # Orthogonal to $blocked: these items are a normal, honest Create/Update/Delete/Assignment
        # diff for a resource kind Microsoft Graph permanently refuses app-only writes to (see
        # Get-CaCResourceMap's deviceEnrollmentConfigurations entry). They are not blocked and will
        # still be attempted for every other resource in the same plan - flagged separately so the
        # callout can never be mistaken for "the deployment is blocked".
        $portalApplyItems = @($changes | Where-Object {
                $_.PSObject.Properties['RequiresPortalApply'] -and $_.RequiresPortalApply
            })

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

        if ($portalApplyItems) {
            $lines.Add('> [!IMPORTANT]')
            $lines.Add('> Microsoft Graph blocks app-only/service-principal writes to Enrollment Restrictions by design - this is not a bug in this pipeline and will not be fixed by retrying or by changing the app registration''s permissions/roles (see [Microsoft365DSC/Microsoft365DSC#5127](https://github.com/microsoft/Microsoft365DSC/issues/5127)).')
            $lines.Add('> Apply the item(s) below by hand in the Intune admin center: Devices > Enrollment > Enrollment restrictions (Platform restrictions / Device limit restrictions, as applicable).')
            $lines.Add('> Everything else in this plan still deploys automatically. The next plan run will show `NoChange` for these once the portal matches this configuration.')
            $lines.Add('>')
            foreach ($item in $portalApplyItems) {
                $lines.Add("> - $($item.Action) $($item.Kind): $($item.Target)")
            }
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
