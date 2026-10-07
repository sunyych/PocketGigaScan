# Windows import and task-storage evidence

Status: implementation reviewed; serial host/build and native UI qualification
in progress. Original photographs, prior exports and legacy task roots retained.

## Read-only storage diagnosis

The observed local 1.3.3 workspace EXE inherits Windows Low Mandatory Level with
No-Write-Up; its process token is RID 4096 (low), while Explorer is RID 8192
(medium). The existing legacy task root and task directory grant the user's
account FullControl, are ordinary directories, and have no read-only flag or
reparse point. No matching Defender Controlled Folder Access block was observed.

A fresh copy into a normal Downloads directory has no low mandatory label and
starts at RID 8192. The unchanged 1.3.3 native picker opens, renders thumbnails
and cancels successfully there. This establishes the development-directory
integrity issue; it does not by itself explain every historical import crash.
See Microsoft's [mandatory integrity documentation](https://learn.microsoft.com/en-us/windows/win32/secauthz/mandatory-integrity-control).

Read-only event review found historical 1.3.2/1.2.1 ucrtbase.dll fatal exits
(0xc0000409, fatal-app-exit subcode 7), without a matching usable minidump.
Third-party shell extensions are present; no specific extension is established
as the cause. Windows EXE Authenticode status is NotSigned. SmartScreen signing
and reputation remain separate from import/task-storage qualification.

## Changes and regression scope

Windows photo and folder selection now use Flutter's endorsed file_selector
Common Item Dialog plugin. JPEG multiselect remains unrestricted; files are
streamed after selection rather than preloaded in memory. Other platforms keep
file_picker and Android's existing SAF bridges. Folder prompts/errors are
covered in English and Chinese.

Task removal commits the metadata tombstone before durable batch references
are dropped. An injected errno-5 tombstone failure must preserve task and queue
ownership, originals and exports, then permit a successful retry.

Adapter tests cover 37 and 1025 entries, jpg/jpeg filters, Unicode names,
metadata/order, cancellation/errors and mobile streaming flags. Host workflow
checks exercise cancellation/error reuse in both locales and 37 valid JPEGs
with distinct hashes. A fixture-dependent Windows-engine test exercises the
complete real copied-photo set and explicitly skips without its external define;
it substitutes only selection and is distinct from native dialog UI evidence.

## Qualification

Flutter analysis is clean and all 284 host tests pass. Final deletion-loop
review is additionally covered by all 33 batch-controller tests. Host import
copy/persistence runs as a real-clock service test; widget tests cover cancel,
error reuse and count presentation separately. The full native Windows import
workflow remains a separate integration/UI qualification.

Normal Windows/Android Release packages and native dialog/full-import checks
remain in progress. This patch does not change stitching
geometry, source comparisons, renderer pixels or calibration limits.

## Release isolation guard

The first local Release package was rejected during independent archive review:
Flutter clean reported a locked generated directory but exited successfully,
leaving an earlier integration-test kernel in the shared Flutter asset directory.
That package was not staged for download or published. The builder now validates
both owned cleanup targets before deleting generated Flutter assets and Release
output, fails on incomplete removal, and requires AOT app.so while rejecting
debug snapshots and the integration-test plugin before packaging. Temporary
contract fixtures verify valid AOT output, debug/plugin rejection, containment
and preservation of unrelated Debug output. The contract suite passes.
