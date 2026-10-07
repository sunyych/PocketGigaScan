# Windows import and task-storage evidence

Status: implementation reviewed; host and Windows-engine import checks and normal
Windows/Android Release builds pass. Latest native-dialog UI check is blocked by
the running Windows screen saver. Original photographs, prior exports and legacy
task roots retained.

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
error reuse and count presentation separately. The actual Windows Flutter-engine workflow test also passes with all 364 JPEGs
(330,560,959 source bytes): it substitutes only selection and uses real streaming
copy, hash/metadata checks, task save/load and UI completion. Source and export
checksums remain unchanged. Native dialog interaction is qualified separately.

The normal Windows source builder passes 212 native tests (two external-original
fixtures ignored), clean Flutter analysis, all 284 host tests, all 32 Python
checks and both builder contracts. Rust formatting and changed Dart formatting
pass. Serial Android ARM64 source build, Release APK, seven Kotlin unit tests
and Release lint pass (zero errors, nine existing warnings). No connected ADB
device is available; Android physical-device execution is unqualified. This
patch does not change stitching geometry, source comparisons, renderer pixels
or calibration limits.

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

## Verified 1.3.4+18 packages

Both packages are built from source commit
`327a8bcfa8f276f276520d5d2a5082f5d57e6d8e` (picker/storage implementation
`15d4338e85f577771a320d8a0008cee48cad5add` plus the Release isolation guard).
Later evidence-only commits do not replace that packaged source identity.

| Package | Bytes | SHA-256 |
| --- | ---: | --- |
| Windows x64 ZIP | 20,813,329 | `cf90e08157a75621531d354cefd3a4cae45cd6b7fc3b615ba9a4a21785f57da8` |
| Android ARM64 APK | 39,318,739 | `2f17e136f9ce73f7aceb8f1477eebbe3ea78050476eb1cdffcb88a2d237b16fe` |

The Windows archive contains 153 members, its AOT app.so, native file-selector
plugin and its license, and no debug or integration-test assets. The core DLL
SHA-256 is unchanged from the qualified 1.3.3 engine:
`dee93f266a208b3798fecc531632d02d70e9cb242d64c42edb431b9395bb0bb4`.
The build manifest identifies the exact source and verified native dependencies.
Android ID is `com.lumiaiq.pocketgigascan`, version 1.3.4/code 18, ARM64 only,
minimum API 29/target API 36. Native exports/dependencies, 16 KiB ELF and ZIP
alignment, the existing development-key APK signature and 135 license files
are independently checked. No signing keys are included in Git.

A fresh Windows extraction into the user's normal Downloads directory has no
Low Mandatory Level label. Its launched process is RID 8192 (medium), and its
accessibility tree loads old tasks and reports the native engine available.
The next native dialog action is blocked by Ribbons.scr: window activation
fails and captures show the screen saver. The user has been asked to return to
the desktop. The new selector's full manual selection/import sequence and a new
AppData task write are **not claimed as completed**. Earlier successful native
open/cancel on unchanged 1.3.3 and the 364-source Windows-engine test are separate
evidence. Authenticode remains NotSigned; no security setting or ACL was relaxed.
