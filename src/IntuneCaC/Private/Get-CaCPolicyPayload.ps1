function Get-CaCPolicyPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)] [hashtable] $AppObjectIds
    )

    $payload = $Policy.payload | ConvertTo-Json -Depth 25 | ConvertFrom-Json -AsHashtable
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
