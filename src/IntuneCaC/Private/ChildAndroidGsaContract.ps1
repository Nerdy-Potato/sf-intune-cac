# The live Android schema identifies the "Global Secure Access" UI label as EnableGSA,
# with integer values. UI labels are not payload keys, even when vendor prose calls them keys.

function Get-CaCChildGsaContract {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        PolicyName   = 'android-defender-gsa-child'
        Kind         = 'androidenterprise#managedConfiguration'
        ProductId    = 'app:com.microsoft.scmx'
        Settings     = @(
            [pscustomobject]@{ Key = 'EnableGSA'; Field = 'valueInteger'; Value = 3; SchemaType = 'integer' }
            [pscustomobject]@{ Key = 'GlobalSecureAccessPrivateChannel'; Field = 'valueInteger'; Value = 0; SchemaType = 'integer' }
        )
        ForbiddenKeys = @('Global Secure Access', 'EnableGSAPrivateChannel', 'GlobalSecureAccessPA')
    }
}

function Test-CaCChildGsaPolicy {
    [CmdletBinding()]
    param($Policy)

    return [bool] ($Policy -and (Get-CaCProperty $Policy 'name') -ceq (Get-CaCChildGsaContract).PolicyName)
}

function ConvertFrom-CaCManagedConfigurationPayload {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string] $PayloadJson)

    if ([string]::IsNullOrWhiteSpace($PayloadJson)) { throw 'payloadJson is missing.' }
    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PayloadJson))
        return $json | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "payloadJson is not base64-encoded JSON: $($_.Exception.Message)"
    }
}

function Get-CaCManagedPropertyValueFields {
    param($Property)

    $names = if ($Property -is [System.Collections.IDictionary]) { @($Property.Keys) }
    else { @($Property.PSObject.Properties.Name) }
    return @($names | Where-Object { $_ -clike 'value*' } | Sort-Object)
}

function Format-CaCManagedPropertyValue {
    param($Value)

    if ($null -eq $Value) { return 'null' }
    return (ConvertTo-Json -InputObject $Value -Compress -Depth 10)
}

function Get-CaCManagedConfigurationSummary {
    <#
    .SYNOPSIS
        Typed, order-independent description such as 'EnableGSA=valueInteger:3'. A
        string '3' renders as valueString:"3", so type drift is visible in plans and inventory.
    #>
    [CmdletBinding()]
    param($Decoded)

    $entries = foreach ($property in @(Get-CaCProperty $Decoded 'managedProperty')) {
        if ($null -eq $property) { continue }
        $fields = @(Get-CaCManagedPropertyValueFields $property)
        $values = @($fields | ForEach-Object { '{0}:{1}' -f $_, (Format-CaCManagedPropertyValue (Get-CaCProperty $property $_)) })
        '{0}={1}' -f (Get-CaCProperty $property 'key'), $(if ($values) { $values -join '|' } else { '<no value>' })
    }
    $sorted = [System.Collections.Generic.List[string]]::new([string[]] @($entries))
    $sorted.Sort([System.StringComparer]::Ordinal)
    return ($sorted -join '; ')
}

function Test-CaCIntegerValue {
    param($Value)

    return ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte])
}

