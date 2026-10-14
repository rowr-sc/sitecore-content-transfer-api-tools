#requires -Version 5.1
<#
.SYNOPSIS
Inspects a Sitecore RAIF file and prints a human-readable manifest.

.DESCRIPTION
Uses Sitecore.XmCloud.Data.ItemsTransfer to read a RAIF file. The script accepts
either a full/relative path or a bare filename. A bare filename is resolved
relative to the directory containing this script.

Dependencies are restored from nuget.org into the same script-local ./lib cache
used by Convert-SitecorePackageToRaif.ps1.

.PARAMETER RaifPath
Path or filename of the RAIF file to inspect.

.PARAMETER ExportJson
Exports the same manifest as JSON. If no JsonPath is supplied, the JSON file is
written beside the RAIF using <name>.manifest.json.

.PARAMETER JsonPath
Optional JSON output path. Supplying JsonPath implies ExportJson.

.PARAMETER ItemTransferVersion
Optional Sitecore.XmCloud.Data.ItemsTransfer package version. If omitted, the
latest stable listed version is used.

.EXAMPLE
.\InspectRaif.ps1 -RaifPath PackageTest-Content.raif

.EXAMPLE
.\InspectRaif.ps1 -RaifPath PackageTest-Content.raif -ExportJson

.EXAMPLE
.\InspectRaif.ps1 -RaifPath C:\Packages\content.raif -ExportJson `
    -JsonPath C:\Reports\content.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position=0)]
    [ValidateNotNullOrEmpty()]
    [string] $RaifPath,

    [Parameter()]
    [switch] $ExportJson,

    [Parameter()]
    [string] $JsonPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ItemTransferVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([Enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls12') {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$script:PackageId = 'Sitecore.XmCloud.Data.ItemsTransfer'
$script:NuGetServiceIndex = 'https://api.nuget.org/v3/index.json'
$script:LibRoot = Join-Path $PSScriptRoot 'lib'

function Write-Section {
    param([string] $Text)
    Write-Host ''
    Write-Host $Text
    Write-Host ('-' * $Text.Length)
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
        Registration = $registration.'@id'.TrimEnd('/')
    }
}

function Get-LatestStableVersion {
    param([string] $PackageId, $NuGetResources)

    $id = $PackageId.ToLowerInvariant()
    $registration = Invoke-RestMethod -Uri "$($NuGetResources.Registration)/$id/index.json"
    $versions = @()

    foreach ($page in $registration.items) {
        $leaves = if ($page.items) { $page.items } else { (Invoke-RestMethod -Uri $page.'@id').items }
        foreach ($leaf in $leaves) {
            $entry = $leaf.catalogEntry
            if ($entry -is [string]) { $entry = Invoke-RestMethod -Uri $entry }
            $listed = if ($null -eq $entry.listed) { $true } else { [bool]$entry.listed }
            $v = [string]$entry.version
            if (-not $listed -or $v -match '-') { continue }
            try { $versions += [Version]$v } catch {}
        }
    }

    if ($versions.Count -eq 0) { throw "No listed stable versions found for '$PackageId'." }
    return ($versions | Sort-Object -Descending | Select-Object -First 1).ToString()
}

function Get-MinimumVersionFromRange {
    param([string] $VersionSpec)
    $value = $VersionSpec.Trim()
    if ($value -notmatch '^[\[\(]') { return $value }
    $inner = $value.Trim('[', ']', '(', ')')
    $parts = $inner.Split(',', 2)
    if ($parts[0].Trim()) { return $parts[0].Trim() }
    throw "Cannot resolve dependency range '$VersionSpec'."
}

function Get-NuGetPackage {
    param(
        [string] $PackageId,
        [string] $Version,
        $NuGetResources,
        [hashtable] $Resolved
    )

    $key = "$($PackageId.ToLowerInvariant())@$($Version.ToLowerInvariant())"
    if ($Resolved.ContainsKey($key)) { return }
    $Resolved[$key] = $true

    $versionRoot = Join-Path (Join-Path $script:LibRoot $PackageId) $Version
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
        try {
            $webClient.DownloadFile($uri, $nupkg)
        }
        finally {
            $webClient.Dispose()
        }

        Write-Progress -Activity 'Initializing Sitecore ItemsTransfer' `
            -Status "Extracting $PackageId $Version" `
            -PercentComplete 50

        $extract = Join-Path $versionRoot 'package'
        if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
        [System.IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $extract)
        New-Item -ItemType File -Path $marker -Force | Out-Null
    }

    $nuspec = Get-ChildItem (Join-Path $versionRoot 'package') -Filter '*.nuspec' | Select-Object -First 1
    if (-not $nuspec) { throw "No .nuspec found for $PackageId $Version." }

    [xml]$manifest = Get-Content $nuspec.FullName -Raw
    $root = $manifest.SelectSingleNode(
        "/*[local-name()='package']/*[local-name()='metadata']/*[local-name()='dependencies']"
    )
    $dependencies = @()

    if ($null -ne $root) {
        $groups = @($root.SelectNodes("./*[local-name()='group']"))
        if ($groups.Count -gt 0) {
            $group = $groups | Where-Object {
                $_.HasAttribute('targetFramework') -and
                $_.GetAttribute('targetFramework') -match 'netstandard2\.0|\.NETStandard2\.0'
            } | Select-Object -First 1
            if (-not $group) {
                $group = $groups | Where-Object {
                    $_.HasAttribute('targetFramework') -and
                    $_.GetAttribute('targetFramework') -match 'netstandard'
                } | Select-Object -First 1
            }
            if (-not $group) { $group = $groups | Select-Object -First 1 }
            if ($group) { $dependencies = @($group.SelectNodes("./*[local-name()='dependency']")) }
        } else {
            $dependencies = @($root.SelectNodes("./*[local-name()='dependency']"))
        }
    }

    foreach ($dependency in $dependencies) {
        $id = $dependency.GetAttribute('id')
        $spec = $dependency.GetAttribute('version')
        if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($spec)) { continue }
        Get-NuGetPackage -PackageId $id `
            -Version (Get-MinimumVersionFromRange $spec) `
            -NuGetResources $NuGetResources -Resolved $Resolved
    }
}

function Import-NuGetAssemblies {
    param([hashtable] $Resolved)

    $dlls = @()
    foreach ($key in $Resolved.Keys) {
        $parts = $key.Split('@', 2)
        $packageDir = Get-ChildItem $script:LibRoot -Directory |
            Where-Object { $_.Name.ToLowerInvariant() -eq $parts[0] } |
            Select-Object -First 1
        if (-not $packageDir) { continue }

        $lib = Join-Path $packageDir.FullName "$($parts[1])/package/lib"
        if (-not (Test-Path $lib)) { continue }

        $dirs = Get-ChildItem $lib -Directory -ErrorAction SilentlyContinue
        $selected = $dirs | Where-Object Name -eq 'netstandard2.0' | Select-Object -First 1
        if (-not $selected) {
            $selected = $dirs | Where-Object { $_.Name -match '^netstandard' } |
                Sort-Object Name -Descending | Select-Object -First 1
        }
        if (-not $selected) {
            $selected = $dirs | Where-Object { $_.Name -match '^net4[0-9]+' } |
                Sort-Object Name -Descending | Select-Object -First 1
        }
        if ($selected) {
            $dlls += Get-ChildItem $selected.FullName -Filter '*.dll'
        }
    }

    $dlls = @($dlls | Sort-Object {
        if ($_.Name -eq 'Sitecore.Data.ItemsTransfer.dll') { 1 } else { 0 }
    }, Name -Unique)

    foreach ($dll in $dlls) {
        try {
            [System.Reflection.Assembly]::LoadFrom($dll.FullName) | Out-Null
        } catch {
            if ($dll.Name -eq 'Sitecore.Data.ItemsTransfer.dll') { throw }
        }
    }

    $assembly = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'Sitecore.Data.ItemsTransfer' } |
        Select-Object -First 1

    if (-not $assembly) { throw 'Sitecore.Data.ItemsTransfer could not be loaded.' }
    return $assembly
}

function Get-PropertyValue {
    param($Object, [string] $Name)

    if ($null -eq $Object) { return $null }

    # Prefer PowerShell's normal property adapter. This avoids Windows
    # PowerShell 5.1's problematic binding of reflection GetValue/Invoke
    # overloads when the reflected getter returns null.
    $psProperty = $Object.PSObject.Properties[$Name]
    if ($null -ne $psProperty) {
        try {
            return $psProperty.Value
        }
        catch {
            # Fall through to reflection for non-public properties.
        }
    }

    $property = $Object.GetType().GetProperty(
        $Name,
        [Reflection.BindingFlags]'Instance,Public,NonPublic'
    )
    if ($null -eq $property) { return $null }

    try {
        # Explicit MethodInfo.Invoke overload via strongly typed argument
        # variables, avoiding PowerShell's ambiguous two-argument binder.
        $getter = $property.GetGetMethod($true)
        if ($null -eq $getter) { return $null }

        [object]$target = $Object
        [object[]]$arguments = @()
        return $getter.Invoke($target, $arguments)
    }
    catch {
        throw ("Failed reading property '{0}' from type '{1}': {2}" -f `
            $Name, $Object.GetType().FullName, $_.Exception.Message)
    }
}

