function Get-CaCDeviceTierProperty {
    param($InputObject, [string] $Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject[$Name] }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function New-CaCDeviceTierGraphInvoker {
    $module = Get-Module -Name IntuneCaC
    if (-not $module) { throw 'IntuneCaC module did not load.' }
    return $module.NewBoundScriptBlock({
        param([string] $Method, [string] $Uri, $Body)
        Invoke-CaCGraphRequest -Method $Method -Uri $Uri -Body $Body -ApiVersion 'v1.0'
    })
}

function Get-CaCDeviceTierTag {
    param($Device)
    return [string] (Get-CaCDeviceTierProperty -InputObject (
        Get-CaCDeviceTierProperty -InputObject $Device -Name 'extensionAttributes'
    ) -Name 'extensionAttribute1')
}

function Assert-CaCDeviceTierIdentity {
    param([string] $TenantId, [string] $ClientId)
    if (-not $TenantId -or -not $ClientId) {
        throw 'TenantId and ClientId are required for the production OIDC-backed Graph identity.'
    }
}