function Test-CaCChildGsaManagedProperties {
    <#
    .SYNOPSIS
        Returns every reason the decoded configuration does not satisfy the typed child GSA
        contract. Used by validation, plan drift, post-write readback and the stale-plan guard.
    #>
    [CmdletBinding()]
    param($Decoded)

    $contract = Get-CaCChildGsaContract
    $errors = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Decoded) { $errors.Add('managed configuration is missing.'); return $errors.ToArray() }

    if ((Get-CaCProperty $Decoded 'kind') -cne $contract.Kind) {
        $errors.Add("kind must be '$($contract.Kind)'.")
    }
    if ((Get-CaCProperty $Decoded 'productId') -cne $contract.ProductId) {
        $errors.Add("productId must be '$($contract.ProductId)'.")
    }

    $properties = @(Get-CaCProperty $Decoded 'managedProperty' | Where-Object { $null -ne $_ })
    foreach ($forbidden in $contract.ForbiddenKeys) {
        if (@($properties | Where-Object { (Get-CaCProperty $_ 'key') -eq $forbidden }).Count -gt 0) {
            $errors.Add("'$forbidden' is not a valid Android Defender key for this policy.")
        }
    }

    foreach ($setting in $contract.Settings) {
        $exact = @($properties | Where-Object { (Get-CaCProperty $_ 'key') -ceq $setting.Key })
        $variants = @($properties | Where-Object {
                $key = [string] (Get-CaCProperty $_ 'key')
                $key -cne $setting.Key -and ($key -eq $setting.Key -or $key.Trim() -eq $setting.Key -or
                    ($key -replace '\s', '') -eq ($setting.Key -replace '\s', ''))
            })
        $expected = '{0}:{1}' -f $setting.Field, $setting.Value
        if ($variants.Count -gt 0) {
            $errors.Add("'$($setting.Key)' has a case/whitespace variant key; only the exact key is applied.")
        }
        if ($exact.Count -ne 1) {
            $errors.Add("'$($setting.Key)' must occur exactly once (found $($exact.Count)) as $expected.")
            continue
        }
        $fields = @(Get-CaCManagedPropertyValueFields $exact[0])
        $value = Get-CaCProperty $exact[0] $setting.Field
        if ($fields.Count -ne 1 -or $fields[0] -cne $setting.Field -or
            -not (Test-CaCIntegerValue $value) -or [long] $value -ne [long] $setting.Value) {
            $actual = @($fields | ForEach-Object {
                    '{0}:{1}' -f $_, (Format-CaCManagedPropertyValue (Get-CaCProperty $exact[0] $_))
                }) -join '|'
            if (-not $actual) { $actual = '<no value>' }
            $errors.Add("'$($setting.Key)' must be $expected with no competing value field (found $actual).")
        }
    }

    return $errors.ToArray()
}

function Get-CaCManagedConfigurationSchemaEvidence {
    <#
    .SYNOPSIS
        Read-only lookup of the Managed Google Play restriction schema Intune holds for the app
        (GET /beta/deviceManagement/androidManagedStoreAppConfigurationSchemas/{id}, documented to
        require only DeviceManagementConfiguration.Read.All) and comparison with the typed contract.
    .DESCRIPTION
        The id is documented as the Android package name; Intune product ids carry an 'app:'
        prefix, so both spellings of the one package are tried. Any read failure is returned as an
        error, never treated as a passing schema.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock] $GraphInvoker)

    $contract = Get-CaCChildGsaContract
    $errors = [System.Collections.Generic.List[string]]::new()
    $readErrors = [System.Collections.Generic.List[string]]::new()
    $schema = $null
    $schemaId = $null
    $packageName = $contract.ProductId -replace '^app:', ''
    foreach ($candidate in @($contract.ProductId, $packageName)) {
        try {
            $response = & $GraphInvoker 'GET' "deviceManagement/androidManagedStoreAppConfigurationSchemas/$candidate" $null
            $wrapped = Get-CaCProperty $response 'value'
            $schema = if ($wrapped -and (Test-CaCHasProperty $wrapped 'schemaItems')) { $wrapped } else { $response }
            $schemaId = $candidate
            break
        }
        catch {
            $readErrors.Add("$candidate -> $($_.Exception.Message)")
        }
    }

    $items = @()
    if (-not $schemaId) {
        $errors.Add("Managed Google Play schema for '$packageName' could not be read; refusing to treat GSA key/type as verified ($($readErrors -join '; ')).")
    }
    else {
        $items = @(@(Get-CaCProperty $schema 'schemaItems') + @(Get-CaCProperty $schema 'nestedSchemaItems') |
            Where-Object { $null -ne $_ })
        if ($items.Count -eq 0) {
            $errors.Add("Managed Google Play schema '$schemaId' returned no schema items; GSA key/type cannot be verified.")
        }
        foreach ($setting in $contract.Settings) {
            $matched = @($items | Where-Object { (Get-CaCProperty $_ 'schemaItemKey') -ceq $setting.Key })
            $types = @($matched | ForEach-Object { [string] (Get-CaCProperty $_ 'dataType') } | Sort-Object -Unique)
            if ($matched.Count -eq 0) {
                $errors.Add("Schema '$schemaId' has no item with key '$($setting.Key)'.")
            }
            elseif ($types.Count -ne 1 -or $types[0] -ne $setting.SchemaType) {
                $errors.Add("Schema '$schemaId' types '$($setting.Key)' as '$($types -join ',')', not '$($setting.SchemaType)' ($($setting.Field)).")
            }
        }
    }

    $related = @($items | Where-Object {
            "$(Get-CaCProperty $_ 'schemaItemKey') $(Get-CaCProperty $_ 'displayName')" -match 'Global ?Secure|GSA|Private ?(Access|Channel)'
        } | ForEach-Object {
            [pscustomobject]@{
                Key         = Get-CaCProperty $_ 'schemaItemKey'
                DisplayName = Get-CaCProperty $_ 'displayName'
                DataType    = Get-CaCProperty $_ 'dataType'
            }
        } | Sort-Object -Property Key, DisplayName, DataType -Unique)

    [pscustomobject]@{
        SchemaId     = $schemaId
        RelatedItems = $related
        Errors       = $errors.ToArray()
    }
}

