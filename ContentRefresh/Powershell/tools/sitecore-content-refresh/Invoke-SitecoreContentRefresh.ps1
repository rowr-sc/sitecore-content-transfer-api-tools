#Requires -Version 5.1

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateSet('PROD', 'UAT', 'DEV')]
    [string] $SourceEnvironment,

    [Parameter(Mandatory = $true)]
    [ValidateSet('UAT', 'DEV')]
    [string] $DestinationEnvironment,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $ManifestPath,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Preview', 'Execute')]
    [string] $Mode = 'Preview',

    [Parameter(Mandatory = $false)]
    [string] $Confirm,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 300)]
    [int] $PollIntervalSeconds = 5,

    [Parameter(Mandatory = $false)]
    [ValidateRange(60, 7200)]
    [int] $TimeoutSeconds = 1800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ContentTransferApiPath = '/sitecore/api/content/transfer/v1'
$ItemTransferApiPath = '/sitecore/shell/api/v3/ItemsTransfer'
$AuthenticationUrl = 'https://auth.sitecorecloud.io/oauth/token'
$AuthenticationAudience = 'https://api.sitecorecloud.io'

Add-Type -AssemblyName System.Net.Http


function Write-Step {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    Write-Host ''
    Write-Host "==> $Message"
}


function Get-RequiredEnvironmentVariable {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $value = [Environment]::GetEnvironmentVariable($Name)

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required environment variable '$Name' is not defined."
    }

    return $value
}


function Normalize-HostUrl {
    param (
        [Parameter(Mandatory = $true)]
        [string] $HostUrl
    )

    return $HostUrl.TrimEnd('/')
}


