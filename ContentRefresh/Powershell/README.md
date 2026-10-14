# SitecoreAI Content Refresh

`Invoke-SitecoreContentRefresh.ps1` is a command-line utility for
manually refreshing selected Sitecore content between SitecoreAI
environments.

It uses the SitecoreAI **Content Transfer API** to package selected
content in a source environment, transfers that package to the
destination environment, and then uses the **Item Transfer API** to load
the content into the destination Sitecore database.

The script is designed for controlled environment refreshes and CI/CD
automation. Content is selected using an explicit inclusion manifest:
only the item trees listed in the manifest are transferred.

## Safety rules

The script enforces several restrictions:

-   **PROD can be a source, but never a destination.**
-   **UAT and DEV can be destinations.**
-   The source and destination cannot be the same environment.
-   The source and destination host URLs cannot be identical.
-   `Preview` mode does not authenticate or call Sitecore APIs.
-   `Execute` mode requires the exact, case-sensitive confirmation value
    `REFRESH`.
-   Only item trees explicitly listed in the manifest are included.

The supported transfer directions are therefore:

  Source   Destination   Supported
  -------- ------------- -----------
  PROD     UAT           Yes
  PROD     DEV           Yes
  UAT      DEV           Yes
  DEV      UAT           Yes
  UAT      PROD          No
  DEV      PROD          No
  PROD     PROD          No
  UAT      UAT           No
  DEV      DEV           No

> **Important:** A manifest can use `OverrideExistingTree`, which may
> delete destination-only descendants within the selected tree. Review
> the manifest before execution.

## Repository layout

The expected layout is:

``` text
.github/workflows/
├── refresh-sitecore-dev.yml
└── refresh-sitecore-uat.yml

tools/sitecore-content-refresh/
├── Invoke-SitecoreContentRefresh.ps1
└── environment-item-manifests/
    ├── prod.json
    ├── uat.json
    └── dev.json
```

The manifest filename does not technically determine the source or
destination environment. It is simply a JSON file supplied with
`-ManifestPath`. Use clear filenames so that operators understand their
purpose.

## Requirements

Before running the script, you need:

1.  PowerShell 5.1 or later.
2.  Network access to the participating SitecoreAI environments and
    Sitecore authentication service.
3.  SitecoreAI automation client credentials for each environment
    participating in the transfer.
4.  The SitecoreAI environment hostname for each participating
    environment.
5.  A valid content-transfer manifest.

The script is compatible with Windows PowerShell 5.1 and modern
PowerShell (`pwsh`) on supported platforms.

### Sitecore permissions

The automation clients must have sufficient SitecoreAI permissions to
use the Content Transfer and Item Transfer APIs. Current Sitecore
documentation requires the appropriate organization-level administrative
permissions for these APIs.

If authentication succeeds but an API operation returns `401` or `403`,
verify the automation client and its permissions in SitecoreAI.

## Environment configuration

Credentials and hostnames are supplied through environment variables.
They are **not stored in the manifest** and should not be committed to
source control.

Each SitecoreAI environment has three variables:

``` text
SITECORE_<ENVIRONMENT>_HOST
SITECORE_<ENVIRONMENT>_CLIENT_ID
SITECORE_<ENVIRONMENT>_CLIENT_SECRET
```

The complete set is:

``` text
SITECORE_PROD_HOST
SITECORE_PROD_CLIENT_ID
SITECORE_PROD_CLIENT_SECRET

SITECORE_UAT_HOST
SITECORE_UAT_CLIENT_ID
SITECORE_UAT_CLIENT_SECRET

SITECORE_DEV_HOST
SITECORE_DEV_CLIENT_ID
SITECORE_DEV_CLIENT_SECRET
```

You only need variables for the source and destination involved in a
particular local execution.

For example, a UAT → DEV transfer requires:

``` powershell
$env:SITECORE_UAT_HOST = "https://your-uat-host.sitecorecloud.io"
$env:SITECORE_UAT_CLIENT_ID = "<UAT client ID>"
$env:SITECORE_UAT_CLIENT_SECRET = "<UAT client secret>"

$env:SITECORE_DEV_HOST = "https://your-dev-host.sitecorecloud.io"
$env:SITECORE_DEV_CLIENT_ID = "<DEV client ID>"
$env:SITECORE_DEV_CLIENT_SECRET = "<DEV client secret>"
```

These assignments set variables for the current PowerShell process. They
do not need to be permanently installed on the machine.

### Where to find the environment hostname

In SitecoreAI Deploy:

1.  Open the relevant project.
2.  Open **Authoring environments**.
3.  Select the environment.
4.  Open its details.
5.  Copy the **Environment host name**.

