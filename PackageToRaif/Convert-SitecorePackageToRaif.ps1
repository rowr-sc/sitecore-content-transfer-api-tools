#requires -Version 5.1
<#
.SYNOPSIS
Converts a Sitecore XM/XP Package Designer ZIP package to a Sitecore RAIF file.

.DESCRIPTION
Reads Sitecore package item/version XML and blobs, aggregates all versions of each
item, validates the package, and writes valid items through Sitecore's official
Sitecore.XmCloud.Data.ItemsTransfer NuGet package.

Compatible with Windows PowerShell 5.1 and PowerShell 7+.
Dependencies are downloaded from nuget.org into a script-local ./lib cache.
No Sitecore binaries are redistributed with this script.

This is an initial implementation intended for validation against real XM/XP
packages and SitecoreAI Item Transfer imports.

.PARAMETER PackagePath
Path to a Sitecore Package Designer ZIP package. If only a filename is
specified, the script looks for it in the same directory as this script.

.PARAMETER OutputPath
Optional path of the RAIF file to create. If omitted, the output is created
beside the input package using the same base filename and a .raif extension.

.PARAMETER ItemTransferVersion
Optional Sitecore.XmCloud.Data.ItemsTransfer version. If omitted, the latest
stable listed version is resolved from nuget.org.

.PARAMETER AllowPartial
If specified, valid items are written when item-level validation failures occur.
Without this switch, interactive execution prompts before writing a valid subset.

.EXAMPLE
./Convert-SitecorePackageToRaif.ps1 -PackagePath Media.zip

