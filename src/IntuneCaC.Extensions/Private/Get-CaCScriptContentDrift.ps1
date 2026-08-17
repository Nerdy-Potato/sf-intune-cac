function Get-CaCScriptContentDrift {
    <#
    .SYNOPSIS
        Drift detector for base64-encoded Proactive Remediation script bodies.
    .DESCRIPTION
        detectionScriptContent and remediationScriptContent are base64 blobs of PowerShell source.
        Comparing the raw base64 strings would flag drift on trivial whitespace/line-ending
        differences that mean nothing; this decodes both sides, normalizes line endings, and
        compares the text. The reported drift line intentionally never includes the decoded
        script body itself (only line counts) so that plan output/PR comments never leak full
        script contents into logs.
    .EXAMPLE
        Get-CaCScriptContentDrift -PropertyName detectionScriptContent -DesiredBase64 $d -ActualBase64 $a
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $PropertyName,

        [Parameter()]
        [AllowNull()]
        [string] $DesiredBase64,

        [Parameter()]
        [AllowNull()]
        [string] $ActualBase64
    )

    function ConvertFrom-CaCScriptBase64 {
        param([string] $Base64)
        if ([string]::IsNullOrWhiteSpace($Base64)) { return '' }
        try {
            $bytes = [Convert]::FromBase64String($Base64)
            return ([System.Text.Encoding]::UTF8.GetString($bytes) -replace "`r`n", "`n").TrimEnd("`n")
        }
        catch {
            # Not valid base64 - compare as opaque strings instead of throwing, so a malformed
            # value still surfaces as drift rather than crashing the plan.
            return $Base64
        }
    }

    $desiredText = ConvertFrom-CaCScriptBase64 -Base64 $DesiredBase64
    $actualText = ConvertFrom-CaCScriptBase64 -Base64 $ActualBase64

    if ($desiredText -eq $actualText) { return $null }

    $desiredLines = @($desiredText -split "`n").Count
    $actualLines = @($actualText -split "`n").Count

    return "$($PropertyName): script content differs ($actualLines line(s) in tenant vs $desiredLines line(s) desired)"
}
