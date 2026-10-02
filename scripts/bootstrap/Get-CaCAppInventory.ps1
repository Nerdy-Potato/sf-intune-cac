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
    IncludeChildGsa also reports, for the two Android GSA keys, the desired typed value next to
    every actual typed value stored by Intune (valueString "3" is NOT reported as forced on), the
    live Managed Google Play schema key/type evidence, child assignment coverage and aggregate
    Intune delivery status counts, without publishing device/user identifiers. Private Access
    (GlobalSecureAccessPrivateChannel) is intentionally 0; a delivery status of 'compliant' is
    not proof of the on-device GSA state.
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
    $contract = & $module { Get-CaCChildGsaContract }
    $decoded = & $module { param($PayloadJson) ConvertFrom-CaCManagedConfigurationPayload $PayloadJson } (
        [string] (& $getProperty $gsa 'payloadJson'))
    $contractErrors = @(& $module { param($Decoded) Test-CaCChildGsaManagedProperties $Decoded } $decoded)
    $settings = foreach ($setting in $contract.Settings) {
        $values = @($decoded.managedProperty | Where-Object { (& $getProperty $_ 'key') -ceq $setting.Key })
        $actual = @($values | ForEach-Object {
                $property = $_
                @($property.Keys | Where-Object { $_ -clike 'value*' } | Sort-Object | ForEach-Object {
                        '{0}:{1}' -f $_, (ConvertTo-Json -InputObject $property[$_] -Compress)
                    }) -join '|'
            })
        $desired = '{0}:{1}' -f $setting.Field, $setting.Value
        $matchesDesired = $values.Count -eq 1 -and $actual.Count -eq 1 -and $actual[0] -ceq $desired
        $row = [ordered]@{
            Key        = $setting.Key
            Desired    = $desired
            Actual     = $actual
            EntryCount = $values.Count
            Matches    = $matchesDesired
        }
        if ($setting.Key -ceq 'EnableGSA') { $row.ForcedOn = $matchesDesired }
        else { $row.PrivateAccessDisabled = $matchesDesired }
        [pscustomobject] $row
    }
    $schema = & $module { param($Invoker) Get-CaCManagedConfigurationSchemaEvidence -GraphInvoker $Invoker } $graphInvoker
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
        (& $getProperty $_ 'packageId') -in @('com.microsoft.scmx', 'app:com.microsoft.scmx') -or
        @((& $getProperty $_ 'targetedMobileApps') | Where-Object { $_ -in $targetIds }).Count -gt 0
    }).Count
    Write-Host '--- Child Android GSA (read-only, no device/user identifiers) ---'
    [pscustomobject]@{
        Settings = @($settings)
        ContractSatisfied = ($contractErrors.Count -eq 0)
        ContractErrors = $contractErrors
        Schema = [pscustomobject]@{
            SchemaId     = $schema.SchemaId
            RelatedItems = @($schema.RelatedItems)
            Errors       = @($schema.Errors)
        }
        PayloadShape = @($decoded.Keys)
        ManagedPropertyKeys = @($decoded.managedProperty | ForEach-Object { & $getProperty $_ 'key' })
        Assignments = @($coverage)
        ExclusionCount = @($assignments | Where-Object {
            (& $getProperty (& $getProperty $_ 'target') '@odata.type') -eq '#microsoft.graph.exclusionGroupAssignmentTarget'
        }).Count
        DefenderConfigurationCount = $defenderPolicyCount
        ReportedDeviceStatuses = $statusCounts
        Note = ('ReportedDeviceStatuses are Intune delivery states, not proof of the on-device GSA toggle; ' +
            "Private Access is intentionally 0. Confirm GSA is on and locked plus VPN lockdown on each device after sync.")
    } | ConvertTo-Json -Depth 8
    if (-not @($settings | Where-Object { $_.Key -ceq 'EnableGSA' })[0].ForcedOn) {
        Write-Warning 'Live main GSA is not typed valueInteger 3 (forced on); deploy the reviewed configuration.'
    }
    if ($contractErrors) {
        Write-Warning "Live child GSA configuration violates the typed contract: $($contractErrors -join ' ')"
    }
    if ($schema.Errors) {
        Write-Warning "Managed Google Play schema does not confirm the GSA key/type contract: $($schema.Errors -join ' ')"
    }
    if ($defenderPolicyCount -gt 1) {
        Write-Warning 'Multiple Defender app configurations exist; review overlapping assignments for conflicts.'
    }
}