function New-ValidatorAccessor {
    param($Assembly, $Source)

    # ValidatorDataAccessor requires internal validation state. The supported
    # path is to let DefaultTransferredItemsManager create the accessor.
    # Locate the concrete manager by type name so this remains tolerant of
    # namespace changes between ItemsTransfer package versions.
    $managerType = $Assembly.GetTypes() |
        Where-Object {
            $_.Name -eq 'DefaultTransferredItemsManager' -and
            -not $_.IsAbstract
        } |
        Select-Object -First 1

    if (-not $managerType) {
        throw 'Could not locate concrete DefaultTransferredItemsManager in Sitecore.Data.ItemsTransfer.'
    }

    $manager = $null
    $constructors = @($managerType.GetConstructors(
        [Reflection.BindingFlags]'Instance,Public,NonPublic'
    ))

    # ItemsTransfer 1.9.20 rejects a null ILogger. Its NuGet dependency graph
    # already includes Microsoft.Extensions.Logging.Abstractions, so use the
    # framework-provided no-op logger rather than adding custom logging code.
    $nullLoggerType = [AppDomain]::CurrentDomain.GetAssemblies() |
        ForEach-Object {
            try { $_.GetType('Microsoft.Extensions.Logging.Abstractions.NullLogger', $false) }
            catch { $null }
        } |
        Where-Object { $null -ne $_ } |
        Select-Object -First 1

    if (-not $nullLoggerType) {
        try {
            $loggingAssembly = [System.Reflection.Assembly]::Load(
                'Microsoft.Extensions.Logging.Abstractions'
            )
            $nullLoggerType = $loggingAssembly.GetType(
                'Microsoft.Extensions.Logging.Abstractions.NullLogger',
                $false
            )
        }
        catch {
            # The dependency loader above normally loads this assembly already.
        }
    }

    if (-not $nullLoggerType) {
        throw ('Could not locate Microsoft.Extensions.Logging.Abstractions.NullLogger. ' +
            'The ItemsTransfer logging dependency was not loaded.')
    }

    $instanceProperty = $nullLoggerType.GetProperty(
        'Instance',
        [Reflection.BindingFlags]'Static,Public'
    )
    if (-not $instanceProperty) {
        throw 'NullLogger.Instance was not found.'
    }

    $nullLogger = $instanceProperty.GetValue($null, $null)
    if ($null -eq $nullLogger) {
        throw 'NullLogger.Instance returned null.'
    }

    foreach ($ctor in $constructors) {
        $parameters = @($ctor.GetParameters())

        if ($parameters.Count -eq 2 -and
            $parameters[0].ParameterType -eq [string] -and
            $parameters[1].ParameterType.FullName -eq 'Microsoft.Extensions.Logging.ILogger') {
            try {
                [object[]]$arguments = @('master', $nullLogger)
                $manager = $ctor.Invoke($arguments)
                break
            }
            catch {
                $message = $_.Exception.Message
                if ($_.Exception.InnerException) {
                    $message += " Inner exception: $($_.Exception.InnerException.Message)"
                }
                throw ("Failed constructing DefaultTransferredItemsManager: {0}" -f $message)
            }
        }
    }

    # Keep a narrow fallback for package versions exposing a single database
    # name constructor.
    if ($null -eq $manager) {
        foreach ($ctor in $constructors) {
            $parameters = @($ctor.GetParameters())
            if ($parameters.Count -eq 1 -and
                $parameters[0].ParameterType -eq [string]) {
                try {
                    [object[]]$arguments = @('master')
                    $manager = $ctor.Invoke($arguments)
                    break
                }
                catch {
                    throw ("Failed constructing DefaultTransferredItemsManager: {0}" -f `
                        $_.Exception.Message)
                }
            }
        }
    }

    if ($null -eq $manager) {
        $signatures = @($constructors | ForEach-Object { $_.ToString() })
        throw ("Could not construct DefaultTransferredItemsManager. Constructors: {0}" -f `
            ($signatures -join '; '))
    }

    $method = $managerType.GetMethod(
        'CreateValidatorDataAccessor',
        [Reflection.BindingFlags]'Instance,Public,NonPublic'
    )

    if ($null -eq $method) {
        throw 'DefaultTransferredItemsManager does not expose CreateValidatorDataAccessor.'
    }

    try {
        [object[]]$arguments = @($Source)
        $accessor = $method.Invoke($manager, $arguments)
    }
    catch {
        $message = $_.Exception.Message
        if ($_.Exception.InnerException) {
            $message += " Inner exception: $($_.Exception.InnerException.Message)"
        }
        throw ("CreateValidatorDataAccessor failed: {0}" -f $message)
    }

    if ($null -eq $accessor) {
        throw 'CreateValidatorDataAccessor returned null.'
    }

    return $accessor
}

function Get-RaifManifest {
    param([string] $Path, $Assembly)

    $sourceType = $Assembly.GetType(
        'Sitecore.Data.ItemsTransfer.Reading.FileItemDataSource',
        $true
    )
    $source = [Activator]::CreateInstance($sourceType, @($Path))

    try {
        $accessor = New-ValidatorAccessor -Assembly $Assembly -Source $source
        $sourceInfo = Get-PropertyValue $accessor 'SourceInfo'

        # Prefer SourceInfo's authoritative enumeration when available.
        $ids = @()
        if ($null -ne $sourceInfo) {
            $getAll = $sourceInfo.PSObject.Methods['GetAllItemIds']
            if ($null -ne $getAll) {
                $ids = @($sourceInfo.GetAllItemIds())
            }
        }
        if ($ids.Count -eq 0) {
            $ids = @($accessor.GetAllItemIds())
        }

        $items = @()

        foreach ($id in $ids) {
            $definition = $accessor.GetItemDefinition($id)
            $rawFields = @($accessor.GetFields($id))

            $fields = foreach ($field in $rawFields) {
                $language = [string](Get-PropertyValue $field 'Language')
                $versionValue = Get-PropertyValue $field 'Version'
                $value = Get-PropertyValue $field 'Value'
                $fieldId = Get-PropertyValue $field 'Id'

                $versionNumber = -1
                if ($null -ne $versionValue) {
                    try { $versionNumber = [int]$versionValue } catch {}
                }

                $storage = if ([string]::IsNullOrEmpty($language)) {
                    'Shared'
                } elseif ($versionNumber -lt 0) {
                    'Unversioned'
                } else {
                    'Versioned'
                }

                [pscustomobject][ordered]@{
                    Id = if ($fieldId) {
                        try { ([Guid]$fieldId).ToString('D') } catch { [string]$fieldId }
                    } else { $null }
                    Storage = $storage
                    Language = if ([string]::IsNullOrEmpty($language)) {
                        $null
                    } else {
                        $language
                    }
                    Version = if ($versionNumber -lt 0) { $null } else { $versionNumber }
                    Value = [string]$value
                }
            }

            $rawId = Get-PropertyValue $definition 'Id'
            $rawParentId = Get-PropertyValue $definition 'ParentId'
            $rawTemplateId = Get-PropertyValue $definition 'TemplateId'
            $rawMasterId = Get-PropertyValue $definition 'MasterId'

            try { $itemId = ([Guid]$rawId).ToString('D') }
            catch { $itemId = [string]$rawId }

            try { $parentId = ([Guid]$rawParentId).ToString('D') }
            catch { $parentId = [string]$rawParentId }

            try { $templateId = ([Guid]$rawTemplateId).ToString('D') }
            catch { $templateId = [string]$rawTemplateId }

            try { $masterId = ([Guid]$rawMasterId).ToString('D') }
            catch { $masterId = [string]$rawMasterId }

            $items += [pscustomobject][ordered]@{
                Id = $itemId
                Name = [string](Get-PropertyValue $definition 'Name')
                ParentId = $parentId
                TemplateId = $templateId
                MasterId = $masterId
                TimeStamp = Get-PropertyValue $definition 'TimeStamp'
                Fields = @($fields)
            }
        }

        $authoritativeItemCount = $items.Count
        $mediaCount = $null

        if ($null -ne $sourceInfo) {
            $value = Get-PropertyValue $sourceInfo 'ItemsCount'
            if ($null -ne $value) { $authoritativeItemCount = [int]$value }

            $value = Get-PropertyValue $sourceInfo 'MediaCount'
            if ($null -ne $value) { $mediaCount = [int]$value }
        }

        $duplicatedItemIds = @()
        $value = Get-PropertyValue $accessor 'DuplicatedItemIds'
        if ($null -ne $value) { $duplicatedItemIds = @($value) }

        $duplicatedBlobIds = @()
        $value = Get-PropertyValue $accessor 'DuplicatedBlobIds'
        if ($null -ne $value) { $duplicatedBlobIds = @($value) }

        $file = Get-Item -LiteralPath $Path

        return [pscustomobject][ordered]@{
            File = [pscustomobject][ordered]@{
                Name = $file.Name
                FullPath = $file.FullName
                SizeBytes = $file.Length
                LastWriteTimeUtc = $file.LastWriteTimeUtc
            }
            Source = [pscustomobject][ordered]@{
                Name = [string](Get-PropertyValue $source 'Name')
                OriginalName = [string](Get-PropertyValue $source 'OriginalName')
                Description = [string](Get-PropertyValue $source 'Description')
                Strategy = [string](Get-PropertyValue $source 'Strategy')
                IsTransferable = Get-PropertyValue $source 'IsTransferable'
                IsTransferred = Get-PropertyValue $source 'IsTransferred'
                Disabled = Get-PropertyValue $source 'Disabled'
            }
            Summary = [pscustomobject][ordered]@{
                ItemCount = $authoritativeItemCount
                EnumeratedItemCount = $items.Count
                FieldCount = @($items | ForEach-Object { $_.Fields }).Count
                MediaCount = $mediaCount
                DuplicatedItemCount = $duplicatedItemIds.Count
                DuplicatedBlobCount = $duplicatedBlobIds.Count
            }
            DuplicatedItemIds = @($duplicatedItemIds | ForEach-Object { [string]$_ })
            DuplicatedBlobIds = @($duplicatedBlobIds | ForEach-Object { [string]$_ })
            Items = @($items)
        }
    }
    finally {
        if ($source -is [IDisposable]) { $source.Dispose() }
    }
}

function Show-Manifest {
    param($Manifest)

    Write-Section 'RAIF Manifest'
    Write-Host "File:               $($Manifest.File.FullPath)"
    Write-Host "Size:               $($Manifest.File.SizeBytes) bytes"
    Write-Host "Items:              $($Manifest.Summary.ItemCount)"
    Write-Host "Fields:             $($Manifest.Summary.FieldCount)"
    Write-Host "Media/blobs:        $($Manifest.Summary.MediaCount)"
    Write-Host "Enumerated items:   $($Manifest.Summary.EnumeratedItemCount)"
    Write-Host "Duplicate items:    $($Manifest.Summary.DuplicatedItemCount)"
    Write-Host "Duplicate blobs:    $($Manifest.Summary.DuplicatedBlobCount)"

    if ($Manifest.Source.Strategy) {
        Write-Host "Merge strategy:     $($Manifest.Source.Strategy)"
    }
    if ($Manifest.Source.Description) {
        Write-Host "Description:        $($Manifest.Source.Description)"
    }

    $index = 0
    foreach ($item in $Manifest.Items) {
        $index++
        Write-Host ''
        Write-Host "[$index] $($item.Name)"
        Write-Host "    ID:          $($item.Id)"
        Write-Host "    Parent:      $($item.ParentId)"
        Write-Host "    Template:    $($item.TemplateId)"
        Write-Host "    Master:      $($item.MasterId)"
        Write-Host "    Timestamp:   $($item.TimeStamp)"
        Write-Host "    Fields:      $($item.Fields.Count)"

        foreach ($field in $item.Fields) {
            $scope = $field.Storage
            if ($field.Language) { $scope += "/$($field.Language)" }
            if ($null -ne $field.Version) { $scope += "/v$($field.Version)" }

            $displayValue = $field.Value
            if ($null -ne $displayValue -and $displayValue.Length -gt 160) {
                $displayValue = $displayValue.Substring(0, 157) + '...'
            }

            Write-Host "        $($field.Id) [$scope] = $displayValue"
        }
    }
}

try {
    Write-Verbose 'Sitecore RAIF Inspector'
    Write-Verbose "PowerShell:          $($PSVersionTable.PSVersion)"
    Write-Verbose "Edition:             $($PSVersionTable.PSEdition)"

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $release = (Get-ItemProperty `
            'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' `
            -Name Release -ErrorAction Stop).Release
        if ([int]$release -lt 461808) {
            throw 'Windows PowerShell 5.1 requires .NET Framework 4.7.2 or later.'
        }
    }

    if ([string]::IsNullOrWhiteSpace((Split-Path -Parent $RaifPath))) {
        $RaifPath = Join-Path $PSScriptRoot $RaifPath
    }
    $RaifPath = (Resolve-Path -LiteralPath $RaifPath).Path

    if ([IO.Path]::GetExtension($RaifPath) -ine '.raif') {
        Write-Warning "Input file does not use the .raif extension: $RaifPath"
    }

    if (-not [string]::IsNullOrWhiteSpace($JsonPath)) {
        $ExportJson = $true
    }

    if ($ExportJson -and [string]::IsNullOrWhiteSpace($JsonPath)) {
        $dir = Split-Path -Parent $RaifPath
        $base = [IO.Path]::GetFileNameWithoutExtension($RaifPath)
        $JsonPath = Join-Path $dir ($base + '.manifest.json')
    } elseif ($ExportJson) {
        $JsonPath = [IO.Path]::GetFullPath($JsonPath)
    }

    New-Item -ItemType Directory -Path $script:LibRoot -Force | Out-Null

    $nuget = Get-NuGetResources
    if ([string]::IsNullOrWhiteSpace($ItemTransferVersion)) {
        $ItemTransferVersion = Get-LatestStableVersion `
            -PackageId $script:PackageId -NuGetResources $nuget
        $versionSource = 'Latest stable listed'
    } else {
        $versionSource = 'Explicitly pinned'
    }

    Write-Verbose "ItemsTransfer:       $ItemTransferVersion"
    Write-Verbose "Version source:      $versionSource"
    Write-Verbose "RAIF:                $RaifPath"
    Write-Verbose "Dependency cache:    $script:LibRoot"

    Write-Progress -Activity 'Initializing Sitecore ItemsTransfer' `
        -Status 'Resolving dependencies' `
        -PercentComplete 10

    $resolved = @{}
    Get-NuGetPackage -PackageId $script:PackageId `
        -Version $ItemTransferVersion -NuGetResources $nuget -Resolved $resolved

    Write-Progress -Activity 'Initializing Sitecore ItemsTransfer' `
        -Status 'Loading assemblies' `
        -PercentComplete 75

    $assembly = Import-NuGetAssemblies -Resolved $resolved

    Write-Progress -Activity 'Initializing Sitecore ItemsTransfer' `
        -Status 'Ready' `
        -PercentComplete 100
    Write-Progress -Activity 'Initializing Sitecore ItemsTransfer' -Completed

    Write-Progress -Activity 'Reading RAIF' `
        -Status 'Building manifest' `
        -PercentComplete 50

    $manifest = Get-RaifManifest -Path $RaifPath -Assembly $assembly

    Write-Progress -Activity 'Reading RAIF' -Completed

    Show-Manifest -Manifest $manifest

    if ($ExportJson) {
        $jsonDirectory = Split-Path -Parent $JsonPath
        if ($jsonDirectory -and -not (Test-Path $jsonDirectory)) {
            New-Item -ItemType Directory -Path $jsonDirectory -Force | Out-Null
        }

        $manifest | ConvertTo-Json -Depth 12 |
            Set-Content -LiteralPath $JsonPath -Encoding UTF8

        Write-Host ''
        Write-Host "JSON manifest:       $JsonPath"
    }
}
catch {
    Write-Host ''
    Write-Host 'ERROR' -ForegroundColor Red
    Write-Host '-----' -ForegroundColor Red
    Write-Host $_.Exception.ToString() -ForegroundColor Red

    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host ''
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor Red
    }

    if ($_.ScriptStackTrace) {
        Write-Host ''
        Write-Host 'PowerShell stack:' -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
    }

    exit 1
}