.EXAMPLE
./Convert-SitecorePackageToRaif.ps1 -PackagePath ./Package.zip -OutputPath ./Package.raif `
    -ItemTransferVersion 1.8.44 -AllowPartial

.EXAMPLE
./Convert-SitecorePackageToRaif.ps1 -PackagePath ./Package.zip -Overwrite
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $PackagePath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ItemTransferVersion,

    [Parameter()]
    [switch] $AllowPartial,

    [Parameter()]
    [switch] $Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Windows PowerShell 5.1 may otherwise negotiate an obsolete TLS version when
# contacting nuget.org. Preserve existing protocols and add TLS 1.2.
if ([Enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls12') {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$script:ItemsTransferPackageId = 'Sitecore.XmCloud.Data.ItemsTransfer'
$script:NuGetServiceIndex = 'https://api.nuget.org/v3/index.json'
$script:LibRoot = Join-Path $PSScriptRoot 'lib'
$script:WorkRoot = $null

function Write-Section {
    param([string] $Text)
    Write-Host ''
    Write-Host $Text
    Write-Host ('-' * $Text.Length)
}


function Get-RelativePath {
    param(
        [Parameter(Mandatory)][string] $BasePath,
        [Parameter(Mandatory)][string] $Path
    )

    $baseFull = [IO.Path]::GetFullPath($BasePath)
    if (-not $baseFull.EndsWith([IO.Path]::DirectorySeparatorChar.ToString())) {
        $baseFull += [IO.Path]::DirectorySeparatorChar
    }

    $pathFull = [IO.Path]::GetFullPath($Path)
    $baseUri = New-Object System.Uri($baseFull)
    $pathUri = New-Object System.Uri($pathFull)
    $relativeUri = $baseUri.MakeRelativeUri($pathUri)

    return [Uri]::UnescapeDataString($relativeUri.ToString()).Replace(
        '/',
        [IO.Path]::DirectorySeparatorChar
    )
}

function ConvertTo-NormalizedGuid {
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    $trimmed = $Value.Trim().Trim('{', '}')
    return [Guid]::Parse($trimmed)
}

function Get-NuGetResources {
    $index = Invoke-RestMethod -Uri $script:NuGetServiceIndex

    $flat = $index.resources |
        Where-Object { $_.'@type' -eq 'PackageBaseAddress/3.0.0' } |
        Select-Object -First 1

    $registration = $index.resources |
        Where-Object { $_.'@type' -match '^RegistrationsBaseUrl/3\.6\.0' } |
        Select-Object -First 1

    if (-not $registration) {
        $registration = $index.resources |
            Where-Object { $_.'@type' -match '^RegistrationsBaseUrl' } |
            Select-Object -First 1
    }

    if (-not $flat -or -not $registration) {
        throw 'Unable to discover required NuGet V3 resources.'
    }

    [pscustomobject]@{
        FlatContainer = $flat.'@id'.TrimEnd('/')
        Registration  = $registration.'@id'.TrimEnd('/')
    }
}

function Get-LatestListedStableVersion {
    param(
        [Parameter(Mandatory)]
        [string] $PackageId,

        [Parameter(Mandatory)]
        $NuGetResources
    )

    $id = $PackageId.ToLowerInvariant()
    $registration = Invoke-RestMethod -Uri "$($NuGetResources.Registration)/$id/index.json"

    $leaves = foreach ($page in $registration.items) {
        if ($page.items) {
            $page.items
        }
        elseif ($page.'@id') {
            (Invoke-RestMethod -Uri $page.'@id').items
        }
    }

    $versions = foreach ($leaf in $leaves) {
        $entry = $leaf.catalogEntry
        if ($entry -is [string]) {
            $entry = Invoke-RestMethod -Uri $entry
        }

        $listed = if ($null -eq $entry.listed) { $true } else { [bool]$entry.listed }
        if (-not $listed) { continue }

        $version = [string]$entry.version
        if ($version -match '-') { continue }

        try {
            [Version]$version
        }
        catch {
            # Ignore versions that cannot be interpreted as stable numeric versions.
        }
    }

    if (-not $versions) {
        throw "No listed stable versions found for NuGet package '$PackageId'."
    }

    return ($versions | Sort-Object -Descending | Select-Object -First 1).ToString()
}

function Get-MinimumVersionFromRange {
    param([Parameter(Mandatory)][string] $VersionSpec)

    $value = $VersionSpec.Trim()

    # Exact version.
    if ($value -notmatch '^[\[\(]') {
        return $value
    }

    # NuGet range: [1.2.3, ), [1.2.3,2.0), etc.
    $inner = $value.Trim('[', ']', '(', ')')
    $parts = $inner.Split(',', 2)
    if ($parts[0].Trim()) {
        return $parts[0].Trim()
    }

    throw "Cannot resolve dependency range '$VersionSpec' because it has no minimum version."
}

function Get-NuGetPackage {
    param(
        [Parameter(Mandatory)][string] $PackageId,
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)] $NuGetResources,
        [Parameter(Mandatory)][hashtable] $Resolved
    )

    $key = "$($PackageId.ToLowerInvariant())@$($Version.ToLowerInvariant())"
    if ($Resolved.ContainsKey($key)) {
        return
    }

    $Resolved[$key] = $true

    $packageRoot = Join-Path $script:LibRoot $PackageId
    $versionRoot = Join-Path $packageRoot $Version
    $marker = Join-Path $versionRoot '.complete'

    if (-not (Test-Path $marker)) {
        Write-Verbose "Downloading $PackageId $Version..."

        New-Item -ItemType Directory -Path $versionRoot -Force | Out-Null
        $lowerId = $PackageId.ToLowerInvariant()
        $lowerVersion = $Version.ToLowerInvariant()
        $nupkg = Join-Path $versionRoot "$lowerId.$lowerVersion.nupkg"

        $uri = "$($NuGetResources.FlatContainer)/$lowerId/$lowerVersion/$lowerId.$lowerVersion.nupkg"

        Write-Progress -Activity 'Initializing Sitecore ItemsTransfer' `
            -Status "Downloading $PackageId $Version" `
            -PercentComplete 25

        $webClient = New-Object System.Net.WebClient
        try { $webClient.DownloadFile($uri, $nupkg) }
        finally { $webClient.Dispose() }

        Write-Progress -Activity 'Initializing Sitecore ItemsTransfer' `
            -Status "Extracting $PackageId $Version" `
            -PercentComplete 50

        $extract = Join-Path $versionRoot 'package'
        if (Test-Path $extract) {
            Remove-Item $extract -Recurse -Force
        }

        # A .nupkg is a ZIP archive, but Windows PowerShell 5.1 Expand-Archive
        # rejects it because the extension is not .zip. Use the .NET ZIP API.
        [System.IO.Compression.ZipFile]::ExtractToDirectory(
            $nupkg,
            $extract
        )

        New-Item -ItemType File -Path $marker -Force | Out-Null
    }

    $nuspec = Get-ChildItem -Path (Join-Path $versionRoot 'package') -Filter '*.nuspec' |
        Select-Object -First 1

    if (-not $nuspec) {
        throw "NuGet package '$PackageId' $Version contains no .nuspec manifest."
    }

    [xml]$manifest = Get-Content -LiteralPath $nuspec.FullName -Raw

    # NuGet manifests may have:
    #   <dependencies><group ...><dependency ... /></group></dependencies>
    #   <dependencies><dependency ... /></dependencies>
    #   <dependencies><group ... /></dependencies>   (no dependencies)
    # or no <dependencies> element at all.
    #
    # Accessing a missing XML property under Set-StrictMode throws, so use
    # SelectNodes rather than PowerShell's dynamic XML properties.
    $dependencies = @()
    $dependencyRoot = $manifest.SelectSingleNode(
        "/*[local-name()='package']/*[local-name()='metadata']/*[local-name()='dependencies']"
    )

    if ($null -ne $dependencyRoot) {
        $groups = @($dependencyRoot.SelectNodes("./*[local-name()='group']"))

        if ($groups.Count -gt 0) {
            # Prefer netstandard2.0, then any netstandard group, then an
            # explicit .NET Framework group, then the first available group.
            $group = $groups |
                Where-Object {
                    $_.HasAttribute('targetFramework') -and
                    $_.GetAttribute('targetFramework') -match 'netstandard2\.0|\.NETStandard2\.0'
                } |
                Select-Object -First 1

            if (-not $group) {
                $group = $groups |
                    Where-Object {
                        $_.HasAttribute('targetFramework') -and
                        $_.GetAttribute('targetFramework') -match 'netstandard'
                    } |
                    Select-Object -First 1
            }

            if (-not $group) {
                $group = $groups |
                    Where-Object {
                        $_.HasAttribute('targetFramework') -and
                        $_.GetAttribute('targetFramework') -match 'net4'
                    } |
                    Select-Object -First 1
            }

            if (-not $group) {
                $group = $groups | Select-Object -First 1
            }

            if ($group) {
                $dependencies = @($group.SelectNodes("./*[local-name()='dependency']"))
            }
        }
        else {
            $dependencies = @($dependencyRoot.SelectNodes("./*[local-name()='dependency']"))
        }
    }

    foreach ($dependency in $dependencies) {
        $dependencyId = $dependency.GetAttribute('id')
        $dependencyVersionSpec = $dependency.GetAttribute('version')

        if ([string]::IsNullOrWhiteSpace($dependencyId) -or
            [string]::IsNullOrWhiteSpace($dependencyVersionSpec)) {
            continue
        }

        $dependencyVersion = Get-MinimumVersionFromRange $dependencyVersionSpec

        Get-NuGetPackage `
            -PackageId $dependencyId `
            -Version $dependencyVersion `
            -NuGetResources $NuGetResources `
            -Resolved $Resolved
    }
}

function Import-NuGetAssemblies {
    param([Parameter(Mandatory)][hashtable] $Resolved)

    $dlls = foreach ($key in $Resolved.Keys) {
        $parts = $key.Split('@', 2)
        $packageIdLower = $parts[0]
        $version = $parts[1]

        $packageDirectory = Get-ChildItem $script:LibRoot -Directory |
            Where-Object { $_.Name.ToLowerInvariant() -eq $packageIdLower } |
            Select-Object -First 1

        if (-not $packageDirectory) { continue }

        $lib = Join-Path $packageDirectory.FullName "$version/package/lib"
        if (-not (Test-Path $lib)) { continue }

        $frameworkDirs = Get-ChildItem $lib -Directory -ErrorAction SilentlyContinue
        $selected = $frameworkDirs |
            Where-Object { $_.Name -eq 'netstandard2.0' } |
            Select-Object -First 1

        if (-not $selected) {
            $selected = $frameworkDirs |
                Where-Object { $_.Name -match '^netstandard' } |
                Sort-Object Name -Descending |
                Select-Object -First 1
        }

        if (-not $selected) {
            $selected = $frameworkDirs |
                Where-Object { $_.Name -match '^net4[0-9]+' } |
                Sort-Object Name -Descending |
                Select-Object -First 1
        }

        if ($selected) {
            Get-ChildItem $selected.FullName -Filter '*.dll' | ForEach-Object {
                [pscustomobject]@{
                    File = $_
                    Package = $packageDirectory.Name
                    Version = $version
                    Framework = $selected.Name
                }
            }
        }
    }

    $dlls = @($dlls | Sort-Object @{
        Expression = { if ($_.File.Name -eq 'Sitecore.Data.ItemsTransfer.dll') { 1 } else { 0 } }
    }, @{ Expression = { $_.File.Name } })

    Write-Verbose ("Assemblies selected: {0}" -f $dlls.Count)

    $loadFailures = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $dlls) {
        $dll = $entry.File
        try {
            [System.Reflection.Assembly]::LoadFrom($dll.FullName) | Out-Null
            Write-Verbose ("  OK   {0}  [{1} {2} / {3}]" -f `
                $dll.Name, $entry.Package, $entry.Version, $entry.Framework)
        }
        catch {
            $exception = $_.Exception
            $messages = [System.Collections.Generic.List[string]]::new()
            $messages.Add($exception.Message)

            $inner = $exception.InnerException
            while ($null -ne $inner) {
                $messages.Add("Inner: " + $inner.Message)
                $inner = $inner.InnerException
            }

            if ($exception -is [System.Reflection.ReflectionTypeLoadException]) {
                foreach ($loaderException in $exception.LoaderExceptions) {
                    if ($null -ne $loaderException) {
                        $messages.Add("Loader: " + $loaderException.Message)
                    }
                }
            }

            Write-Host ("  FAIL {0}  [{1} {2} / {3}]" -f `
                $dll.Name, $entry.Package, $entry.Version, $entry.Framework) `
                -ForegroundColor Red

            foreach ($message in $messages) {
                Write-Host ("       {0}" -f $message) -ForegroundColor Red
            }

            $loadFailures.Add([pscustomobject]@{
                Assembly = $dll.Name
                Package = $entry.Package
                Version = $entry.Version
                Framework = $entry.Framework
                Path = $dll.FullName
                Messages = @($messages)
            })
        }
    }

    # Do not rely on Type.GetType here: assembly identity/version differences
    # under Windows PowerShell 5.1 can make that return null even after a
    # successful LoadFrom. Inspect the AppDomain directly.
    $itemsTransferAssembly = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'Sitecore.Data.ItemsTransfer' } |
        Select-Object -First 1

    if (-not $itemsTransferAssembly) {
        Write-Host ''
        Write-Host 'ItemsTransfer assembly was not loaded.' -ForegroundColor Red

        if ($loadFailures.Count -gt 0) {
            Write-Host ("Assembly load failures: {0}" -f $loadFailures.Count) -ForegroundColor Red
        }

        throw 'Sitecore.Data.ItemsTransfer could not be loaded. See the assembly diagnostics above.'
    }

    Write-Verbose ("ItemsTransfer loaded: {0}" -f $itemsTransferAssembly.FullName)

    # Force type enumeration now. This catches dependencies that allow the
    # assembly itself to load but prevent its public types from resolving.
    try {
        $null = $itemsTransferAssembly.GetTypes()
        Write-Verbose 'ItemsTransfer types: resolved successfully'
    }
    catch [System.Reflection.ReflectionTypeLoadException] {
        Write-Host 'ItemsTransfer type resolution failed:' -ForegroundColor Red
        foreach ($loaderException in $_.Exception.LoaderExceptions) {
            if ($null -ne $loaderException) {
                Write-Host ("  {0}" -f $loaderException.Message) -ForegroundColor Red
            }
        }
        throw 'Sitecore.Data.ItemsTransfer loaded, but one or more of its types could not be resolved.'
    }

    if ($loadFailures.Count -gt 0) {
        Write-Verbose ("NOTE: {0} non-fatal assembly load failure(s) occurred before ItemsTransfer loaded." -f `
            $loadFailures.Count)
        Write-Verbose 'If conversion later fails, rerun with -Verbose to see assembly diagnostics.'
    }
}

function Expand-SitecorePackage {
    param([Parameter(Mandatory)][string] $Path)

    $outer = Join-Path $script:WorkRoot 'outer'
    $inner = Join-Path $script:WorkRoot 'package'
    New-Item -ItemType Directory -Path $outer, $inner -Force | Out-Null

    Expand-Archive -LiteralPath $Path -DestinationPath $outer -Force

    $embedded = Join-Path $outer 'package.zip'
    if (Test-Path $embedded) {
        Expand-Archive -LiteralPath $embedded -DestinationPath $inner -Force
        return $inner
    }

    # Some package ZIPs may already be the inner Sitecore package.
    if (Test-Path (Join-Path $outer 'items')) {
        return $outer
    }

    throw "The ZIP does not contain package.zip or an items/ directory and does not appear to be a Sitecore package."
}

function Get-FieldStorageMap {
    param([Parameter(Mandatory)][string] $PropertiesPath)

    $map = @{}

    if (-not (Test-Path -LiteralPath $PropertiesPath)) {
        return $map
    }

    foreach ($line in Get-Content -LiteralPath $PropertiesPath) {
        if ($line -notmatch '^fieldproperties=(.*)$') { continue }

        foreach ($pair in $Matches[1].Split('|', [StringSplitOptions]::RemoveEmptyEntries)) {
            $parts = $pair.Split(':', 2)
            if ($parts.Count -ne 2) { continue }

            try {
                $id = (ConvertTo-NormalizedGuid $parts[0]).ToString('D')
                $map[$id] = $parts[1]
            }
            catch {
                # Bad metadata is reported later when a field needs it.
            }
        }
    }

    return $map
}

function Get-SitecorePackageModel {
    param([Parameter(Mandatory)][string] $PackageRoot)

    $itemsRoot = Join-Path $PackageRoot 'items'
    if (-not (Test-Path $itemsRoot)) {
        throw 'The Sitecore package contains no items directory.'
    }

    $records = @()

    foreach ($xmlFile in Get-ChildItem -Path $itemsRoot -Recurse -File -Filter 'xml') {
        try {
            [xml]$xml = Get-Content -LiteralPath $xmlFile.FullName -Raw
            $node = $xml.item

            $id = ConvertTo-NormalizedGuid ([string]$node.id)
            $relative = Get-RelativePath -BasePath $itemsRoot -Path $xmlFile.FullName
            $relativeParts = $relative -split '[\\/]'

            if ($relativeParts.Count -lt 5) {
                throw "Unexpected item path '$relative'."
            }

            $database = $relativeParts[0]
            $language = [string]$node.language
            $version = [int]$node.version

            # properties/items mirrors items exactly.
            $propertiesPath = Join-Path $PackageRoot ('properties/items/' + $relative)
            $storageMap = Get-FieldStorageMap $propertiesPath

            $fields = foreach ($field in @($node.fields.field)) {
                $fieldId = ConvertTo-NormalizedGuid ([string]$field.tfid)
                $fieldKey = [string]$field.key
                $fieldType = [string]$field.type
                $value = if ($null -eq $field.content) { '' } else { [string]$field.content }

                $storageKey = $fieldId.ToString('D')
                $storage = if ($storageMap.ContainsKey($storageKey)) {
                    [string]$storageMap[$storageKey]
                }
                else {
                    $null
                }

                [pscustomobject]@{
                    Id       = $fieldId
                    Key      = $fieldKey
                    Type     = $fieldType
                    Value    = $value
                    Storage  = $storage
                    Language = $language
                    Version  = $version
                }
            }

            $itemPathParts = $relativeParts[1..($relativeParts.Count - 5)]
            $displayPath = '/' + (($itemPathParts | ForEach-Object {
                if ($_ -match '^\{[0-9A-Fa-f-]+\}$') { return $null }
                $_
            } | Where-Object { $_ }) -join '/')

            $records += [pscustomobject]@{
                Id         = $id
                Name       = [string]$node.name
                ParentId   = ConvertTo-NormalizedGuid ([string]$node.parentid)
                TemplateId = ConvertTo-NormalizedGuid ([string]$node.tid)
                MasterId   = ConvertTo-NormalizedGuid ([string]$node.mid)
                Database   = $database
                Language   = $language
                Version    = $version
                Created    = [string]$node.created
                Path       = $displayPath
                SourceFile = $xmlFile.FullName
                Fields     = @($fields)
            }
        }
        catch {
            $records += [pscustomobject]@{
                Id         = $null
                Name       = $xmlFile.Directory.Name
                ParentId   = $null
                TemplateId = $null
                MasterId   = $null
                Database   = $null
                Language   = $null
                Version    = $null
                Created    = $null
                Path       = $xmlFile.FullName
                SourceFile = $xmlFile.FullName
                Fields     = @()
                ParseError = $_.Exception.Message
            }
        }
    }

    return @($records)
}

function New-ValidationResult {
    param(
        $Item,
        [string] $Code,
        [string] $Message,
        [string] $Source = $null
    )

    [pscustomobject]@{
        ItemId  = $Item.Id
        Path    = $Item.Path
        Code    = $Code
        Message = $Message
        Source  = $Source
    }
}

function Merge-AndValidateItems {
    param(
        [Parameter(Mandatory)] [array] $Records,
        [Parameter(Mandatory)] [string] $PackageRoot
    )

    $errors = [System.Collections.Generic.List[object]]::new()
    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($bad in @($Records | Where-Object { $_.PSObject.Properties.Name -contains 'ParseError' })) {
        $errors.Add([pscustomobject]@{
            ItemId  = $null
            Path    = $bad.Path
            Code    = 'PARSE_ERROR'
            Message = $bad.ParseError
            Source  = $bad.SourceFile
        })
    }

    $goodRecords = @($Records | Where-Object { -not ($_.PSObject.Properties.Name -contains 'ParseError') })

    foreach ($group in ($goodRecords | Group-Object { $_.Id.ToString('D') })) {
        $versions = @($group.Group | Sort-Object Language, Version)
        $first = $versions[0]

        $item = [pscustomobject]@{
            Id         = $first.Id
            Name       = $first.Name
            ParentId   = $first.ParentId
            TemplateId = $first.TemplateId
            MasterId   = $first.MasterId
            Database   = $first.Database
            Path       = $first.Path
            Versions   = $versions
            Fields     = [System.Collections.Generic.List[object]]::new()
            Blobs      = [System.Collections.Generic.List[object]]::new()
            IsValid    = $true
        }

        # All records for one item must agree on structural identity.
        foreach ($record in $versions) {
            if ($record.Name -ne $first.Name -or
                $record.ParentId -ne $first.ParentId -or
                $record.TemplateId -ne $first.TemplateId -or
                $record.MasterId -ne $first.MasterId -or
                $record.Database -ne $first.Database) {

                $item.IsValid = $false
                $errors.Add((New-ValidationResult $item 'INCONSISTENT_ITEM' `
                    'Item versions disagree on name, parent, template, master, or database.' $record.SourceFile))
            }
        }

        # Deduplicate shared/unversioned fields while retaining every versioned field.
        $fieldKeys = @{}
        $blobIds = @{}

        foreach ($record in $versions) {
            foreach ($field in $record.Fields) {
                if ([string]::IsNullOrWhiteSpace($field.Storage)) {
                    $item.IsValid = $false
                    $errors.Add((New-ValidationResult $item 'UNKNOWN_FIELD_STORAGE' `
                        "Field $($field.Id) ('$($field.Key)') has no Shared/Unversioned/Versioned metadata." `
                        $record.SourceFile))
                    continue
                }

                switch ($field.Storage.ToLowerInvariant()) {
                    'shared' {
                        $key = "S|$($field.Id)"
                    }
                    'unversioned' {
                        $key = "U|$($field.Id)|$($field.Language)"
                    }
                    'versioned' {
                        $key = "V|$($field.Id)|$($field.Language)|$($field.Version)"
                    }
                    default {
                        $item.IsValid = $false
                        $errors.Add((New-ValidationResult $item 'INVALID_FIELD_STORAGE' `
                            "Field $($field.Id) has unsupported storage '$($field.Storage)'." $record.SourceFile))
                        continue
                    }
                }

                if ($fieldKeys.ContainsKey($key)) {
                    if ($fieldKeys[$key].Value -ne $field.Value) {
                        $item.IsValid = $false
                        $errors.Add((New-ValidationResult $item 'CONFLICTING_FIELD_VALUE' `
                            "Field $($field.Id) has conflicting values for the same storage/language/version." `
                            $record.SourceFile))
                    }
                    continue
                }

                $fieldKeys[$key] = $field
                $item.Fields.Add($field)

                if ($field.Type -ieq 'attachment' -and -not [string]::IsNullOrWhiteSpace($field.Value)) {
                    try {
                        $blobId = ConvertTo-NormalizedGuid $field.Value
                        $blobKey = $blobId.ToString('D')

                        if (-not $blobIds.ContainsKey($blobKey)) {
                            $blobPath = Join-Path $PackageRoot "blob/$($item.Database)/$blobKey"
                            if (-not (Test-Path -LiteralPath $blobPath)) {
                                # Package blob filenames may use original casing/format. Search by normalized GUID.
                                $blobDirectory = Join-Path $PackageRoot "blob/$($item.Database)"
                                $candidate = if (Test-Path $blobDirectory) {
                                    Get-ChildItem $blobDirectory -File |
                                        Where-Object {
                                            try {
                                                (ConvertTo-NormalizedGuid $_.Name) -eq $blobId
                                            }
                                            catch { $false }
                                        } |
                                        Select-Object -First 1
                                } else { $null }

                                if ($candidate) {
                                    $blobPath = $candidate.FullName
                                }
                            }

                            if (-not (Test-Path -LiteralPath $blobPath)) {
                                $item.IsValid = $false
                                $errors.Add((New-ValidationResult $item 'MISSING_BLOB' `
                                    "Attachment field $($field.Id) references blob $blobId, but the blob is not in the package."))
                            }
                            else {
                                $blob = [pscustomobject]@{
                                    Id   = $blobId
                                    Path = $blobPath
                                }
                                $blobIds[$blobKey] = $blob
                                $item.Blobs.Add($blob)
                            }
                        }
                    }
                    catch {
                        $item.IsValid = $false
                        $errors.Add((New-ValidationResult $item 'INVALID_BLOB_ID' `
                            "Attachment field $($field.Id) contains invalid blob ID '$($field.Value)'."))
                    }
                }
            }
        }

        $items.Add($item)
    }

    # Parent failure propagation only applies when the parent itself is in this package.
    $byId = @{}
    foreach ($item in $items) {
        $byId[$item.Id.ToString('D')] = $item
    }

    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($item in $items) {
            if (-not $item.IsValid) { continue }

            $parentKey = $item.ParentId.ToString('D')
            if ($byId.ContainsKey($parentKey) -and -not $byId[$parentKey].IsValid) {
                $item.IsValid = $false
                $changed = $true
                $errors.Add((New-ValidationResult $item 'INVALID_PARENT' `
                    "Parent item $($item.ParentId) is in the package but cannot be converted."))
            }
        }
    }

    [pscustomobject]@{
        Items  = @($items)
        Errors = @($errors)
    }
}

