#Requires -Version 7.2
<#
.SYNOPSIS
    Adds one explicitly selected Entra user to the local Administrators group on one managed Windows device.
.DESCRIPTION
    Creates or reuses a deterministic static security group containing only the target Entra device
    object, then assigns a Windows custom configuration containing the LocalUsersAndGroups CSP
    Update action for exactly one Entra user SID. It never replaces or removes local group members.
    Existing target-specific objects are reused only when their ownership, membership, setting, and
    assignments are exact. All existing state is read before the first write.
.PARAMETER DeviceName
    Exact Windows managed-device name to resolve. Specify this or ManagedDeviceId, not both.
.PARAMETER ManagedDeviceId
    Exact Intune managedDevice object id to resolve. Specify this or DeviceName, not both.
.PARAMETER UserPrincipalName
    Exact enabled member user to add. A mismatch with the managed device's reported user UPN aborts.
.EXAMPLE
    ./scripts/bootstrap/New-CaCDeviceLocalAdminRecovery.ps1 -DeviceName '<device-name>' `
        -UserPrincipalName '<user@tenant.example>' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [string] $DeviceName,

    [Parameter()]
    [string] $ManagedDeviceId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $UserPrincipalName,

    [Parameter()]
    [string] $TenantId = $env:AZURE_TENANT_ID,

    [Parameter()]
    [string] $ClientId = $env:AZURE_CLIENT_ID,

    [Parameter()]
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../config')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RecoveryProperty {
    param(
        [Parameter()] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject[$Name] }

    $property = $InputObject.PSObject.Properties[$Name]
    if (-not $property) { return $null }

    return $property.Value
}

function Test-RecoveryGuid {
    param([Parameter(Mandatory)][string] $Value)

    $parsedGuid = [guid]::Empty
    return [guid]::TryParse($Value, [ref]$parsedGuid)
}

function ConvertTo-RecoverySid {
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $ObjectId
    )

    $bytes = ([guid]::Parse($ObjectId)).ToByteArray()
    $parts = for ($index = 0; $index -lt 4; $index++) {
        [System.BitConverter]::ToUInt32($bytes, $index * 4).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    return "S-1-12-1-$($parts -join '-')"
}

function Test-RecoveryGroupShape {
    param(
        [Parameter(Mandatory)] $Group,
        [Parameter(Mandatory)] [string] $ExpectedName,
        [Parameter(Mandatory)] [string] $ManagedMarker
    )

    if ([string] (Get-RecoveryProperty $Group 'displayName') -cne $ExpectedName) {
        throw "The device recovery group has an unexpected display name; refusing to reuse it."
    }
    if ([string] (Get-RecoveryProperty $Group 'description') -notlike "*$ManagedMarker*") {
        throw "The device recovery group does not carry the repository managed marker; refusing to reuse it."
    }
    if ((Get-RecoveryProperty $Group 'securityEnabled') -ne $true -or
        (Get-RecoveryProperty $Group 'mailEnabled') -ne $false) {
        throw "The device recovery group is not a non-mail-enabled security group; refusing to reuse it."
    }

    $groupTypes = @(Get-RecoveryProperty $Group 'groupTypes')
    if ($groupTypes.Count -ne 0 -or
        (Get-RecoveryProperty $Group 'membershipRule') -or
        (Get-RecoveryProperty $Group 'onPremisesSyncEnabled') -eq $true) {
        throw "The device recovery group is dynamic or directory-synchronized; refusing to reuse it."
    }
}

function Test-RecoveryPolicyShape {
    param(
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)] [string] $ExpectedName,
        [Parameter(Mandatory)] [string] $ManagedMarker,
        [Parameter(Mandatory)] [string] $ExpectedOmaUri,
        [Parameter(Mandatory)] [string] $ExpectedXml
    )

    if ([string] (Get-RecoveryProperty $Policy 'displayName') -cne $ExpectedName) {
        throw (
            "The target-specific recovery policy has unexpected display name " +
            "'$([string] (Get-RecoveryProperty $Policy 'displayName'))'; expected '$ExpectedName'."
        )
    }
    if ([string] (Get-RecoveryProperty $Policy 'description') -notlike "*$ManagedMarker*") {
        throw 'The target-specific recovery policy does not carry the repository managed marker; refusing to reuse it.'
    }
    if ([string] (Get-RecoveryProperty $Policy '@odata.type') -ne '#microsoft.graph.windows10CustomConfiguration') {
        throw 'The target-specific recovery policy is not a windows10CustomConfiguration; refusing to reuse it.'
    }

    $omaSettings = @(Get-RecoveryProperty $Policy 'omaSettings')
    if ($omaSettings.Count -ne 1 -or
        [string] (Get-RecoveryProperty $omaSettings[0] '@odata.type') -ne '#microsoft.graph.omaSettingString' -or
        [string] (Get-RecoveryProperty $omaSettings[0] 'omaUri') -cne $ExpectedOmaUri -or
        [string] (Get-RecoveryProperty $omaSettings[0] 'value') -cne $ExpectedXml) {
        throw 'The target-specific policy setting differs from the exact additive recovery setting; refusing to update it.'
    }
}

if ([string]::IsNullOrWhiteSpace($DeviceName) -eq [string]::IsNullOrWhiteSpace($ManagedDeviceId)) {
    throw 'Specify exactly one of DeviceName or ManagedDeviceId.'
}
if ([string]::IsNullOrWhiteSpace($TenantId) -or -not (Test-RecoveryGuid -Value $TenantId)) {
    throw 'TenantId must be configured as a valid Entra tenant GUID.'
}
if ([string]::IsNullOrWhiteSpace($ClientId)) {
    throw 'ClientId is required for the OIDC-backed Microsoft Graph identity.'
}
if ([string]::IsNullOrWhiteSpace($UserPrincipalName) -or $UserPrincipalName -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    throw 'UserPrincipalName must be a valid UPN.'
}

$DeviceName = if ($DeviceName) { $DeviceName.Trim() } else { $null }
$ManagedDeviceId = if ($ManagedDeviceId) { $ManagedDeviceId.Trim() } else { $null }
$UserPrincipalName = $UserPrincipalName.Trim()

if ($ManagedDeviceId -and -not (Test-RecoveryGuid -Value $ManagedDeviceId)) {
    throw 'ManagedDeviceId must be a valid Intune managedDevice GUID.'
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
            $Body,
            [string] $ApiVersion = 'v1.0'
        )

        Invoke-CaCGraphRequest -Method $Method -Uri $Uri -Body $Body -ApiVersion $ApiVersion
    })

$configuration = Get-CaCConfiguration -Path $ConfigPath
$managedMarker = [string] $configuration.Tenant.managedMarker
if ([string]::IsNullOrWhiteSpace($managedMarker)) {
    throw 'The repository managed marker is missing from tenant configuration.'
}

$odataUser = $UserPrincipalName.Replace("'", "''")
$userFilter = [uri]::EscapeDataString("userPrincipalName eq '$odataUser'")
$userResponse = & $graphInvoker -Method GET -Uri "users?`$filter=$userFilter&`$select=id,userPrincipalName,userType,accountEnabled"
$userMatches = @($userResponse.value | Where-Object {
        [string]::Equals([string] (Get-RecoveryProperty $_ 'userPrincipalName'), $UserPrincipalName, [System.StringComparison]::OrdinalIgnoreCase)
    })
if ($userMatches.Count -ne 1) {
    throw "Expected exactly one Entra user with UPN '$UserPrincipalName'; found $($userMatches.Count)."
}
$user = $userMatches[0]
$userObjectId = [string] (Get-RecoveryProperty $user 'id')
if (-not (Test-RecoveryGuid -Value $userObjectId)) {
    throw 'The selected Entra user has a missing or invalid object id.'
}
if ((Get-RecoveryProperty $user 'accountEnabled') -ne $true -or
    [string] (Get-RecoveryProperty $user 'userType') -cne 'Member') {
    throw "The selected UPN does not resolve to an enabled member user; refusing to grant local administrator access."
}

$managedFilter = if ($DeviceName) {
    $odataDeviceName = $DeviceName.Replace("'", "''")
    [uri]::EscapeDataString("deviceName eq '$odataDeviceName'")
}
else {
    [uri]::EscapeDataString("id eq '$ManagedDeviceId'")
}
$managedResponse = & $graphInvoker -Method GET -Uri (
    "deviceManagement/managedDevices?`$filter=$managedFilter&" +
    '$select=id,deviceName,operatingSystem,managementState,azureADDeviceId,userPrincipalName'
)
$managedMatches = @($managedResponse.value | Where-Object {
        if ($DeviceName) {
            [string]::Equals([string] (Get-RecoveryProperty $_ 'deviceName'), $DeviceName, [System.StringComparison]::OrdinalIgnoreCase)
        }
        else {
            [string]::Equals([string] (Get-RecoveryProperty $_ 'id'), $ManagedDeviceId, [System.StringComparison]::OrdinalIgnoreCase)
        }
    } | Where-Object {
        [string]::Equals([string] (Get-RecoveryProperty $_ 'operatingSystem'), 'Windows', [System.StringComparison]::OrdinalIgnoreCase)
    })