function Get-SitecoreAccessToken {
    param (
        [Parameter(Mandatory = $true)]
        [string] $ClientId,

        [Parameter(Mandatory = $true)]
        [string] $ClientSecret
    )

    $body = @{
        audience      = $AuthenticationAudience
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = $ClientSecret
    }

    $response = Invoke-RestMethod `
        -Method Post `
        -Uri $AuthenticationUrl `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body $body

    if (
        $null -eq $response -or
        [string]::IsNullOrWhiteSpace([string] $response.access_token)
    ) {
        throw 'Authentication succeeded but no access token was returned.'
    }

    return [string] $response.access_token
}


function New-AuthorizationHeaders {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Token
    )

    return @{
        Authorization = "Bearer $Token"
        Accept        = 'application/json'
    }
}


function Get-HttpStatusCodeFromException {
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    if ($null -eq $ErrorRecord.Exception.Response) {
        return $null
    }

    try {
        return [int] $ErrorRecord.Exception.Response.StatusCode
    }
    catch {
        return $null
    }
}


function Wait-Until {
    param (
        [Parameter(Mandatory = $true)]
        [scriptblock] $Operation,

        [Parameter(Mandatory = $true)]
        [scriptblock] $IsComplete,

        [Parameter(Mandatory = $true)]
        [string] $Description,

        [Parameter(Mandatory = $true)]
        [int] $PollIntervalSeconds,

        [Parameter(Mandatory = $true)]
        [int] $TimeoutSeconds,

        [Parameter(Mandatory = $false)]
        [switch] $IgnoreNotFound
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $result = & $Operation

            if (& $IsComplete $result) {
                return $result
            }
        }
        catch {
            $statusCode = Get-HttpStatusCodeFromException $_

            if (-not ($IgnoreNotFound -and $statusCode -eq 404)) {
                throw
            }
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Timed out after $TimeoutSeconds seconds while waiting for $Description."
}


function New-HttpClient {
    param (
        [Parameter(Mandatory = $true)]
        [string] $AccessToken
    )

    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)

    $client.DefaultRequestHeaders.Authorization =
        New-Object System.Net.Http.Headers.AuthenticationHeaderValue(
            'Bearer',
            $AccessToken
        )

    return $client
}


function Get-IsMediaFromHttpResponse {
    param (
        [Parameter(Mandatory = $true)]
        [System.Net.Http.HttpResponseMessage] $Response
    )

    $contentDispositionValues = $null

    if (
        $Response.Content.Headers.TryGetValues(
            'Content-Disposition',
            [ref] $contentDispositionValues
        )
    ) {
        $headerValue = ($contentDispositionValues -join ';')
    }
    else {
        throw 'Chunk response did not contain a Content-Disposition header.'
    }

    if ($headerValue -match '(?i)\bIsMedia\s*=\s*"?([^";,\s]+)"?') {
        $value = $Matches[1]

        if ($value -ieq 'true') {
            return $true
        }

        if ($value -ieq 'false') {
            return $false
        }
    }

    throw "Unable to determine IsMedia from Content-Disposition header '$headerValue'."
}


function Send-Chunk {
    param (
        [Parameter(Mandatory = $true)]
        [System.Net.Http.HttpClient] $SourceClient,

        [Parameter(Mandatory = $true)]
        [System.Net.Http.HttpClient] $DestinationClient,

        [Parameter(Mandatory = $true)]
        [string] $SourceUri,

        [Parameter(Mandatory = $true)]
        [string] $DestinationBaseUri
    )

    $sourceRequest =
        New-Object System.Net.Http.HttpRequestMessage(
            [System.Net.Http.HttpMethod]::Get,
            $SourceUri
        )

    $sourceResponse = $null
    $destinationRequest = $null
    $destinationResponse = $null
    $sourceStream = $null
    $streamContent = $null

    try {
        $sourceResponse =
            $SourceClient.SendAsync(
                $sourceRequest,
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            ).GetAwaiter().GetResult()

        if (-not $sourceResponse.IsSuccessStatusCode) {
            $statusCode = [int] $sourceResponse.StatusCode
            $reason = $sourceResponse.ReasonPhrase

            throw "Chunk download failed with HTTP $statusCode $reason."
        }

        $isMedia =
            Get-IsMediaFromHttpResponse `
                -Response $sourceResponse

        $isMediaString =
            $isMedia.ToString().ToLowerInvariant()

        # Use concatenation rather than interpolation so PowerShell
        # does not interpret ?isMedia as part of the variable name.
        $destinationUri =
            $DestinationBaseUri + '?isMedia=' + $isMediaString

        $sourceStream =
            $sourceResponse.Content.ReadAsStreamAsync().GetAwaiter().GetResult()

        $streamContent =
            New-Object System.Net.Http.StreamContent($sourceStream)

        $streamContent.Headers.ContentType =
            New-Object System.Net.Http.Headers.MediaTypeHeaderValue(
                'application/octet-stream'
            )

        $destinationRequest =
            New-Object System.Net.Http.HttpRequestMessage(
                [System.Net.Http.HttpMethod]::Put,
                $destinationUri
            )

        $destinationRequest.Content = $streamContent

        $destinationResponse =
            $DestinationClient.SendAsync(
                $destinationRequest,
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            ).GetAwaiter().GetResult()

        if (-not $destinationResponse.IsSuccessStatusCode) {
            $statusCode = [int] $destinationResponse.StatusCode
            $reason = $destinationResponse.ReasonPhrase

            throw "Chunk upload failed with HTTP $statusCode $reason."
        }

        return $isMedia
    }
    finally {
        if ($null -ne $destinationResponse) {
            $destinationResponse.Dispose()
        }

        if ($null -ne $destinationRequest) {
            $destinationRequest.Dispose()
        }

        if ($null -ne $streamContent) {
            $streamContent.Dispose()
        }

        if ($null -ne $sourceStream) {
            $sourceStream.Dispose()
        }

        if ($null -ne $sourceResponse) {
            $sourceResponse.Dispose()
        }

        if ($null -ne $sourceRequest) {
            $sourceRequest.Dispose()
        }
    }
}