Use the Sitecore environment hostname itself. Do not use a URL rewritten
by an email security product such as Mimecast.

For example:

``` text
https://example-develop.sitecorecloud.io
```

The script accepts a trailing `/`, but removes it before constructing
API URLs.

### Automation client credentials

Create or obtain automation client credentials for each participating
environment.

Treat credentials as **environment-specific**. Do not assume that a
client ID or secret from DEV is valid for UAT or PROD.

The script authenticates using the OAuth client-credentials flow
against:

``` text
https://auth.sitecorecloud.io/oauth/token
```

with the Sitecore API audience:

``` text
https://api.sitecorecloud.io
```

### Protecting secrets

Do not:

-   Put client secrets in a manifest.
-   Hard-code client secrets in the PowerShell script.
-   Commit secrets to Git.
-   Print client secrets in CI/CD logs.
-   Paste client secrets into tickets or documentation.

For GitHub Actions, store secrets using GitHub's secret-management
facilities and inject them as environment variables at execution time.

## Creating a manifest

Each source environment has its own manifest:

```text
environment-item-manifests/
├── prod.json
├── uat.json
└── dev.json
```

The manifest describes content available in the **source**, not content expected in a particular destination. Always select the manifest corresponding to `-SourceEnvironment`.

For example:

| Transfer | Source manifest |
| --- | --- |
| PROD → UAT | `prod.json` |
| PROD → DEV | `prod.json` |
| UAT → DEV | `uat.json` |
| DEV → UAT | `dev.json` |

The manifest defines exactly which Sitecore item trees will be included
in the refresh.

Example:

``` json
{
  "Database": "master",
  "DataTrees": [
    {
      "ItemPath": "/sitecore/content/Home/Test",
      "Scope": "ItemAndDescendants",
      "MergeStrategy": "OverrideExistingItem"
    }
  ]
}
```

### `Database`

The Sitecore database into which the Item Transfer operation will load
the content.

For the intended authoring-environment refresh scenario, this will
normally be:

``` json
"Database": "master"
```

### `DataTrees`

`DataTrees` is the inclusion list.

Each entry identifies a Sitecore item and controls how much of its tree
is transferred and how conflicts are handled.

You can include multiple trees:

``` json
{
  "Database": "master",
  "DataTrees": [
    {
      "ItemPath": "/sitecore/content/Corporate/Home",
      "Scope": "ItemAndDescendants",
      "MergeStrategy": "OverrideExistingItem"
    },
    {
      "ItemPath": "/sitecore/media library/Corporate",
      "Scope": "ItemAndDescendants",
      "MergeStrategy": "OverrideExistingItem"
    },
    {
      "ItemPath": "/sitecore/system/Settings/Some Item",
      "Scope": "SingleItem",
      "MergeStrategy": "KeepExistingItem"
    }
  ]
}
```

There is no exclusion list. If content should not be transferred, do not
include it in `DataTrees`.

### `ItemPath`

The Sitecore path of the root item to transfer.

Example:

``` json
"ItemPath": "/sitecore/content/Home/Test"
```

The item must exist in the source environment.

### `Scope`

Supported values are:

  Value                  Meaning
  ---------------------- --------------------------------------------------
  `SingleItem`           Transfer only the item identified by `ItemPath`.
  `ItemAndDescendants`   Transfer the item and its descendants.

For a site or subtree refresh, `ItemAndDescendants` is normally
appropriate.

### `MergeStrategy`

Supported values are:

  -----------------------------------------------------------------------
  Value                               Behavior
  ----------------------------------- -----------------------------------
  `OverrideExistingItem`              Incoming items replace
                                      corresponding existing items while
                                      destination-only items can remain.

  `KeepExistingItem`                  Existing destination items are
                                      preserved rather than overwritten
                                      by corresponding incoming items.

  `OverrideExistingTree`              Make the selected destination tree
                                      correspond to the incoming tree;
                                      destination-only descendants may be
                                      removed.
  -----------------------------------------------------------------------

`OverrideExistingItem` is the safer general-purpose default when the
goal is to update source content without intentionally removing
destination-only descendants.

Use `OverrideExistingTree` only when tree replacement semantics are
intentional.

## Previewing a refresh

Always preview a new or modified manifest before executing it.

Example:

``` powershell
.\Invoke-SitecoreContentRefresh.ps1 `
    -SourceEnvironment UAT `
    -DestinationEnvironment DEV `
    -ManifestPath ".\environment-item-manifests\uat.json" `
    -Mode Preview
```

Example output:

``` text
SitecoreAI Content Refresh

Source:      UAT
Destination: DEV
Database:    master
Mode:        Preview

Included item trees:

  ItemPath:      /sitecore/content/Home/Test
  Scope:         ItemAndDescendants
  MergeStrategy: OverrideExistingItem

PREVIEW ONLY. No Sitecore content was modified.
```

### What Preview means

Preview validates and displays the **transfer plan**.

It verifies such things as:

-   The manifest is valid JSON.
-   A database is specified.
-   At least one `DataTrees` entry exists.
-   Every entry has an item path.
-   `Scope` contains a supported value.
-   `MergeStrategy` contains a supported value.
-   Source and destination are allowed.

Preview does **not**:

-   Authenticate to Sitecore.
-   Verify that an item exists in the source environment.
-   Compare source and destination content.
-   Calculate creates, updates, or deletes.
-   Call the Content Transfer API.
-   Call the Item Transfer API.
-   Modify Sitecore.

It is therefore a configuration preview, not a content diff.

## Executing a refresh

After reviewing the preview, execute the transfer using:

``` powershell
.\Invoke-SitecoreContentRefresh.ps1 `
    -SourceEnvironment UAT `
    -DestinationEnvironment DEV `
    -ManifestPath ".\environment-item-manifests\uat.json" `
    -Mode Execute `
    -Confirm REFRESH
```

`REFRESH` is case-sensitive.

For example, this will fail:

``` powershell
-Confirm refresh
```

This requirement is intentional protection against accidental execution.

## Parameters

  ---------------------------------------------------------------------------------
  Parameter                  Required          Values/default    Description
  -------------------------- ----------------- ----------------- ------------------
  `SourceEnvironment`        Yes               `PROD`, `UAT`,    Environment from
                                               `DEV`             which content is
                                                                 exported.

  `DestinationEnvironment`   Yes               `UAT`, `DEV`      Environment into
                                                                 which content is
                                                                 loaded. PROD is
                                                                 deliberately
                                                                 excluded.

  `ManifestPath`             Yes               Existing JSON     Path to the
                                               file              content-transfer
                                                                 manifest.

  `Mode`                     No                `Preview`,        Controls whether
                                               `Execute`;        the script only
                                               default `Preview` displays the plan
                                                                 or performs the
                                                                 transfer.

  `Confirm`                  Execute only      `REFRESH`         Required exact
                                                                 confirmation for
                                                                 Execute mode.

  `PollIntervalSeconds`      No                Default `5`       Number of seconds
                                                                 between API status
                                                                 checks.

  `TimeoutSeconds`           No                Default `1800`    Maximum wait time
                                                                 for an
                                                                 asynchronous
                                                                 operation before
                                                                 failing.
  ---------------------------------------------------------------------------------

Example with custom polling settings:

``` powershell
.\Invoke-SitecoreContentRefresh.ps1 `
    -SourceEnvironment PROD `
    -DestinationEnvironment UAT `
    -ManifestPath ".\environment-item-manifests\prod.json" `
    -Mode Execute `
    -Confirm REFRESH `
    -PollIntervalSeconds 10 `
    -TimeoutSeconds 3600
```

## What happens during execution

An Execute run performs the following sequence:

1.  Load and validate the manifest.
2.  Validate the source/destination combination.
3.  Require the `REFRESH` confirmation.
4.  Load source and destination configuration from environment
    variables.
5.  Authenticate independently to the source and destination
    environments.
6.  Create a Content Transfer in the source environment.
7.  Wait for Sitecore to generate transfer chunks.
8.  Download each chunk from the source.
9.  Read the chunk's `IsMedia` metadata.
10. Stream the unchanged chunk bytes to the destination Content Transfer
    API.
11. Complete each destination chunk set, producing a `.raif` file.
12. Clean up the source Content Transfer resources.
13. Verify that each destination RAIF blob is in the `Uploaded` state.
14. Submit the RAIF to the destination Item Transfer API.
15. Poll the destination blob until it reaches a terminal state.
16. Treat `Transferred` as success.
17. Treat `TransferredWithErrors` as failure.
18. Delete successfully consumed destination blobs.
19. Print a completion summary.

The script streams chunks between environments. It does not
intentionally deserialize and recreate the transferred Sitecore data
locally.

## Understanding the output

A successful run will progress through stages similar to:

``` text
==> Authenticating to UAT

==> Authenticating to DEV

==> Creating Content Transfer <guid> in UAT

==> Waiting for UAT to generate transfer chunks
Generated 1 chunk set(s).

==> Transferring chunk set <guid> (1 chunk(s))
  Chunk 1 of 1
    IsMedia: False
  Completing chunk set <guid>
  Created contentTransfer-....raif

==> Cleaning up UAT Content Transfer resources

==> Loading contentTransfer-....raif into DEV
  Initial blob state: Uploaded
  Item Transfer submitted.
  Waiting for Item Transfer to complete...
    BlobState: ...
    BlobState: Transferred
  Final blob state: Transferred
  Transfer completed successfully.

==> Content refresh completed successfully
```

The number of chunk sets and chunks depends on the content selected by
the manifest.

## Failure behavior

The script uses terminating errors. A failed operation causes the script
to fail rather than silently continue as though the refresh succeeded.

This is important for GitHub Actions because a terminating PowerShell
error results in a failed workflow step.

### `TransferredWithErrors`

`TransferredWithErrors` is treated as a failure, even though Sitecore
may have successfully transferred some content.

This prevents a partially successful refresh from being reported as a
successful CI/CD operation.

### Cleanup

Source Content Transfer resources are deleted after the destination RAIF
files have been created.

Successfully consumed destination RAIF blobs are also deleted.

Some cleanup operations are intentionally best-effort. If cleanup itself
fails, the script can emit a warning so that the original transfer
result is not obscured.

If execution fails partway through, temporary transfer resources may
remain in Sitecore and may require investigation or cleanup.

## Troubleshooting

### Authentication returns `401 Unauthorized`

Check:

-   The client ID belongs to the intended environment.
-   The client secret is correct.
-   The client secret has not expired or been rotated.
-   The expected environment variables are populated.

You can verify that variables exist without printing a secret:

``` powershell
$env:SITECORE_UAT_HOST
$env:SITECORE_UAT_CLIENT_ID
[string]::IsNullOrWhiteSpace($env:SITECORE_UAT_CLIENT_SECRET)
```

The final command should return:

``` text
False
```

### Authentication returns `403 Forbidden`

Verify that the automation client has the permissions required by the
Sitecore APIs.

Also inspect the complete error response. If the error contains a URL
such as:

``` text
mimecastprotect.com
```

where Sitecore expects:

``` text
https://api.sitecorecloud.io
```

a URL has probably been rewritten by an email security system.

Use the literal Sitecore URLs rather than security-wrapped links.

### `Required environment variable ... is not defined`

The current PowerShell process does not have all configuration required
for the selected source and destination.

For example:

``` text
Required environment variable 'SITECORE_UAT_CLIENT_SECRET' is not defined.
```

Set the missing variable and rerun the command.

### Source and destination hosts are identical

The script deliberately refuses to continue if both environment
configurations resolve to the same hostname.

Check the `SITECORE_<ENV>_HOST` variables. This protects against
accidentally labeling the same Sitecore environment as two different
logical environments.

### Manifest validation fails

Check:

-   JSON syntax.
-   `Database`.
-   `DataTrees`.
-   `ItemPath`.
-   `Scope`.
-   `MergeStrategy`.

Run Preview mode after correcting the file.

### Content Transfer times out

The default timeout is 30 minutes.

For unusually large transfers, increase it:

``` powershell
-TimeoutSeconds 3600
```

Do not immediately assume that a timeout means Sitecore stopped
processing. Investigate the transfer state before retrying a large or
potentially destructive operation.

### `TransferredWithErrors`

The Item Transfer completed only partially.

The script fails intentionally in this state and reports the error
information returned with the blob status when available.

Investigate the Sitecore transfer error before treating the destination
as successfully refreshed.

### A run fails after Item Transfer was submitted

Do not assume that no content changed.

Once the script reports:

``` text
Item Transfer submitted.
```

Sitecore has been asked to consume the RAIF. A subsequent polling,
networking, or local-script failure does not necessarily roll that
operation back.

Inspect the destination environment before retrying if
duplicate/repeated execution would be significant.

## GitHub Actions usage

The script is designed so the same PowerShell implementation can be
called locally and from GitHub Actions.

The recommended CI/CD design uses separate manually triggered workflows:

``` text
refresh-sitecore-dev.yml
refresh-sitecore-uat.yml
```

The destination is fixed by the workflow. This reduces the chance that
an operator accidentally selects the wrong destination.

For a DEV refresh, valid sources are:

``` text
PROD
UAT
```

For a UAT refresh, valid sources are:

``` text
PROD
DEV
```

The workflows should use `workflow_dispatch`, not a scheduled or
deployment-triggered refresh.

### GitHub variables and secrets

Environment hostnames can be stored as GitHub configuration variables if
desired.

Client IDs and client secrets should be stored as GitHub Actions
secrets.

