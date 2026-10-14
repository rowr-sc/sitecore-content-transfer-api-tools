# Convert-SitecorePackageToRaif.ps1

`Convert-SitecorePackageToRaif.ps1` converts a legacy Sitecore XM/XP
**Package Designer ZIP package** into a **RAIF** file that can be used
with Sitecore's Item Transfer tooling.

## Purpose

Sitecore Package Designer packages are a convenient way to export items
from legacy XM/XP solutions, but they are not directly consumable by the
SitecoreAI Item Transfer API. This utility bridges that gap by
translating the item data in a Sitecore package into Sitecore's RAIF
transfer format.

The converter supports normal Sitecore items as well as **media items
and their binary blobs**, making it useful when moving content that
cannot be handled by migration tooling that does not support media.

Use it when you have content exported from a legacy Sitecore instance as
a Package Designer ZIP and need to prepare that content for an Item
Transfer-based migration workflow.

## Requirements

-   Windows PowerShell 5.1 or later
-   .NET Framework 4.7.2 or later when using Windows PowerShell 5.1
-   Internet access on first run to retrieve the official
    `Sitecore.XmCloud.Data.ItemsTransfer` NuGet package and dependencies

Dependencies are downloaded automatically and cached in the `lib`
directory beside the script. Normal dependency initialization is shown
with a progress bar; use `-Verbose` to see detailed initialization
information.

## Usage

Basic conversion:

``` powershell
.\Convert-SitecorePackageToRaif.ps1 -PackagePath Package.zip
```

A bare filename is resolved relative to the script directory. By
default, the RAIF is written beside the source package using the same
basename:

``` text
Package.zip
Package.raif
```

A specific output path can also be supplied:

``` powershell
.\Convert-SitecorePackageToRaif.ps1 `
    -PackagePath C:\Migration\Package.zip `
    -OutputPath C:\Migration\Output.raif
```

If the target RAIF already exists, the script asks for confirmation
before replacing it.

## Parameters

### `-PackagePath`

**Required.** Path to the Sitecore Package Designer ZIP to convert.

Accepts either a full path or a filename/path relative to the script
directory.

``` powershell
-PackagePath MediaPackage.zip
```

### `-OutputPath`

Optional destination for the generated RAIF.

If omitted, the output is created beside the source package with the
`.raif` extension.

``` powershell
-OutputPath C:\Migration\MediaPackage.raif
```

### `-ItemTransferVersion`

Pins the official `Sitecore.XmCloud.Data.ItemsTransfer` NuGet package to
a specific version.

If omitted, the script resolves the latest stable version. Pinning is
useful when a migration process needs reproducible behavior across
environments.

``` powershell
-ItemTransferVersion 1.9.20
```

### `-AllowPartial`

Normally, if some package items cannot be converted, the script reports
the failures and asks whether to generate a RAIF containing only the
valid items.

`-AllowPartial` bypasses that confirmation and permits creation of a
partial RAIF automatically.

``` powershell
-AllowPartial
```

This does **not** suppress fatal package, dependency, serialization, or
output errors.

### `-Overwrite`

Allows an existing target RAIF to be replaced without confirmation.

``` powershell
-Overwrite
```

Without this flag, an existing output file must be explicitly confirmed
before it is replaced.

### `-Verbose`

Displays detailed initialization and dependency information that is
normally hidden, including ItemsTransfer version resolution, dependency
downloads, cache paths, and assembly loading.

``` powershell
-Verbose
```

## Example

``` powershell
.\Convert-SitecorePackageToRaif.ps1 `
    -PackagePath SitecoreContent.zip `
    -OutputPath SitecoreContent.raif `
    -ItemTransferVersion 1.9.20 `
    -AllowPartial `
    -Overwrite
```

## Limitations

This utility is a **format translator**, not a complete migration or
dependency-analysis engine.

-   It converts items present in the supplied Sitecore package; it does
    not discover additional dependencies from the source Sitecore
    instance.
-   It preserves Sitecore item structure, field storage semantics,
    languages, versions, and package-provided media blobs.
-   A failure in any language, version, field, or blob invalidates that
    item.
-   If an item's parent is also included in the package and that parent
    fails conversion, the child is also invalidated.
-   GUIDs stored in ordinary field values are not recursively
    interpreted as dependencies or automatically added to the migration.
-   Successful RAIF generation confirms that the package could be
    translated and serialized; it does not guarantee that every item
    will be accepted by a particular destination environment.

The generated RAIF can be inspected before transfer with
`InspectRaif.ps1`.