if ($managedMatches.Count -ne 1) {
    $selector = if ($DeviceName) { "Windows managed device named '$DeviceName'" } else { "Windows managedDevice id '$ManagedDeviceId'" }
    throw "Expected exactly one $selector; found $($managedMatches.Count)."
}
$managedDevice = $managedMatches[0]
$managedDeviceIdResolved = [string] (Get-RecoveryProperty $managedDevice 'id')
if (-not (Test-RecoveryGuid -Value $managedDeviceIdResolved)) {
    throw 'The selected Intune managedDevice has a missing or invalid id.'
}
if ([string] (Get-RecoveryProperty $managedDevice 'managementState') -cne 'managed') {
    throw "The selected Intune device is not in managementState 'managed'; refusing to assign recovery."
}

$reportedUser = [string] (Get-RecoveryProperty $managedDevice 'userPrincipalName')
if (-not [string]::IsNullOrWhiteSpace($reportedUser) -and
    -not [string]::Equals($reportedUser, $UserPrincipalName, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Selected UPN '$UserPrincipalName' differs from the managed device's reported user UPN '$reportedUser'; no changes were made."
}

$entraDeviceId = [string] (Get-RecoveryProperty $managedDevice 'azureADDeviceId')
if (-not (Test-RecoveryGuid -Value $entraDeviceId)) {
    throw 'The selected managedDevice has no valid azureADDeviceId; refusing to target an unlinked device.'
}
$deviceFilter = [uri]::EscapeDataString("deviceId eq '$entraDeviceId'")
$deviceResponse = & $graphInvoker -Method GET -Uri "devices?`$filter=$deviceFilter&`$select=id,deviceId,displayName,accountEnabled,trustType"
$deviceMatches = @($deviceResponse.value | Where-Object {
        [string]::Equals([string] (Get-RecoveryProperty $_ 'deviceId'), $entraDeviceId, [System.StringComparison]::OrdinalIgnoreCase)
    })
if ($deviceMatches.Count -ne 1) {
    throw "Expected exactly one Entra device object for azureADDeviceId '$entraDeviceId'; found $($deviceMatches.Count)."
}
$entraDevice = $deviceMatches[0]
$entraDeviceObjectId = [string] (Get-RecoveryProperty $entraDevice 'id')
if (-not (Test-RecoveryGuid -Value $entraDeviceObjectId) -or
    (Get-RecoveryProperty $entraDevice 'accountEnabled') -ne $true) {
    throw 'The linked Entra device object has a missing/invalid object id or is disabled; refusing to assign recovery.'
}

$expectedSid = ConvertTo-RecoverySid -ObjectId $userObjectId
$userSid = $expectedSid
if ($userSid -notmatch '^S-1-12-1-(?:\d{1,10}-){3}\d{1,10}$') {
    throw 'The selected Entra user object id did not produce a valid Entra SID.'
}

$policyPrefix = "CaC - Device Local Admin Recovery - Device-$($entraDeviceObjectId.ToLowerInvariant()) - User-"
$policyName = "$policyPrefix$($userObjectId.ToLowerInvariant())"
$groupName = "CaC - Device Local Admin Recovery - Device-$($entraDeviceObjectId.ToLowerInvariant())"
$omaUri = './Device/Vendor/MSFT/Policy/Config/LocalUsersAndGroups/Configure'
$xml = '<GroupConfiguration><accessgroup desc="S-1-5-32-544"><group action="U" /><add member="{0}" /></accessgroup></GroupConfiguration>' -f $userSid
$policyDescription = "Adds exactly one selected Entra user SID to local Administrators using LocalUsersAndGroups Update. $managedMarker"
$groupDescription = "Static device-only scope for a single-user local administrator recovery. $managedMarker"

$odataGroupName = $groupName.Replace("'", "''")
$groupFilter = [uri]::EscapeDataString("displayName eq '$odataGroupName'")
$groupResponse = & $graphInvoker -Method GET -Uri (
    "groups?`$filter=$groupFilter&" +
    '$select=id,displayName,description,securityEnabled,mailEnabled,groupTypes,membershipRule,membershipRuleProcessingState,onPremisesSyncEnabled'
)
$groupMatches = @($groupResponse.value | Where-Object {
        [string]::Equals([string] (Get-RecoveryProperty $_ 'displayName'), $groupName, [System.StringComparison]::OrdinalIgnoreCase)
    })
if ($groupMatches.Count -gt 1) {
    throw "More than one group has the exact deterministic recovery-group name '$groupName'; refusing to write."
}

$group = $null
$groupObjectId = $null
$groupMemberIds = @()
if ($groupMatches.Count -eq 1) {
    $group = $groupMatches[0]
    Test-RecoveryGroupShape -Group $group -ExpectedName $groupName -ManagedMarker $managedMarker
    $groupObjectId = [string] (Get-RecoveryProperty $group 'id')
    if (-not (Test-RecoveryGuid -Value $groupObjectId)) {
        throw 'The target-specific recovery group has a missing or invalid Entra object id.'
    }
    $memberResponse = & $graphInvoker -Method GET -Uri "groups/$groupObjectId/members?`$select=id"
    $groupMemberIds = @($memberResponse.value | ForEach-Object { [string] (Get-RecoveryProperty $_ 'id') })
    $unexpectedMembers = @($groupMemberIds | Where-Object {
            -not [string]::Equals($_, $entraDeviceObjectId, [System.StringComparison]::OrdinalIgnoreCase)
        })
    if ($unexpectedMembers.Count -gt 0 -or $groupMemberIds.Count -gt 1) {
        throw "The target-specific recovery group is not exclusive to the selected Entra device; refusing to widen its scope."
    }
}

$policyResponse = & $graphInvoker -Method GET -Uri 'deviceManagement/deviceConfigurations?$select=id,displayName,description'
$deviceRecoveryPolicies = @($policyResponse.value | Where-Object {
        $name = [string] (Get-RecoveryProperty $_ 'displayName')
        $name.StartsWith($policyPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    })
$otherTargetPolicies = @($deviceRecoveryPolicies | Where-Object {
        [string] (Get-RecoveryProperty $_ 'displayName') -cne $policyName
    })
if ($otherTargetPolicies.Count -gt 0) {
    throw 'A repository-owned recovery policy already exists for this device and a different user; refusing to accumulate local-admin grants.'
}

$policyMatches = @($deviceRecoveryPolicies | Where-Object {
        [string]::Equals([string] (Get-RecoveryProperty $_ 'displayName'), $policyName, [System.StringComparison]::OrdinalIgnoreCase)
    })
if ($policyMatches.Count -gt 1) {
    throw "More than one policy has the exact deterministic recovery-policy name '$policyName'; refusing to write."
}

$policy = $null
$policyObjectId = $null
$policyAssignments = @()
$hasExactAssignment = $false
if ($policyMatches.Count -eq 1) {
    $policySummary = $policyMatches[0]
    $policyObjectId = [string] (Get-RecoveryProperty $policySummary 'id')
    if (-not (Test-RecoveryGuid -Value $policyObjectId)) {
        throw 'The target-specific recovery policy has a missing or invalid object id.'
    }
    $policy = & $graphInvoker -Method GET -Uri "deviceManagement/deviceConfigurations/$policyObjectId"
    Test-RecoveryPolicyShape -Policy $policy -ExpectedName $policyName -ManagedMarker $managedMarker -ExpectedOmaUri $omaUri -ExpectedXml $xml
    $assignmentResponse = & $graphInvoker -Method GET -Uri "deviceManagement/deviceConfigurations/$policyObjectId/assignments"
    $policyAssignments = @($assignmentResponse.value)
    if ($policyAssignments.Count -gt 1) {
        throw 'The target-specific recovery policy has multiple assignments; refusing to replace or widen them.'
    }
    if ($policyAssignments.Count -eq 1) {
        $target = Get-RecoveryProperty $policyAssignments[0] 'target'
        $targetType = [string] (Get-RecoveryProperty $target '@odata.type')
        $targetGroupId = [string] (Get-RecoveryProperty $target 'groupId')
        if ($targetType -cne '#microsoft.graph.groupAssignmentTarget' -or
            -not $groupObjectId -or
            -not [string]::Equals($targetGroupId, $groupObjectId, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'The target-specific recovery policy has an assignment outside the exact static device group; refusing to replace it.'
        }
        $hasExactAssignment = $true
    }
}

$needsGroupCreate = $null -eq $group
$needsGroupMember = $groupMemberIds.Count -eq 0
$needsPolicyCreate = $null -eq $policy
$needsAssignment = -not $hasExactAssignment
$changes = [System.Collections.Generic.List[string]]::new()
if ($needsGroupCreate) { $changes.Add("create static security group '$groupName'") }
if ($needsGroupMember) { $changes.Add("add only Entra device object '$entraDeviceObjectId' to the recovery group") }
if ($needsPolicyCreate) { $changes.Add("create additive LocalUsersAndGroups policy '$policyName'") }
if ($needsAssignment) { $changes.Add("assign the policy exclusively to the recovery device group") }

if ($changes.Count -gt 0 -and -not $PSCmdlet.ShouldProcess(
        "Windows device '$($managedDevice.deviceName)' / Entra user '$UserPrincipalName'",
        ($changes -join '; ')
    )) {
    $status = if ($WhatIfPreference) { 'WhatIf' } else { 'NotApplied' }
    return [pscustomobject]@{
        Status                 = $status
        DeviceName             = [string] (Get-RecoveryProperty $managedDevice 'deviceName')
        ManagedDeviceId        = $managedDeviceIdResolved
        EntraDeviceObjectId    = $entraDeviceObjectId
        UserPrincipalName      = $UserPrincipalName
        UserObjectId           = $userObjectId
        UserSid                = $userSid
        GroupObjectId          = $groupObjectId
        PolicyObjectId         = $policyObjectId
        PlannedChanges         = $changes.ToArray()
        Scope                  = 'One static security device group with exactly the selected Entra device object.'
        EndpointSuccessVerified = $false
        EndpointState          = 'Not checked; policy application and local group membership require device sync and endpoint verification.'
    }
}

if ($needsGroupCreate) {
    $mailNickname = 'cac-recovery-device-' + $entraDeviceObjectId.Replace('-', '').ToLowerInvariant()
    $groupPayload = @{
        displayName     = $groupName
        description     = $groupDescription
        mailEnabled     = $false
        mailNickname    = $mailNickname
        securityEnabled = $true
        groupTypes      = @()
    }
    try {
        $createdGroup = & $graphInvoker -Method POST -Uri 'groups' -Body $groupPayload
    }
    catch {
        throw "Graph failed to create recovery group '$groupName'. No policy was created. $($_.Exception.Message)"
    }
    $groupObjectId = [string] (Get-RecoveryProperty $createdGroup 'id')
    if (-not (Test-RecoveryGuid -Value $groupObjectId)) {
        throw "Graph returned no valid group object id after creating '$groupName'; inspect tenant state before retrying."
    }
    $group = $createdGroup
}

if ($needsGroupMember) {
    try {
        & $graphInvoker -Method POST -Uri "groups/$groupObjectId/members/`$ref" -Body @{
            '@odata.id' = "https://graph.microsoft.com/v1.0/devices/$entraDeviceObjectId"
        } | Out-Null
    }
    catch {
        throw "Graph failed to add the selected Entra device object to recovery group '$groupName' [$groupObjectId]. The group may remain empty; no policy was created. $($_.Exception.Message)"
    }
}

$verifiedGroupMembersResponse = & $graphInvoker -Method GET -Uri "groups/$groupObjectId/members?`$select=id"
$verifiedGroupMemberIds = @($verifiedGroupMembersResponse.value | ForEach-Object { [string] (Get-RecoveryProperty $_ 'id') })
if ($verifiedGroupMemberIds.Count -ne 1 -or
    -not [string]::Equals($verifiedGroupMemberIds[0], $entraDeviceObjectId, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw (
        "Recovery group '$groupName' [$groupObjectId] failed exact membership verification; " +
        "expected only '$entraDeviceObjectId', found $($verifiedGroupMemberIds -join ', '); policy creation was stopped."
    )
}

if ($needsPolicyCreate) {
    $policyPayload = @{
        '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'
        displayName   = $policyName
        description   = $policyDescription
        omaSettings   = @(
            @{
                '@odata.type' = '#microsoft.graph.omaSettingString'
                displayName  = 'Local Administrators additive membership'
                description  = 'Update the built-in Administrators group with one Entra user SID; preserve all other members.'
                omaUri       = $omaUri
                value        = $xml
            }
        )
    }
    try {
        $createdPolicy = & $graphInvoker -Method POST -Uri 'deviceManagement/deviceConfigurations' -Body $policyPayload
    }
    catch {
        throw "Graph failed to create recovery policy '$policyName'. The exact device group remains in place. $($_.Exception.Message)"
    }
    $policyObjectId = [string] (Get-RecoveryProperty $createdPolicy 'id')
    if (-not (Test-RecoveryGuid -Value $policyObjectId)) {
        throw "Graph returned no valid policy object id after creating '$policyName'; inspect tenant state before retrying."
    }
}

if ($needsAssignment) {
    try {
        & $graphInvoker -Method POST -Uri "deviceManagement/deviceConfigurations/$policyObjectId/assign" -Body @{
            assignments = @(
                @{
                    '@odata.type' = '#microsoft.graph.deviceConfigurationAssignment'
                    target        = @{
                        '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                        groupId       = $groupObjectId
                    }
                }
            )
        } | Out-Null
    }
    catch {
        throw "Graph failed to assign recovery policy '$policyName' [$policyObjectId] to only group '$groupName' [$groupObjectId]. The policy and group may exist without an assignment. $($_.Exception.Message)"
    }
}

$verifiedGroup = & $graphInvoker -Method GET -Uri (
    "groups/${groupObjectId}?`$select=id,displayName,description,securityEnabled,mailEnabled,groupTypes,membershipRule,membershipRuleProcessingState,onPremisesSyncEnabled"
)
Test-RecoveryGroupShape -Group $verifiedGroup -ExpectedName $groupName -ManagedMarker $managedMarker
$verifiedPolicy = & $graphInvoker -Method GET -Uri "deviceManagement/deviceConfigurations/$policyObjectId"
Test-RecoveryPolicyShape -Policy $verifiedPolicy -ExpectedName $policyName -ManagedMarker $managedMarker -ExpectedOmaUri $omaUri -ExpectedXml $xml
$verifiedAssignmentsResponse = & $graphInvoker -Method GET -Uri "deviceManagement/deviceConfigurations/$policyObjectId/assignments"
$verifiedAssignments = @($verifiedAssignmentsResponse.value)
if ($verifiedAssignments.Count -ne 1) {
    throw "Recovery policy '$policyName' [$policyObjectId] did not verify as having exactly one assignment."
}
$verifiedTarget = Get-RecoveryProperty $verifiedAssignments[0] 'target'
if ([string] (Get-RecoveryProperty $verifiedTarget '@odata.type') -cne '#microsoft.graph.groupAssignmentTarget' -or
    -not [string]::Equals([string] (Get-RecoveryProperty $verifiedTarget 'groupId'), $groupObjectId, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Recovery policy '$policyName' [$policyObjectId] did not verify as assigned exclusively to group '$groupName' [$groupObjectId]."
}

[pscustomobject]@{
    Status                  = 'AppliedAndVerifiedInGraph'
    DeviceName              = [string] (Get-RecoveryProperty $managedDevice 'deviceName')
    ManagedDeviceId         = $managedDeviceIdResolved
    EntraDeviceId           = $entraDeviceId
    EntraDeviceObjectId     = $entraDeviceObjectId
    UserPrincipalName       = $UserPrincipalName
    UserObjectId            = $userObjectId
    UserSid                 = $userSid
    GroupObjectId           = $groupObjectId
    PolicyObjectId          = $policyObjectId
    PlannedChanges          = $changes.ToArray()
    Scope                   = 'One static security device group containing exactly the selected Entra device object; policy assigned only to that group.'
    EndpointSuccessVerified = $false
    EndpointState           = 'Not checked; policy application and local group membership require device sync and endpoint verification.'
}