function Get-CaCChildGsaPlanFindings {
    <#
    .SYNOPSIS
        Plan-time schema verification for the child GSA policy. Any finding becomes plan drift,
        so the policy is never reported NoChange while its key/type contract is unverified, and
        apply refuses to write it until the schema matches.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock] $GraphInvoker)

    $evidence = Get-CaCManagedConfigurationSchemaEvidence -GraphInvoker $GraphInvoker
    if (-not $evidence.Errors) { return @() }

    $related = @($evidence.RelatedItems | ForEach-Object { "$($_.Key)|$($_.DisplayName)|$($_.DataType)" }) -join '; '
    $findings = @($evidence.Errors | ForEach-Object { "gsa schema contract: $_" })
    $findings += "gsa schema contract: related schema items [$related]"
    return $findings
}

function Get-CaCChildGsaLiveErrors {
    <#
    .SYNOPSIS
        Reads the live child GSA policy (full GET, plus its assignments when group ids are given)
        and returns every contract violation. GET only; an unreadable object is a violation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock] $GraphInvoker,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $PolicyId,
        [string[]] $ExpectedIncludeGroupIds
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    try {
        $live = & $GraphInvoker 'GET' "$Path/$PolicyId" $null
        $decoded = ConvertFrom-CaCManagedConfigurationPayload ([string] (Get-CaCProperty $live 'payloadJson'))
        foreach ($problem in @(Test-CaCChildGsaManagedProperties $decoded)) {
            $errors.Add("live payload: $problem (live: $(Get-CaCManagedConfigurationSummary $decoded))")
        }
    }
    catch {
        $errors.Add("live payload could not be verified: $($_.Exception.Message)")
    }

    if ($PSBoundParameters.ContainsKey('ExpectedIncludeGroupIds')) {
        try {
            $response = & $GraphInvoker 'GET' "$Path/$PolicyId/assignments" $null
            $targets = @(@(Get-CaCProperty $response 'value') | Where-Object { $_ } | ForEach-Object { Get-CaCProperty $_ 'target' })
            $included = @{}
            foreach ($target in $targets) {
                $type = [string] (Get-CaCProperty $target '@odata.type')
                $groupId = [string] (Get-CaCProperty $target 'groupId')
                if ($type -eq '#microsoft.graph.groupAssignmentTarget') { $included[$groupId] = $true }
                else { $errors.Add("live assignment: unexpected target '$type' $groupId (only child group includes are allowed).") }
            }
            foreach ($groupId in $ExpectedIncludeGroupIds) {
                if (-not $included.ContainsKey($groupId)) { $errors.Add("live assignment: child group '$groupId' is not included.") }
            }
        }
        catch {
            $errors.Add("live assignments could not be verified: $($_.Exception.Message)")
        }
    }
    return $errors.ToArray()
}