The workflow should expose them to the PowerShell process using the same
environment-variable names expected by the script.

Conceptually:

``` yaml
env:
  SITECORE_PROD_HOST: ${{ vars.SITECORE_PROD_HOST }}
  SITECORE_PROD_CLIENT_ID: ${{ secrets.SITECORE_PROD_CLIENT_ID }}
  SITECORE_PROD_CLIENT_SECRET: ${{ secrets.SITECORE_PROD_CLIENT_SECRET }}

  SITECORE_UAT_HOST: ${{ vars.SITECORE_UAT_HOST }}
  SITECORE_UAT_CLIENT_ID: ${{ secrets.SITECORE_UAT_CLIENT_ID }}
  SITECORE_UAT_CLIENT_SECRET: ${{ secrets.SITECORE_UAT_CLIENT_SECRET }}

  SITECORE_DEV_HOST: ${{ vars.SITECORE_DEV_HOST }}
  SITECORE_DEV_CLIENT_ID: ${{ secrets.SITECORE_DEV_CLIENT_ID }}
  SITECORE_DEV_CLIENT_SECRET: ${{ secrets.SITECORE_DEV_CLIENT_SECRET }}
```

Preview mode does not require these credentials because it exits before
authentication.

## Recommended operating procedure

For a new or changed refresh definition:

1.  Edit the appropriate manifest.
2.  Review every `ItemPath`, `Scope`, and `MergeStrategy`.
3.  Run the script in `Preview` mode.
4.  Confirm that the displayed source and destination are correct.
5.  Confirm that every displayed item tree is intentionally included.
6.  Pay particular attention to any `OverrideExistingTree` entries.
7.  Run in `Execute` mode with `-Confirm REFRESH`.
8.  Review the output and ensure the final result is successful.
9.  Verify representative content in the destination environment.

For production-originated refreshes, remember that PROD is the **source
of content**, not a destination. This tool is deliberately incapable of
writing content back to PROD.

## Example commands

### Preview UAT → DEV

``` powershell
.\Invoke-SitecoreContentRefresh.ps1 `
    -SourceEnvironment UAT `
    -DestinationEnvironment DEV `
    -ManifestPath ".\environment-item-manifests\uat.json" `
    -Mode Preview
```

### Execute UAT → DEV

``` powershell
.\Invoke-SitecoreContentRefresh.ps1 `
    -SourceEnvironment UAT `
    -DestinationEnvironment DEV `
    -ManifestPath ".\environment-item-manifests\uat.json" `
    -Mode Execute `
    -Confirm REFRESH
```

### Preview PROD → UAT

``` powershell
.\Invoke-SitecoreContentRefresh.ps1 `
    -SourceEnvironment PROD `
    -DestinationEnvironment UAT `
    -ManifestPath ".\environment-item-manifests\prod.json" `
    -Mode Preview
```

### Execute PROD → UAT

``` powershell
.\Invoke-SitecoreContentRefresh.ps1 `
    -SourceEnvironment PROD `
    -DestinationEnvironment UAT `
    -ManifestPath ".\environment-item-manifests\prod.json" `
    -Mode Execute `
    -Confirm REFRESH
```

### Execute DEV → UAT

``` powershell
.\Invoke-SitecoreContentRefresh.ps1 `
    -SourceEnvironment DEV `
    -DestinationEnvironment UAT `
    -ManifestPath ".\environment-item-manifests\dev.json" `
    -Mode Execute `
    -Confirm REFRESH
```

## API overview

The script coordinates two Sitecore APIs.

### Content Transfer API

Used to:

-   Define the source item trees.
-   Generate transfer chunks.
-   Download source chunks.
-   Upload chunks to the destination.
-   Generate the destination RAIF package.

Base path:

``` text
/sitecore/api/content/transfer/v1
```

### Item Transfer API

Used to consume the generated RAIF package into the destination Sitecore
database and monitor its blob state.

Base path:

``` text
/sitecore/shell/api/v3/ItemsTransfer
```

The script deliberately encapsulates these API details. Normal operators
should use the script rather than manually reproducing its HTTP
sequence.

## Scope of this tool

This is a focused content-refresh utility, not a general Sitecore
synchronization platform.

It does not provide:

-   Bidirectional synchronization.
-   Automatic conflict resolution beyond Sitecore's selected merge
    strategy.
-   A graphical interface.
-   Scheduled synchronization.
-   Automatic deployment-triggered synchronization.
-   A source/destination content diff.
-   Automatic discovery of which Sitecore trees should be transferred.
-   A mechanism for writing to PROD.

The manifest is the authoritative definition of what content is included
in a refresh.
