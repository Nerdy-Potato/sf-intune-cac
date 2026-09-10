#Requires -Version 7.2
<#
.SYNOPSIS
    Read-only diagnostic: resolves the group assignments on the manually-created
    "SF Adults Local Admin" Settings Catalog policy, and computes each candidate
    group's AAD SID encoding to identify which group matches the policy's
    accessgroup_action_add_update member SID.
.DESCRIPTION
    The live "SF Adults Local Admin" policy (id 6179ed47-e39e-4bd9-825b-80adb13df242)
    adds a group's members to the local Administrators group via the
    device_vendor_msft_policy_config_localusersandgroups_configure CSP, additively
    (accessgroup_action_add_update). Its member list is expressed as an Entra
    "AAD SID" (S-1-12-1-...) which is Microsoft's deterministic forward-encoding of
    an Entra object GUID into a Windows SID - there is no Graph API to reverse this,
    so we compute the SID forward from each candidate group's real GUID and compare
    strings.

    This script:
      1. Resolves the 3 group assignment targets on the policy via Graph
         (GET /groups/{id}) to their displayName.
      2. Computes the AAD SID for those 3 groups plus a handful of other
         candidate groups of interest, using the documented forward-encoding
         algorithm: split the 16-byte GUID into four little-endian UInt32
         values and format as S-1-12-1-{p1}-{p2}-{p3}-{p4}.
      3. Compares each computed SID against the known member SID from the
         live policy to identify a match.

    Read-only; issues no writes. Reuses the same OIDC auth path as the other
    bootstrap scripts.
.EXAMPLE
    ./scripts/bootstrap/Resolve-CaCLocalAdminPolicyTargets.ps1
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string] $TenantId = $env:AZURE_TENANT_ID,

    [Parameter()]
    [string] $ClientId = $env:AZURE_CLIENT_ID
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $TenantId -or -not $ClientId) {
    throw (
        'TenantId and ClientId are required. Run this script from GitHub Actions with ' +
        'AZURE_TENANT_ID and AZURE_CLIENT_ID set for the OIDC-backed Graph identity.'
    )
}

# The known member SID from the live "SF Adults Local Admin" policy
# (device_vendor_msft_policy_config_localusersandgroups_configure, accessgroup_action_add_update).
$KnownMemberAadSid = 'S-1-12-1-1322638706-1150646150-2137834924-157029862'

# The 3 group assignment targets (ordinary Graph object IDs) on that policy.
$AssignmentGroupIds = @(
    'a5fd2b25-90a3-43af-a01a-d6da475db918',
    '67da4a6f-2655-4589-a700-776a41b75aea',
    '1b71b3d8-d260-44ea-9ff9-6c826630ccc4'
)

# Additional groups of interest to compute the SID for, for full visibility,
# even though they are not assignment targets on the policy.
$AdditionalGroupDisplayNames = @(
    'CaC-Tier-Adult',
    'CaC-Tier-Teen',
    'CaC-Tier-Child',
    'CaC-Admins',
    'CaC-BreakGlass',
    'NuclearFamily-SG'
)

function ConvertTo-CaCAadSid {
    <#
    .SYNOPSIS
        Forward-encodes an Entra (Azure AD) object GUID into its deterministic
        "AAD SID" (S-1-12-1-...) form, as used by the Local Users and Groups CSP.
    .DESCRIPTION
        Splits the 16-byte GUID into four little-endian UInt32 values (bytes 0-3,
        4-7, 8-11, 12-15) and formats them as S-1-12-1-{p1}-{p2}-{p3}-{p4}.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [guid] $ObjectId
    )

    $bytes = $ObjectId.ToByteArray()
    $p1 = [System.BitConverter]::ToUInt32($bytes, 0)
    $p2 = [System.BitConverter]::ToUInt32($bytes, 4)
    $p3 = [System.BitConverter]::ToUInt32($bytes, 8)
    $p4 = [System.BitConverter]::ToUInt32($bytes, 12)

    return "S-1-12-1-$p1-$p2-$p3-$p4"
}

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../..')).Path
Import-Module -Name (Join-Path $repoRoot 'src/IntuneCaC/IntuneCaC.psd1') -Force

Connect-CaCGraph -TenantId $TenantId -ClientId $ClientId

$module = Get-Module -Name IntuneCaC
if (-not $module) {
    throw 'IntuneCaC module did not load.'
}

$graphInvoker = $module.NewBoundScriptBlock({
        param(
            [Parameter(Mandatory)][string] $Method,
            [Parameter(Mandatory)][string] $Uri,
            $Body
        )

        Invoke-CaCGraphRequest -Method $Method -Uri $Uri -Body $Body
    })

# Resolve the 3 policy assignment group IDs directly.
$assignmentGroups = foreach ($groupId in $AssignmentGroupIds) {
    & $graphInvoker 'GET' "groups/${groupId}?`$select=id,displayName" $null
}

# Resolve the additional groups of interest by displayName.
$additionalGroups = foreach ($name in $AdditionalGroupDisplayNames) {
    $encodedName = [System.Uri]::EscapeDataString($name)
    $response = & $graphInvoker 'GET' "groups?`$filter=displayName eq '${encodedName}'&`$select=id,displayName" $null
    foreach ($group in @($response.value)) {
        $group
    }
}

# De-duplicate by id, since a group could already be in $assignmentGroups.
$allGroups = @($assignmentGroups) + @($additionalGroups)
$uniqueGroups = $allGroups | Where-Object { $_ } | Sort-Object -Property id -Unique

$results = foreach ($group in $uniqueGroups) {
    $computedSid = ConvertTo-CaCAadSid -ObjectId ([guid] $group.id)
    [pscustomobject]@{
        DisplayName        = $group.displayName
        Id                 = $group.id
        ComputedAadSid     = $computedSid
        MatchesMemberSid   = ($computedSid -eq $KnownMemberAadSid)
        IsAssignmentTarget = ($AssignmentGroupIds -contains $group.id)
    }
}

Write-Host ''
Write-Host "Known local-admin member AAD SID (from live policy): $KnownMemberAadSid"
Write-Host ''

$results | Sort-Object -Property IsAssignmentTarget -Descending |
    Format-Table -Property DisplayName, Id, ComputedAadSid, MatchesMemberSid, IsAssignmentTarget -AutoSize

Write-Host ''
Write-Host '--- JSON (for scripted parsing) ---'
$results | ConvertTo-Json -Depth 10
