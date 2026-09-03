# JAMF Get DDM Info

`JAMFGetDDMInfo.sh` is a SwiftDialog-based utility for retrieving and reporting Declarative Device Management information from Jamf Pro.

The script can:

- Scan all managed computers for a specific Blueprint
- Display DDM information for an individual computer
- Scan computers in a Jamf smart or static group
- Request a DDM status synchronization for an individual computer
- Export Blueprint and DDM results to CSV
- Export individual computer results to a text file
- Associate Blueprint UUIDs with friendly Blueprint names
- Report active, inactive, failed, invalid, conditional, and missing Blueprint deployments
- Report DDM software update failures and device information

## Current Development Version

**Version:** `1.0RC6`

This development version contains significant changes from the `1.0RC5` version currently published in the GitHub repository.

GitHub source:

[View the published JAMFGetDDMInfo.sh source](https://github.com/ScottEKendall/JAMF-Pro-Scripts/blob/main/JAMFGetDDMInfo/JAMFGetDDMInfo.sh)

---

# Summary of Changes from RC5 to RC6

## Blueprint Classification

Blueprint evaluation has been reworked to assign a single final classification to the requested Blueprint on each computer.

The classification precedence is:

1. Invalid
2. Failed
3. Conditional
4. Active
5. Inactive
6. Not Found

A Blueprint is classified as `Conditional` when Jamf reports both active and inactive state indicators for the same Blueprint.

The final classification is now used consistently for:

- SwiftDialog status display
- Result filtering
- CSV filtering
- CSV status values
- Logging

This prevents a computer from being displayed under one status while being exported under another.

## Independent Blueprint State Detection

Blueprint status indicators are evaluated independently.

A single Blueprint may therefore appear in more than one internal state array when the Jamf DDM response contains multiple indicators.

The script tracks:

- `DDMBlueprintSuccess`
- `DDMBlueprintInactive`
- `DDMBlueprintInvalid`
- `DDMBlueprintFailed`

The final Blueprint classification resolves overlapping states according to the classification precedence.

## Blueprint Result Filters

The Blueprint scan now supports the following result filters:

- Everything
- Failed Only
- Invalid Only
- Active Only
- Inactive Only
- Active & Inactive
- Not Found Only

Filtering is based on the final Blueprint classification rather than individual raw state indicators.

For example:

- A Blueprint containing both `active=true` and `valid=invalid` is classified as `Invalid`.
- It appears under `Invalid Only`.
- It does not appear under `Active Only`.

## Display-Only-Matching Option

A new `Display only matching systems` option is available for Blueprint scans.

When enabled:

- Computers matching the selected result filter remain in the SwiftDialog list.
- Computers that do not match are removed from the list.
- Computers that could not be evaluated because of an API, management ID, or parsing error remain visible as errors.

When disabled:

- All evaluated computers remain visible.
- CSV output continues to honor the selected result filter.

## Improved Not Found Handling

Blueprints that are not present in a computer's DDM response are now handled separately and consistently.

A Not Found result:

- Is displayed when the filter is `Everything`
- Is displayed when the filter is `Not Found Only`
- Is removed when display filtering is enabled with another filter
- Is exported only when the selected CSV result filter permits it
- Uses `Not Found` as the CSV status

## CSV Output Improvements

CSV creation has been hardened for concurrent scans.

### CSV write locking

Background workers no longer write directly to the CSV file without coordination.

The `append_csv_line` function uses an atomic directory lock so only one worker can append a row at a time.

This protects against:

- Interleaved CSV records
- Truncated rows
- Concurrent write collisions
- Corrupted report output

### CSV field escaping

CSV field values are passed through `csv_escape`.

The function:

- Removes carriage returns
- Converts embedded newlines to escaped `\n` values
- Escapes embedded double quotes
- Wraps every field in double quotes

This improves compatibility when values contain commas, quotes, multiline failure descriptions, or Blueprint error details.

### Consistent CSV status

Blueprint CSV status now comes directly from the final classification:

- Active
- Inactive
- Conditional
- Failed
- Invalid
- Not Found

## Background Worker Management

Parallel processing has been reworked into the shared `execute_in_parallel` function.

The function:

- Supports Blueprint and group scans
- Limits concurrent workers using `BACKGROUND_TASKS`
- Stores worker process IDs
- Waits for workers before returning
- Tracks failed worker processes
- Reports worker failures to the caller
- Prevents the main workflow from returning to the menu before the scan dialog is closed

The default worker limit is:

```zsh
BACKGROUND_TASKS=10