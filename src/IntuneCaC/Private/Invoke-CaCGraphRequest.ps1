function Invoke-CaCGraphRequest {
    <#
    .SYNOPSIS
        Minimal Microsoft Graph client with paging and throttling support.
    .DESCRIPTION
        Deliberately dependency free: the workflows run on hosted runners and installing the full
        Graph SDK on every job is slow and pulls in a large amount of code we do not need.
        Every call funnels through here so that retry, throttling and read-only enforcement are
        implemented exactly once.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter()]
        $Body,

        [Parameter()]
        [ValidateSet('v1.0', 'beta')]
        [string] $ApiVersion = 'beta',

        [Parameter()]
        [int] $MaxAttempts = 5
    )

    if (-not $script:GraphToken) {
        throw 'Not connected to Microsoft Graph. Call Connect-CaCGraph first.'
    }

    if ($script:GraphReadOnly -and $Method -ne 'GET') {
        throw "Refusing to issue a $Method request while the session is read-only: $Uri"
    }

    $requestUri = if ($Uri -match '^https://') { $Uri } else { "https://graph.microsoft.com/$ApiVersion/$($Uri.TrimStart('/'))" }

    $headers = @{ Authorization = 'Bearer ' + $script:GraphToken }

    $jsonBody = $null
    if ($null -ne $Body) {
        $jsonBody = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 25 }
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $response = Invoke-RestMethod -Method $Method -Uri $requestUri -Headers $headers -Body $jsonBody -ContentType 'application/json' -ErrorAction Stop

            $nextLink = Get-CaCProperty -InputObject $response -Name '@odata.nextLink'
            if ($Method -eq 'GET' -and $nextLink) {
                $items = [System.Collections.Generic.List[object]]::new()
                $items.AddRange(@(Get-CaCProperty -InputObject $response -Name 'value'))

                while ($nextLink) {
                    $page = Invoke-CaCGraphRequest -Method GET -Uri $nextLink -ApiVersion $ApiVersion
                    $items.AddRange(@(Get-CaCProperty -InputObject $page -Name 'value'))
                    $nextLink = Get-CaCProperty -InputObject $page -Name '@odata.nextLink'
                }

                return [pscustomobject]@{ value = $items.ToArray() }
            }

            return $response
        }
        catch {
            $status = 0
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                $status = [int] $_.Exception.Response.StatusCode
            }

            if ($status -notin @(429, 500, 502, 503, 504) -or $attempt -eq $MaxAttempts) { throw }

            $delay = [int] [Math]::Pow(2, $attempt)
            Write-Warning "Graph returned $status for $Method $requestUri. Retrying in $delay second(s) (attempt $attempt of $MaxAttempts)."
            Start-Sleep -Seconds $delay
        }
    }
}
