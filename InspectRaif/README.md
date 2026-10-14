# InspectRaif.ps1

`InspectRaif.ps1` is a lightweight PowerShell utility for inspecting the
contents of a Sitecore **RAIF (Remote Automated Item Format)** file.

RAIF files are used by Sitecore's Item Transfer tooling to represent
Sitecore items, fields, versions, languages, and associated binary
content during content transfer operations. Because RAIF is a binary
serialization format, its contents cannot be conveniently inspected with
a text editor or archive utility.

This script provides a human-readable manifest for troubleshooting and
validating RAIF files before using them in a content transfer.

## Requirements

-   Windows PowerShell 5.1 or later
-   Internet access on first run to retrieve the required Sitecore
    ItemsTransfer NuGet package and dependencies

Dependencies are downloaded automatically and cached in the `lib`
directory beside the script.

## Usage

Inspect a RAIF file in the same directory as the script:

``` powershell
.\InspectRaif.ps1 -RaifPath PackageTest.raif
```

A full path can also be supplied:

``` powershell
.\InspectRaif.ps1 -RaifPath C:\Sitecore\Migration\PackageTest.raif
```

The script displays a manifest containing information about the items,
fields, languages, versions, and binary/media content represented in the
RAIF.

### Verbose Output

By default, dependency initialization and other startup details are
suppressed so the terminal output focuses on the RAIF manifest.

Use PowerShell's standard `-Verbose` flag to display initialization
details, including the ItemsTransfer version, dependency cache, and
dependency downloads:

``` powershell
.\InspectRaif.ps1 -RaifPath PackageTest.raif -Verbose
```

### Export to JSON

Use `-ExportJson` to also write the manifest to a JSON file:

``` powershell
.\InspectRaif.ps1 -RaifPath PackageTest.raif -ExportJson
```

By default, this creates:

``` text
PackageTest.manifest.json
```

beside the RAIF file.

A specific output location can be supplied with `-JsonPath`:

``` powershell
.\InspectRaif.ps1 -RaifPath PackageTest.raif -ExportJson -JsonPath C:\Temp\manifest.json
```

## ItemsTransfer Version

By default, the script retrieves the latest stable version of the
official `Sitecore.XmCloud.Data.ItemsTransfer` NuGet package.

A specific version can be selected when reproducibility or version
matching is required:

``` powershell
.\InspectRaif.ps1 -RaifPath PackageTest.raif -ItemTransferVersion 1.9.20
```

The script uses Sitecore's ItemsTransfer library to read the RAIF rather
than independently attempting to decode or reverse-engineer the binary
format.
