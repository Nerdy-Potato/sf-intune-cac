function Get-CaCPolicyPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)] [hashtable] $AppObjectIds
    )

    $payload = $Policy.payload | ConvertTo-Json -Depth 25 | ConvertFrom-Json -AsHashtable

    # deviceManagementConfigurationPolicies (Settings Catalog) is not a polymorphic mobileApps-
    # style resource: the live Graph object has no @odata.type and identifies itself via `name`,
    # not `displayName` (see Get-CaCResourceMap's RemoteNameProperty comment). Config keeps
    # displayName/@odata.type for schema consistency with every other resource kind; remap to the
    # real wire shape here, at the one place that builds the outbound Graph body.
    $resourceMap = Get-CaCResourceMap -Resource $Policy.resource
    $remoteNameProperty = Get-CaCProperty -InputObject $resourceMap -Name 'RemoteNameProperty'
    if ($remoteNameProperty -and $remoteNameProperty -ne 'displayName') {
        $payload[$remoteNameProperty] = $payload['displayName']
        $payload.Remove('displayName')
        $payload.Remove('@odata.type')
    }

    if (-not (Test-CaCHasProperty -InputObject $Policy -Name 'targetApps')) { return $payload }

    $targetIds = @($Policy.targetApps | ForEach-Object {
            if (-not $AppObjectIds.ContainsKey($_)) {
                throw "App '$_' has no Intune object id. Apps must be created before targeted app configuration policies."
            }
            $AppObjectIds[$_]
        })
    $payload['targetedMobileApps'] = $targetIds
    return $payload
}
