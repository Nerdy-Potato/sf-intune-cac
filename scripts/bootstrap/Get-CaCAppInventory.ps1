#Requires -Version 7.2
<#
.SYNOPSIS
    Lists every Intune mobile app object in the tenant with its actual, live @odata.type and
    publishingState, as reported by Microsoft Graph right now.
.DESCRIPTION
    Diagnostic, read-only tool. Get-CaCRemoteAppCandidates matches remote apps to configuration
    by packageId/bundleId only, and Get-CaCPayloadDrift intentionally excludes @odata.type from
    drift comparison (the type is immutable after creation, so a normal Update can never fix it).
    That means a live app object created with the wrong concrete type (for example a beta
    'androidManagedStoreApp' object instead of the v1.0 'managedAndroidStoreApp' type declared in
    config/apps/*.json) will silently and permanently report as 'NoChange' in every plan, even
    though the Intune portal displays it differently (frequently as a "Built-in" app rather than a
    "Managed Google Play Store app").

    Run this to see, for every current mobileApps object, whether its live type actually matches
    what config declares - so mismatches can be identified and deleted for CI to recreate correctly
    typed, instead of being missed indefinitely.
    IncludeChildGsa also reports the two live GSA values, child assignment coverage and aggregate
    device status counts without publishing device/user identifiers.
.EXAMPLE
    ./scripts/bootstrap/Get-CaCAppInventory.ps1
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string] $TenantId = $env:AZURE_TENANT_ID,

    [Parameter()]
    [string] $ClientId = $env:AZURE_CLIENT_ID,

    [Parameter()]
    [switch] $IncludeChildGsa
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $TenantId -or -not $ClientId) {
    throw (
        'TenantId and ClientId are required. Run this script from GitHub Actions with ' +
        'AZURE_TENANT_ID and AZURE_CLIENT_ID set for the OIDC-backed Graph identity.'
    )
}

$repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../..')).Path
Import-Module -Name (Join-Path $repoRoot 'src/IntuneCaC/IntuneCaC.psd1') -Force

Connect-CaCGraph -TenantId $TenantId -ClientId $ClientId -ReadOnly

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

# Get-CaCProperty is a private module function; bind it to the module scope the same way
# graphInvoker is bound above, rather than duplicating its hashtable/PSCustomObject logic here.
$getProperty = $module.NewBoundScriptBlock({
        param(
            $InputObject,
            [Parameter(Mandatory)][string] $Name
        )

        Get-CaCProperty -InputObject $InputObject -Name $Name
    })

$configuration = Get-CaCConfiguration -Path (Join-Path $repoRoot 'config')
# Case-sensitive dictionaries, split by identity field: PowerShell's default @{} hashtable
# compares string keys case-insensitively, which would silently collide an Android packageId
# (e.g. com.microsoft.office.word) with a differently-cased iOS bundleId
# (e.g. com.microsoft.Office.Word) and report a false type mismatch. Splitting by field also
# guarantees we never compare across identity types, matching the switch on $App.source in
# Get-CaCRemoteAppCandidates.
$configuredByPackageId = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
$configuredByBundleId = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
foreach ($app in $configuration.Apps) {
    $configuredPackageId = & $getProperty $app.payload 'packageId'
    $configuredBundleId = & $getProperty $app.payload 'bundleId'
    if ($configuredPackageId) { $configuredByPackageId[$configuredPackageId] = $app }
    if ($configuredBundleId) { $configuredByBundleId[$configuredBundleId] = $app }
}

$remoteApps = @((& $graphInvoker 'GET' 'deviceAppManagement/mobileApps' $null).value | Where-Object { $_ })

$rows = foreach ($remote in $remoteApps) {
    $packageId = & $getProperty $remote 'packageId'
    $bundleId = & $getProperty $remote 'bundleId'

    $configured = $null
    $key = $null
    if ($packageId -and $configuredByPackageId.ContainsKey($packageId)) {
        $configured = $configuredByPackageId[$packageId]
        $key = $packageId
    }
    elseif ($bundleId -and $configuredByBundleId.ContainsKey($bundleId)) {
        $configured = $configuredByBundleId[$bundleId]
        $key = $bundleId
    }
    else {
        $key = if ($packageId) { $packageId } elseif ($bundleId) { $bundleId } else { $null }
    }

    $desiredType = if ($configured) { $configured.payload.'@odata.type' } else { $null }
    $actualType = & $getProperty $remote '@odata.type'

    [pscustomobject]@{
        Id               = & $getProperty $remote 'id'
        DisplayName      = & $getProperty $remote 'displayName'
        PackageOrBundle  = $key
        ActualType       = $actualType
        ConfiguredType   = $desiredType
        TypeMismatch     = [bool]($desiredType -and $actualType -ne $desiredType)
        PublishingState  = & $getProperty $remote 'publishingState'
    }
}

$rows | Sort-Object DisplayName | Format-Table -AutoSize
$mismatches = @($rows | Where-Object TypeMismatch)
if ($mismatches) {
    Write-Host ''
    Write-Warning "$($mismatches.Count) app object(s) have a live @odata.type that does not match configuration:"
    $mismatches | ForEach-Object { Write-Warning "  $($_.DisplayName) [$($_.Id)]: actual '$($_.ActualType)' vs configured '$($_.ConfiguredType)'" }
}

Write-Host ''
Write-Host '--- JSON (for scripted parsing) ---'
$rows | Sort-Object DisplayName | ConvertTo-Json -Depth 4

if ($IncludeChildGsa) {
    $gsaConfig = $configuration.Policies | Where-Object name -EQ 'android-defender-gsa-child'
    $remoteConfigurations = @((& $graphInvoker 'GET' 'deviceAppManagement/mobileAppConfigurations' $null).value |
        Where-Object { $_ })
    $matches = @($remoteConfigurations | Where-Object {
        (& $getProperty $_ 'displayName') -eq $gsaConfig.payload.displayName
    })
    if ($matches.Count -ne 1) { throw 'Expected exactly one live child Defender/GSA app configuration.' }
    $gsaId = & $getProperty $matches[0] 'id'
    $gsa = & $graphInvoker 'GET' "deviceAppManagement/mobileAppConfigurations/$gsaId" $null
    $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
        [string] (& $getProperty $gsa 'payloadJson'))) | ConvertFrom-Json -AsHashtable
    $settings = foreach ($key in @('Global Secure Access', 'GlobalSecureAccessPrivateChannel')) {
        $values = @($decoded.managedProperty | Where-Object key -CEQ $key)
        [pscustomobject]@{
            Key = $key
            Value = @($values | ForEach-Object { & $getProperty $_ 'valueString' }) -join ','
            ForcedOn = $values.Count -eq 1 -and (& $getProperty $values[0] 'valueString') -ceq '3'
        }
    }
    $assignments = @((& $graphInvoker 'GET' "deviceAppManagement/mobileAppConfigurations/$gsaId/assignments" $null).value |
        Where-Object { $_ })
    $coverage = foreach ($groupKey in @('sg-tier-child', 'sg-devices-child')) {
        $groupName = ($configuration.Groups | Where-Object id -EQ $groupKey).displayName
        $encodedFilter = [uri]::EscapeDataString("displayName eq '$($groupName.Replace("'", "''"))'")
        $groups = @((& $graphInvoker 'GET' "groups?`$filter=$encodedFilter" $null).value | Where-Object { $_ })
        if ($groups.Count -ne 1) { throw "Expected exactly one '$groupName' assignment group." }
        $groupId = & $getProperty $groups[0] 'id'
        $included = @($assignments | Where-Object {
            $target = & $getProperty $_ 'target'
            (& $getProperty $target 'groupId') -eq $groupId -and
            (& $getProperty $target '@odata.type') -eq '#microsoft.graph.groupAssignmentTarget'
        }).Count -eq 1
        $members = @((& $graphInvoker 'GET' "groups/$groupId/members" $null).value | Where-Object { $_ })
        [pscustomobject]@{ Group = $groupName; Included = $included; MemberCount = $members.Count }
    }
    $statuses = @((& $graphInvoker 'GET' "deviceAppManagement/mobileAppConfigurations/$gsaId/deviceStatuses" $null).value |
        Where-Object { $_ })
    $statusCounts = @($statuses | Group-Object -Property { & $getProperty $_ 'status' } |
        ForEach-Object { [pscustomobject]@{ Status = $_.Name; Count = $_.Count } })
    $targetIds = @(& $getProperty $gsa 'targetedMobileApps')
    $defenderPolicyCount = @($remoteConfigurations | Where-Object {
        (& $getProperty $_ 'packageId') -eq 'com.microsoft.scmx' -or
        @((& $getProperty $_ 'targetedMobileApps') | Where-Object { $_ -in $targetIds }).Count -gt 0
    }).Count
    Write-Host '--- Child Android GSA (read-only, no device/user identifiers) ---'
    [pscustomobject]@{
        Settings = @($settings)
        PayloadShape = @($decoded.Keys)
        ManagedPropertyKeys = @($decoded.managedProperty | ForEach-Object { & $getProperty $_ 'key' })
        Assignments = @($coverage)
        ExclusionCount = @($assignments | Where-Object {
            (& $getProperty (& $getProperty $_ 'target') '@odata.type') -eq '#microsoft.graph.exclusionGroupAssignmentTarget'
        }).Count
        DefenderConfigurationCount = $defenderPolicyCount
        ReportedDeviceStatuses = $statusCounts
        Note = 'Assignment and reported status inventory only; confirm GSA and VPN lockdown on each device after sync.'
    } | ConvertTo-Json -Depth 8
    if (@($settings | Where-Object { -not $_.ForcedOn }).Count -gt 0) {
        Write-Warning 'Live GSA is not forced on for both keys; deploy the reviewed configuration.'
    }
    if ($defenderPolicyCount -gt 1) {
        Write-Warning 'Multiple Defender app configurations exist; review overlapping assignments for conflicts.'
    }
}
