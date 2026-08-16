function Connect-CaCGraph {
    <#
    .SYNOPSIS
        Authenticates to Microsoft Graph using a GitHub Actions federated credential.
    .DESCRIPTION
        No client secrets are used or stored anywhere. The workflow's short-lived OIDC token is
        exchanged directly for a Graph token, so the only thing that lives in GitHub is a client id.

        -ReadOnly puts the session into a mode where any non-GET request throws. The pull request
        planning workflow uses it as a second line of defence behind the read-only app registration.
    .EXAMPLE
        Connect-CaCGraph -TenantId $env:AZURE_TENANT_ID -ClientId $env:AZURE_CLIENT_ID -ReadOnly
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory, ParameterSetName = 'Federated')]
        [string] $ClientId,

        [Parameter(ParameterSetName = 'Federated')]
        [string] $Audience = 'api://AzureADTokenExchange',

        [Parameter(Mandatory, ParameterSetName = 'Token')]
        [string] $AccessToken,

        [Parameter()]
        [switch] $ReadOnly
    )

    if ($PSCmdlet.ParameterSetName -eq 'Token') {
        $script:GraphToken = $AccessToken
    }
    else {
        if (-not $env:ACTIONS_ID_TOKEN_REQUEST_URL -or -not $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN) {
            throw "No GitHub OIDC token endpoint available. The job needs 'permissions: id-token: write'."
        }

        $oidcUri = '{0}&audience={1}' -f $env:ACTIONS_ID_TOKEN_REQUEST_URL, [uri]::EscapeDataString($Audience)
        $oidc = Invoke-RestMethod -Method GET -Uri $oidcUri -Headers @{
            Authorization = 'Bearer ' + $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN
        }

        $tokenResponse = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
            client_id             = $ClientId
            scope                 = 'https://graph.microsoft.com/.default'
            grant_type            = 'client_credentials'
            client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            client_assertion      = $oidc.value
        }

        $script:GraphToken = $tokenResponse.access_token
    }

    $script:GraphReadOnly = [bool] $ReadOnly

    Write-Verbose "Connected to Microsoft Graph for tenant $TenantId (read-only: $($script:GraphReadOnly))."
}