function Show-ValidationReport {
    param(
        [Parameter(Mandatory)] $Validation
    )

    $valid = @($Validation.Items | Where-Object IsValid)
    $invalid = @($Validation.Items | Where-Object { -not $_.IsValid })

    Write-Section 'Validation'
    Write-Host ("Items discovered: {0,6}" -f $Validation.Items.Count)
    Write-Host ("Items valid:      {0,6}" -f $valid.Count)
    Write-Host ("Items invalid:    {0,6}" -f $invalid.Count)
    Write-Host ("Errors:           {0,6}" -f $Validation.Errors.Count)

    if ($Validation.Errors.Count -gt 0) {
        Write-Host ''
        Write-Host 'ERRORS'

        $i = 0
        foreach ($error in $Validation.Errors) {
            $i++
            Write-Host ''
            Write-Host "[$i] $($error.Path)"
            if ($error.ItemId) { Write-Host "    ID:      $($error.ItemId)" }
            Write-Host "    Code:    $($error.Code)"
            Write-Host "    $($error.Message)"
            if ($error.Source) { Write-Host "    Source:  $($error.Source)" }
        }
    }
}

function Confirm-PartialConversion {
    param(
        [int] $ValidCount,
        [int] $TotalCount
    )

    if ($AllowPartial) {
        return $true
    }

    if (-not [Environment]::UserInteractive) {
        return $false
    }

    Write-Host ''
    $response = Read-Host "$ValidCount of $TotalCount items can be converted successfully. Continue and generate a RAIF containing only those items? [y/N]"
    return $response -match '^(?i)y(es)?$'
}