function Invoke-HttpPost {
    param (
        [Parameter(Mandatory = $true)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory = $true)]
        [string] $Uri
    )

    $request =
        New-Object System.Net.Http.HttpRequestMessage(
            [System.Net.Http.HttpMethod]::Post,
            $Uri
        )

    $response = $null

    try {
        # Explicitly send a zero-length body. Some Item Transfer
        # deployments reject a body-less POST with HTTP 411.
        $emptyBody = New-Object byte[] 0

        $request.Content =
            New-Object System.Net.Http.ByteArrayContent `
                -ArgumentList (, $emptyBody)

        $response =
            $Client.SendAsync($request).GetAwaiter().GetResult()

        if (-not $response.IsSuccessStatusCode) {
            $statusCode = [int] $response.StatusCode
            $reason = $response.ReasonPhrase

            $responseBody = ''

            try {
                $responseBody =
                    $response.Content.ReadAsStringAsync().
                    GetAwaiter().
                    GetResult()
            }
            catch {
                $responseBody = ''
            }

            if ([string]::IsNullOrWhiteSpace($responseBody)) {
                throw "POST '$Uri' failed with HTTP $statusCode $reason."
            }

            throw (
                "POST '$Uri' failed with HTTP $statusCode $reason. " +
                "Response: $responseBody"
            )
        }

        # The current API returns a Location header pointing to the
        # destination blob resource. We do not use it to infer an
        # Item Transfer ID.
        if ($null -ne $response.Headers.Location) {
            return $response.Headers.Location.ToString()
        }

        return $null
    }
    finally {
        if ($null -ne $response) {
            $response.Dispose()
        }

        if ($null -ne $request) {
            $request.Dispose()
        }
    }
}


function Remove-DestinationBlob {
    param (
        [Parameter(Mandatory = $true)]
        [string] $DestinationHost,

        [Parameter(Mandatory = $true)]
        [hashtable] $Headers,

        [Parameter(Mandatory = $true)]
        [string] $BlobName
    )

    $encodedBlobName =
        [Uri]::EscapeDataString($BlobName)

    $uri =
        "$DestinationHost$ItemTransferApiPath/sources/blobs/$encodedBlobName"

    try {
        Invoke-RestMethod `
            -Method Delete `
            -Uri $uri `
            -Headers $Headers `
            | Out-Null
    }
    catch {
        Write-Warning (
            "Unable to delete destination blob '$BlobName': " +
            $_.Exception.Message
        )
    }
}


function Test-Manifest {
    param (
        [Parameter(Mandatory = $true)]
        [object] $Manifest
    )

    if (
        $null -eq $Manifest.Database -or
        [string]::IsNullOrWhiteSpace([string] $Manifest.Database)
    ) {
        throw "Manifest must define 'Database'."
    }

    if (
        $null -eq $Manifest.DataTrees -or
        @($Manifest.DataTrees).Count -eq 0
    ) {
        throw "Manifest must contain at least one entry in 'DataTrees'."
    }

    $validScopes = @(
        'SingleItem',
        'ItemAndDescendants'
    )

    $validMergeStrategies = @(
        'OverrideExistingItem',
        'KeepExistingItem',
        'OverrideExistingTree'
    )

    foreach ($dataTree in @($Manifest.DataTrees)) {
        if (
            [string]::IsNullOrWhiteSpace(
                [string] $dataTree.ItemPath
            )
        ) {
            throw "Every DataTrees entry must define 'ItemPath'."
        }

        if ($dataTree.Scope -notin $validScopes) {
            throw (
                "Invalid Scope '$($dataTree.Scope)' for " +
                "'$($dataTree.ItemPath)'."
            )
        }

        if (
            $dataTree.MergeStrategy -notin
            $validMergeStrategies
        ) {
            throw (
                "Invalid MergeStrategy " +
                "'$($dataTree.MergeStrategy)' for " +
                "'$($dataTree.ItemPath)'."
            )
        }
    }
}


function Write-TransferPlan {
    param (
        [Parameter(Mandatory = $true)]
        [object] $Manifest,

        [Parameter(Mandatory = $true)]
        [string] $SourceEnvironment,

        [Parameter(Mandatory = $true)]
        [string] $DestinationEnvironment,

        [Parameter(Mandatory = $true)]
        [string] $Mode
    )

    Write-Host ''
    Write-Host 'SitecoreAI Content Refresh'
    Write-Host ''
    Write-Host "Source:      $SourceEnvironment"
    Write-Host "Destination: $DestinationEnvironment"
    Write-Host "Database:    $($Manifest.Database)"
    Write-Host "Mode:        $Mode"
    Write-Host ''
    Write-Host 'Included item trees:'

    foreach ($dataTree in @($Manifest.DataTrees)) {
        Write-Host ''
        Write-Host "  ItemPath:      $($dataTree.ItemPath)"
        Write-Host "  Scope:         $($dataTree.Scope)"
        Write-Host "  MergeStrategy: $($dataTree.MergeStrategy)"
    }

    Write-Host ''
}


#
# Validate source and destination.
#

if ($SourceEnvironment -eq $DestinationEnvironment) {
    throw (
        'Source and destination environments cannot be the same. ' +
        "Both were '$SourceEnvironment'."
    )
}

# ValidateSet prevents PROD from being supplied as the destination.
# Keep the explicit guard so the safety requirement remains clear
# if parameter validation is modified later.
if ($DestinationEnvironment -eq 'PROD') {
    throw (
        'PROD can never be used as the destination ' +
        'of a content refresh.'
    )
}


#
# Load and validate the manifest.
#

Write-Step "Loading manifest: $ManifestPath"

$manifestJson =
    Get-Content `
        -Path $ManifestPath `
        -Raw

$manifest =
    $manifestJson | ConvertFrom-Json

Test-Manifest `
    -Manifest $manifest

Write-TransferPlan `
    -Manifest $manifest `
    -SourceEnvironment $SourceEnvironment `
    -DestinationEnvironment $DestinationEnvironment `
    -Mode $Mode


#
# Preview stops before credentials are loaded or APIs are called.
#

if ($Mode -eq 'Preview') {
    Write-Host 'PREVIEW ONLY. No Sitecore content was modified.'
    exit 0
}


#
# Execute-mode confirmation.
#

if ($Confirm -cne 'REFRESH') {
    throw (
        'Execution mode requires confirmation. ' +
        'Type REFRESH exactly.'
    )
}


#
# Load environment-specific configuration.
#

$sourcePrefix =
    "SITECORE_$SourceEnvironment"

$sourceHost =
    Normalize-HostUrl (
        Get-RequiredEnvironmentVariable `
            "${sourcePrefix}_HOST"
    )

$sourceClientId =
    Get-RequiredEnvironmentVariable `
        "${sourcePrefix}_CLIENT_ID"

$sourceClientSecret =
    Get-RequiredEnvironmentVariable `
        "${sourcePrefix}_CLIENT_SECRET"


$destinationPrefix =
    "SITECORE_$DestinationEnvironment"

$destinationHost =
    Normalize-HostUrl (
        Get-RequiredEnvironmentVariable `
            "${destinationPrefix}_HOST"
    )

$destinationClientId =
    Get-RequiredEnvironmentVariable `
        "${destinationPrefix}_CLIENT_ID"

$destinationClientSecret =
    Get-RequiredEnvironmentVariable `
        "${destinationPrefix}_CLIENT_SECRET"


if ($sourceHost -eq $destinationHost) {
    throw (
        'Source and destination hosts are identical. ' +
        'Transfer aborted.'
    )
}


#
# Authenticate.
#

Write-Step "Authenticating to $SourceEnvironment"

$sourceToken =
    Get-SitecoreAccessToken `
        -ClientId $sourceClientId `
        -ClientSecret $sourceClientSecret

Write-Step "Authenticating to $DestinationEnvironment"

$destinationToken =
    Get-SitecoreAccessToken `
        -ClientId $destinationClientId `
        -ClientSecret $destinationClientSecret

$sourceHeaders =
    New-AuthorizationHeaders `
        -Token $sourceToken

$destinationHeaders =
    New-AuthorizationHeaders `
        -Token $destinationToken

$sourceHttpClient = $null
$destinationHttpClient = $null


try {
    $sourceHttpClient =
        New-HttpClient `
            -AccessToken $sourceToken

    $destinationHttpClient =
        New-HttpClient `
            -AccessToken $destinationToken


    #
    # Create the Content Transfer in the source environment.
    #

    $transferId =
        [Guid]::NewGuid().ToString()

    Write-Step (
        "Creating Content Transfer $transferId " +
        "in $SourceEnvironment"
    )

    $dataTrees = @()

    foreach ($dataTree in @($manifest.DataTrees)) {
        $dataTrees += @{
            ItemPath      = [string] $dataTree.ItemPath
            Scope         = [string] $dataTree.Scope
            MergeStrategy = [string] $dataTree.MergeStrategy
        }
    }

    $createTransferBody = @{
        TransferId    = $transferId
        Configuration = @{
            Database  = [string] $manifest.Database
            DataTrees = $dataTrees
        }
    } | ConvertTo-Json -Depth 10

    $createTransferUri =
        "$sourceHost$ContentTransferApiPath/transfers"

    Invoke-RestMethod `
        -Method Post `
        -Uri $createTransferUri `
        -Headers $sourceHeaders `
        -ContentType 'application/json' `
        -Body $createTransferBody `
        | Out-Null


    #
    # Wait for source chunk generation.
    #

    Write-Step (
        "Waiting for $SourceEnvironment to generate transfer chunks"
    )

    $statusUri =
        "$sourceHost$ContentTransferApiPath/transfers/$transferId/status"

    $transferStatus =
        Wait-Until `
            -Description 'Content Transfer generation' `
            -PollIntervalSeconds $PollIntervalSeconds `
            -TimeoutSeconds $TimeoutSeconds `
            -IgnoreNotFound `
            -Operation {
                Invoke-RestMethod `
                    -Method Get `
                    -Uri $statusUri `
                    -Headers $sourceHeaders
            } `
            -IsComplete {
                param($status)

                if ($status.State -eq 'Failed') {
                    throw (
                        "Content Transfer '$transferId' " +
                        "failed in $SourceEnvironment."
                    )
                }

                return ($status.State -eq 'Completed')
            }

    $chunkSets =
        @($transferStatus.ChunkSetsMetadata)

    if ($chunkSets.Count -eq 0) {
        throw (
            "Content Transfer '$transferId' completed " +
            'without any chunk sets.'
        )
    }

    Write-Host "Generated $($chunkSets.Count) chunk set(s)."


    #
    # Transfer chunks from source to destination.
    #

    $raifFiles =
        New-Object 'System.Collections.Generic.List[string]'

    foreach ($chunkSet in $chunkSets) {
        $chunkSetId =
            [string] $chunkSet.ChunkSetId

        $chunkCount =
            [int] $chunkSet.ChunkCount

        Write-Step (
            "Transferring chunk set $chunkSetId " +
            "($chunkCount chunk(s))"
        )

        for (
            $chunkId = 0;
            $chunkId -lt $chunkCount;
            $chunkId++
        ) {
            Write-Host "  Chunk $($chunkId + 1) of $chunkCount"

            $sourceChunkUri =
                "$sourceHost$ContentTransferApiPath/" +
                "transfers/$transferId/" +
                "chunksets/$chunkSetId/" +
                "chunks/$chunkId"

            $destinationChunkUri =
                "$destinationHost$ContentTransferApiPath/" +
                "transfers/$transferId/" +
                "chunksets/$chunkSetId/" +
                "chunks/$chunkId"

            $isMedia =
                Send-Chunk `
                    -SourceClient $sourceHttpClient `
                    -DestinationClient $destinationHttpClient `
                    -SourceUri $sourceChunkUri `
                    -DestinationBaseUri $destinationChunkUri

            Write-Host "    IsMedia: $isMedia"
        }


        #
        # Complete the chunk set and generate the destination RAIF.
        #

        Write-Host "  Completing chunk set $chunkSetId"

        $completeUri =
            "$destinationHost$ContentTransferApiPath/" +
            "transfers/$transferId/" +
            "chunksets/$chunkSetId/complete"

        $completeResponse =
            Invoke-RestMethod `
                -Method Post `
                -Uri $completeUri `
                -Headers $destinationHeaders `
                -ContentType 'application/json' `
                -Body '{}'

        if (
            $null -eq $completeResponse -or
            [string]::IsNullOrWhiteSpace(
                [string] $completeResponse.ContentTransferFileName
            )
        ) {
            throw (
                'Destination did not return a RAIF filename ' +
                "for chunk set '$chunkSetId'."
            )
        }

        $raifFile =
            [string] $completeResponse.ContentTransferFileName

        $raifFiles.Add($raifFile)

        Write-Host "  Created $raifFile"
    }


    #
    # Clean up source-side Content Transfer resources.
    #

    Write-Step (
        "Cleaning up $SourceEnvironment Content Transfer resources"
    )

    $deleteSourceTransferUri =
        "$sourceHost$ContentTransferApiPath/transfers/$transferId"

    try {
        Invoke-RestMethod `
            -Method Delete `
            -Uri $deleteSourceTransferUri `
            -Headers $sourceHeaders `
            | Out-Null
    }
    catch {
        Write-Warning (
            'Unable to clean up source Content Transfer ' +
            "'$transferId': $($_.Exception.Message)"
        )
    }


    #
    # Consume each RAIF in the destination environment.
    #

    foreach ($raifFile in $raifFiles) {
        Write-Step (
            "Loading $raifFile into $DestinationEnvironment"
        )

        $encodedBlobName =
            [Uri]::EscapeDataString($raifFile)

        $encodedDatabase =
            [Uri]::EscapeDataString(
                [string] $manifest.Database
            )

        $blobStatusUri =
            "$destinationHost$ItemTransferApiPath/" +
            "sources/blobs/$encodedBlobName"


        #
        # Verify the RAIF exists before asking Item Transfer
        # to consume it.
        #

        $blobStatus =
            Invoke-RestMethod `
                -Method Get `
                -Uri $blobStatusUri `
                -Headers $destinationHeaders

        Write-Host (
            "  Initial blob state: $($blobStatus.BlobState)"
        )

        if ($blobStatus.BlobState -ne 'Uploaded') {
            throw (
                "RAIF '$raifFile' was expected to be " +
                "in 'Uploaded' state before consumption, " +
                "but was '$($blobStatus.BlobState)'."
            )
        }


        #
        # Start Item Transfer.
        #
        # The Location header returned by the current API points
        # to the blob resource rather than a transfer-status
        # resource, so we do not attempt to derive a transfer ID.
        #

        $consumeUri =
            "$destinationHost$ItemTransferApiPath/" +
            "transfers/databases/$encodedDatabase/" +
            "sources?blobName=$encodedBlobName"

        $location =
            Invoke-HttpPost `
                -Client $destinationHttpClient `
                -Uri $consumeUri

        Write-Host '  Item Transfer submitted.'

        if (-not [string]::IsNullOrWhiteSpace($location)) {
            Write-Host "  Location: $location"
        }


        #
        # Poll the destination blob until Item Transfer reaches
        # a terminal state.
        #

        Write-Host '  Waiting for Item Transfer to complete...'

        $finalBlobStatus =
            Wait-Until `
                -Description "Item Transfer for '$raifFile'" `
                -PollIntervalSeconds $PollIntervalSeconds `
                -TimeoutSeconds $TimeoutSeconds `
                -Operation {
                    Invoke-RestMethod `
                        -Method Get `
                        -Uri $blobStatusUri `
                        -Headers $destinationHeaders
                } `
                -IsComplete {
                    param($status)

                    $state =
                        [string] $status.BlobState

                    Write-Host "    BlobState: $state"

                    if ($state -eq 'TransferredWithErrors') {
                        $message =
                            "RAIF '$raifFile' was transferred " +
                            'with errors.'

                        if (
                            $null -ne $status.Error -and
                            -not [string]::IsNullOrWhiteSpace(
                                [string] $status.Error
                            )
                        ) {
                            $message += (
                                " Error: $($status.Error)"
                            )
                        }

                        throw $message
                    }

                    return ($state -eq 'Transferred')
                }


        #
        # Success.
        #

        Write-Host (
            "  Final blob state: $($finalBlobStatus.BlobState)"
        )

        Write-Host '  Transfer completed successfully.'


        #
        # Delete the consumed RAIF.
        #

        Remove-DestinationBlob `
            -DestinationHost $destinationHost `
            -Headers $destinationHeaders `
            -BlobName $raifFile
    }


    #
    # Final summary.
    #

    Write-Step 'Content refresh completed successfully'

    Write-Host ''
    Write-Host "Content Transfer ID: $transferId"
    Write-Host "Source:              $SourceEnvironment"
    Write-Host "Destination:         $DestinationEnvironment"
    Write-Host "Database:            $($manifest.Database)"
    Write-Host "Item trees:          $(@($manifest.DataTrees).Count)"
    Write-Host "RAIF files:          $($raifFiles.Count)"
}
finally {
    if ($null -ne $sourceHttpClient) {
        $sourceHttpClient.Dispose()
    }

    if ($null -ne $destinationHttpClient) {
        $destinationHttpClient.Dispose()
    }
}