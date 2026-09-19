<#
.SYNOPSIS
    Intune proactive remediation DETECTION script: verifies the user who performed this device's
    MDM enrollment is a local administrator.
.DESCRIPTION
    Windows Autopilot Device Preparation is supposed to add the enrolling user to the local
    Administrators group when its "User account type" setting is Administrator, but this has
    proven unreliable in practice - the account type setting can be verified correct end to end
    (Device Preparation policy, group targeting, MDM enrollment) and the enrolling user still
    isn't a local admin afterwards. This remediation pair is the safety net: it does not depend on
    Device Preparation's own admin-grant step at all, and instead independently enforces that the
    specific person who enrolled THIS device (not every member of their tier) is a local admin.

    Runs as SYSTEM (the Intune remediation default), so it cannot rely on the interactively signed
    in user. Instead it reads the enrolling user's UPN from the MDM enrollment registry key that
    Windows writes at enrollment time - a well known, documented location, not something this
    script invents: HKLM:\SOFTWARE\Microsoft\Enrollments\<GUID>\UPN, scoped to the enrollment
    whose ProviderID is "MS DM Server" (the actual Intune MDM enrollment, as opposed to any WNS/
    push-only child enrollment under the same GUID tree).

    This script is only ever assigned (see scripts/bootstrap/New-CaCLocalAdminRemediationScript.ps1)
    to the CaC-Devices-Adult and CaC-Devices-Teen dynamic device groups - the same device-scoped
    groups Windows LAPS targets - so it never runs on Child-tier devices and never needs to
    re-derive tier from Graph on the device itself.

    Exit code 0 = compliant (remediation script will not run). Exit code 1 = needs remediation.
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
        Write-Output 'No MDM enrollment UPN found on this device yet; nothing to check.'
        exit 0
    }

    $accountName = "AzureAD\$upn"
    try {
        $sid = ([System.Security.Principal.NTAccount] $accountName).Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        Write-Output "'$accountName' has no local security principal yet (user may not have signed in on this device yet); nothing to check."
        exit 0
    }

    $isAdmin = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop) |
        Where-Object { $_.SID -and $_.SID.Value -eq $sid }

    if ($isAdmin) {
        Write-Output "'$upn' is already a local administrator."
        exit 0
    }

    Write-Output "'$upn' enrolled this device but is not a local administrator."
    exit 1
}
catch {
    Write-Output "Detection failed: $($_.Exception.Message)"
    exit 1
}