function ConvertTo-TransferredItem {
    param([Parameter(Mandatory)] $Item)

    $transferred = [Sitecore.Data.ItemsTransfer.TransferredItem]::new()
    $transferred.Id = $Item.Id
    $transferred.Name = $Item.Name
    $transferred.ParentId = $Item.ParentId
    $transferred.TemplateId = $Item.TemplateId
    $transferred.MasterId = $Item.MasterId
    $transferred.TimeStamp = [DateTime]::UtcNow.Ticks

    $fields = [System.Collections.Generic.List[Sitecore.Data.ItemsTransfer.Abstractions.ITransferredField]]::new()

    foreach ($field in $Item.Fields) {
        switch ($field.Storage.ToLowerInvariant()) {
            'shared' {
                $value = [Sitecore.Data.ItemsTransfer.SharedTransferredField]::new(
                    $field.Id, [string]$field.Value
                )
            }
            'unversioned' {
                $value = [Sitecore.Data.ItemsTransfer.UnversionedTransferredField]::new(
                    $field.Id, [string]$field.Value, [string]$field.Language
                )
            }
            'versioned' {
                $value = [Sitecore.Data.ItemsTransfer.VersionedTransferredField]::new(
                    $field.Id, [string]$field.Value, [string]$field.Language, [int]$field.Version
                )
            }
        }

        $fields.Add($value)
    }

    $blobs = [System.Collections.Generic.List[Sitecore.Data.ItemsTransfer.Abstractions.ITransferredBlob]]::new()
    $streams = [System.Collections.Generic.List[System.IO.Stream]]::new()

    foreach ($blob in $Item.Blobs) {
        $stream = [IO.File]::OpenRead($blob.Path)
        $streams.Add($stream)
        $blobs.Add([Sitecore.Data.ItemsTransfer.TransferredBlob]::new($blob.Id, $stream))
    }

    # TransferredItem exposes read-only collection properties.
    # Populate those collections rather than assigning replacement lists.
    foreach ($field in $fields) {
        $transferred.Fields.Add($field)
    }

    foreach ($blob in $blobs) {
        $transferred.Blobs.Add($blob)
    }

    [pscustomobject]@{
        Item    = $transferred
        Streams = $streams
    }
}

