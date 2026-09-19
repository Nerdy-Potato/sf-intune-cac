<#
.SYNOPSIS
    Intune proactive remediation REMEDIATION script: adds the user who performed this device's
    MDM enrollment to the local Administrators group.
.DESCRIPTION
    Companion to Detect-CaCEnrollingUserLocalAdmin.ps1 - see that script for the full rationale
    and the enrolling-user UPN discovery mechanism. This script only runs when detection reports
    non-compliance (exit code 1), and only ever on devices assigned this remediation (CaC-Devices-
    Adult and CaC-Devices-Teen - see scripts/bootstrap/New-CaCLocalAdminRemediationScript.ps1).

    Uses `net localgroup` rather than Add-LocalGroupMember: this is the same command that reliably
    grants an Entra-joined (AzureAD\<upn>) account local admin rights from a SYSTEM/WinRE context
    in this tenant, and Add-LocalGroupMember has been observed to fail to resolve "AzureAD\" -
    prefixed principals on some builds even when the account already has a local security
    principal. Add-LocalGroupMember is still tried first since it is the more idiomatic API; `net
    localgroup` is the fallback, not a replacement.

    Exit code 0 = the enrolling user is now (or already was) a local administrator. Exit code 1 =
    could not add them (for example, the user has never signed in on this device yet, so no local
    security principal exists for their account); Intune will retry on the next scheduled run.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CaCEnrollingUserUpn {
    $enrollmentsKey = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (-not (Test-Path -Path $enrollmentsKey)) {
        return $null
    }

    foreach ($enrollment in Get-ChildItem -Path $enrollmentsKey -ErrorAction SilentlyContinue) {
        $properties = Get-ItemProperty -Path $enrollment.PSPath -ErrorAction SilentlyContinue
        if (-not $properties) { continue }
        if ($properties.ProviderID -ne 'MS DM Server') { continue }
        if ($properties.UPN) { return [string] $properties.UPN }
    }

    return $null
}

try {
    $upn = Get-CaCEnrollingUserUpn
    if (-not $upn) {
        Write-Output 'No MDM enrollment UPN found on this device yet; nothing to remediate.'
        exit 0
    }

    $accountName = "AzureAD\$upn"
    try {
        [void] ([System.Security.Principal.NTAccount] $accountName).Translate([System.Security.Principal.SecurityIdentifier])
    }
    catch {
        Write-Output "'$accountName' has no local security principal yet (user may not have signed in on this device yet); cannot remediate until they sign in at least once."
        exit 1
    }

    try {
        Add-LocalGroupMember -Group 'Administrators' -Member $accountName -ErrorAction Stop
        Write-Output "Added '$upn' to the local Administrators group."
        exit 0
    }
    catch [Microsoft.PowerShell.Commands.MemberExistsException] {
        Write-Output "'$upn' is already a local administrator."
        exit 0
    }
    catch {
        Write-Output "Add-LocalGroupMember failed ($($_.Exception.Message)); falling back to net localgroup."
        $netOutput = & net localgroup Administrators $accountName /add 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Output "Added '$upn' to the local Administrators group via net localgroup."
            exit 0
        }
        if ($netOutput -match 'already a member') {
            Write-Output "'$upn' is already a local administrator."
            exit 0
        }

        Write-Output "net localgroup failed: $netOutput"
        exit 1
    }
}
catch {
    Write-Output "Remediation failed: $($_.Exception.Message)"
    exit 1
}