function Write-Raif {
    param(
        [Parameter(Mandatory)] [array] $Items,
        [Parameter(Mandatory)] [string] $Path
    )

    $outputDirectory = Split-Path -Parent $Path
    if ($outputDirectory -and -not (Test-Path $outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }

    if (Test-Path $Path) {
        Remove-Item -LiteralPath $Path -Force
    }

    $output = [IO.File]::Create($Path)
    try {
        $factory = [Sitecore.Data.ItemsTransfer.TransferFactory]::new()

        $options = [Sitecore.Data.ItemsTransfer.Abstractions.TransferOptions]::new(
            [Sitecore.Data.ItemsTransfer.Abstractions.MergeStrategy]::OverrideExistingItem,
            [Sitecore.Data.ItemsTransfer.Abstractions.TransferType]::Transferable,
            [DateTime]::UtcNow.Ticks,
            'Converted from Sitecore XM/XP Package Designer package'
        )

        $header = $factory.CreateHeader($options)
        try {
            $header.Write($output)
        }
        finally {
            $header.Dispose()
        }

        foreach ($item in $Items) {
            $converted = ConvertTo-TransferredItem $item
            try {
                $writer = $factory.CreateWriter($converted.Item)
                try {
                    $writer.Write($output)
                }
                finally {
                    $writer.Dispose()
                }
            }
            finally {
                foreach ($stream in $converted.Streams) {
                    $stream.Dispose()
                }
            }
        }
    }
    catch {
        $output.Dispose()
        if (Test-Path $Path) {
            Remove-Item -LiteralPath $Path -Force
        }
        throw
    }
    finally {
        if ($output) {
            $output.Dispose()
        }
    }

    $file = Get-Item -LiteralPath $Path
    if ($file.Length -le 0) {
        Remove-Item -LiteralPath $Path -Force
        throw 'RAIF writer produced an empty output file.'
    }

    return $file
}

try {
    Write-Verbose 'Sitecore Package -> RAIF Converter'
    Write-Verbose "PowerShell:          $($PSVersionTable.PSVersion)"
    Write-Verbose "Edition:             $($PSVersionTable.PSEdition)"

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        try {
            $release = (Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' `
                -Name Release -ErrorAction Stop).Release
        }
        catch {
            throw 'Unable to determine the installed .NET Framework version.'
        }

        if ([int]$release -lt 461808) {
            throw ("Windows PowerShell 5.1 requires .NET Framework 4.7.2 or later " +
                   "for Sitecore.XmCloud.Data.ItemsTransfer. Installed release key: $release")
        }

        Write-Verbose "NET Framework key:   $release"
    }

    # A bare package filename is resolved relative to the script directory.
    $packageDirectory = Split-Path -Parent $PackagePath
    if ([string]::IsNullOrWhiteSpace($packageDirectory)) {
        $PackagePath = Join-Path $PSScriptRoot $PackagePath
    }

    $PackagePath = (Resolve-Path -LiteralPath $PackagePath).Path

    # Default output: beside input, same basename, .raif extension.
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $inputDirectory = Split-Path -Parent $PackagePath
        $inputBaseName = [IO.Path]::GetFileNameWithoutExtension($PackagePath)
        $OutputPath = Join-Path $inputDirectory ($inputBaseName + '.raif')
    }
    else {
        $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    }

    # Protect an existing RAIF from accidental replacement. -Overwrite makes
    # replacement explicit and allows unattended/CI usage.
    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        if (-not $Overwrite) {
            Write-Host ''
            Write-Host 'Output file already exists:'
            Write-Host "  $OutputPath"
            $confirmation = Read-Host 'Overwrite it? [y/N]'

            if ($confirmation -notmatch '^(?i:y|yes)$') {
                Write-Host 'Conversion cancelled. Existing output file was not modified.'
                return
            }
        }

        Write-Verbose "Existing output file will be overwritten: $OutputPath"
    }

    New-Item -ItemType Directory -Path $script:LibRoot -Force | Out-Null

    Write-Verbose 'Resolving ItemsTransfer package...'
    $nuget = Get-NuGetResources

    $versionSource = 'Explicitly pinned'
    if ([string]::IsNullOrWhiteSpace($ItemTransferVersion)) {
        $ItemTransferVersion = Get-LatestListedStableVersion `
            -PackageId $script:ItemsTransferPackageId `
            -NuGetResources $nuget
        $versionSource = 'Latest stable listed'
    }

    Write-Verbose "ItemsTransfer:       $ItemTransferVersion"
    Write-Verbose "Version source:      $versionSource"
    Write-Verbose "Package:             $PackagePath"
    Write-Verbose "Output:              $OutputPath"
    Write-Verbose "Dependency cache:    $script:LibRoot"

    Write-Progress -Activity 'Initializing Sitecore ItemsTransfer' `
        -Status 'Resolving dependencies' `
        -PercentComplete 10

    $resolved = @{}
    Get-NuGetPackage `
        -PackageId $script:ItemsTransferPackageId `
        -Version $ItemTransferVersion `
        -NuGetResources $nuget `
        -Resolved $resolved

    Write-Progress -Activity 'Initializing Sitecore ItemsTransfer' `
        -Status 'Loading assemblies' `
        -PercentComplete 75

    Import-NuGetAssemblies -Resolved $resolved

    Write-Progress -Activity 'Initializing Sitecore ItemsTransfer' `
        -Status 'Ready' `
        -PercentComplete 100
    Write-Progress -Activity 'Initializing Sitecore ItemsTransfer' -Completed

    $script:WorkRoot = Join-Path ([IO.Path]::GetTempPath()) ("SitecorePackageToRaif-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:WorkRoot -Force | Out-Null

    Write-Section 'Reading package'
    $packageRoot = Expand-SitecorePackage -Path $PackagePath
    $records = @(Get-SitecorePackageModel -PackageRoot $packageRoot)

    if ($records.Count -eq 0) {
        throw 'No Sitecore item records were found in the package.'
    }

    $validation = Merge-AndValidateItems -Records $records -PackageRoot $packageRoot
    Show-ValidationReport -Validation $validation

    $validItems = @($validation.Items | Where-Object IsValid)
    if ($validItems.Count -eq 0) {
        throw 'No valid items remain to write.'
    }

    if ($validation.Errors.Count -gt 0) {
        if (-not (Confirm-PartialConversion -ValidCount $validItems.Count -TotalCount $validation.Items.Count)) {
            Write-Host ''
            Write-Host 'Conversion cancelled. No RAIF file was created.'
            exit 2
        }
    }

    Write-Section 'Writing RAIF'
    $result = Write-Raif -Items $validItems -Path $OutputPath

    Write-Host "Items written:       $($validItems.Count)"
    Write-Host "Output size:         $($result.Length) bytes"
    Write-Host "RAIF:                $($result.FullName)"
}
catch {
    Write-Error $_
    exit 1
}
finally {
    if ($script:WorkRoot -and (Test-Path $script:WorkRoot)) {
        Remove-Item $script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
