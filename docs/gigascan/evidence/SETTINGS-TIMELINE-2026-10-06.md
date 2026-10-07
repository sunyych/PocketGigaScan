# PG-053: settings and timestamped stitching logs

Application version: `1.3.0+14`. Branch: `codex/settings-stitch-timeline`.
Final application source: `a2b7045e2b7b545b44d5f495756d01384b0d3288`.
Subsequent documentation commits do not change the packaged application.
[Review PR #5](https://github.com/sunyych/PocketGigaScan/pull/5).

## Behavior

Settings persist independently of task records: system/English/Chinese language,
system/light/dark appearance, accent color, output quality, performance defaults
and output folder. Language/theme changes apply immediately. Processing defaults
are snapshotted for new tasks/queues; existing task options remain intact.
Preferences use serialized writes and recoverable file replacement.

Stitch details and Stitching log are independently collapsed. Log rows keep local
timestamps on the left and localized step text on the right. Rust records stage,
state and operation transitions at their source; polling merges that history.
Inner-loop stages are grouped and progress-only updates do not add log entries.
Batch comparisons normalize the same stage families to prevent duplicate rows.
The summary shows full start/finish dates and elapsed wall-clock time through
pauses, automatic encoding and destination publication. Legacy recovery/export
cannot establish the original start time, so their full duration stays unknown.

Windows encodes directly into its configured output folder. Android retains a
writable SAF tree grant, encodes privately and automatically streams the result
to that tree. Failed publication retains the private result and offers retry
without another encode. Reopening a completed publication does not duplicate it.
Task deletion during copying retains a successfully created destination file;
only newly created incomplete documents are cleaned up after copy failure.
Original photos and completed exports are never deleted by task removal.

## Automated checks

- Dart formatting and Flutter analysis pass. All **208 Flutter tests** pass in
  the normal Windows builder, including EN/ZH presentation, live settings,
  persistence/races, existing-task isolation, direct Windows destination,
  independent panels, timestamp geometry, legacy recovery/export, native-event
  deduplication, batch defaults, automatic publication, retry, restart and stale
  ownership. Storage/native APIs in host functional tests use explicit fakes.
- Rust formatting passes with 1.88.0. **172 native tests pass**: 140 unit tests
  and 32 integration tests. Two real-photo fixture tests remain intentionally
  ignored by the normal builder; they require preserved local fixture paths.
  Synthetic geometry/texture/renderer checks do not qualify real-photo seams.
- Windows and Android build-script contract checks pass. Normal Windows Release
  builds the vendored core from source with verified SDK dependencies, including
  runtime, license, capabilities and archive-integrity checks.
- Android native ARM64 and normal Flutter Release APK builds run from source.
  **7 Kotlin policy tests** pass. Android lint reports **0 errors, 9 warnings**;
  existing warnings are not suppressed. The read/write permission call preserves
  write-only grants and uses explicit constants recognized by lint.

## Packages

Windows x64 ZIP: `PocketGigaScan-Windows-x64-v1.3.0-14-settings-timeline.zip`.
Size: 20,580,928 bytes. SHA-256:
`09d150a3df4e240700732818bd0e74c5aea006696fc0e3a2bd05ddba67572adf`.
Core DLL SHA-256:
`2f0b7896d6e3d3a5ceebfd99a1e577df0753fb9d5866be090cf691c2e0d46a34`.
The complete ZIP includes the x64 MSVC runtime and dependency licenses; the EXE
is unsigned and must be used with its bundled files.

Android APK: `PocketGigaScan-Android-arm64-v1.3.0-14-settings-timeline.apk`.
Size: 38,765,127 bytes. SHA-256:
`ebc0df9c60de6571aa6ee33eda5a68f55dd97b74e23b6c636463d85ed1d50cb1`.
Package: `com.lumiaiq.pocketgigascan`, version `1.3.0` / code `14`, minimum API
29 (Android 10), target API 36, ARM64 only. Inspection verifies the five expected
native libraries, FFI exports, allowed native dependencies, ELF LOAD alignment
of at least 16 KiB, ZIP alignment, APK signature and all 135 native license
files against their manifest hashes. It uses development signing, not a Play
Store distribution key. The ARM64 core manifest records the same final source
commit as Windows. `adb devices -l` returned no connected devices, so no on-device
SAF-provider, foreground-service or large-image viewer qualification is claimed.

## Reproduce

Use `scripts/build-dwarf-stitch-windows.ps1` for the normal Windows source build.
Use `scripts/build-stitch-android-core.ps1 -AndroidSdkRoot D:/Android/Sdk`, then
`flutter build apk --release --target-platform android-arm64` and
`gradlew :app:testDebugUnitTest :app:lintDebug`. See [BUILD](../../BUILD.md).
Build/check logs and packages live in ignored `.local`/`.build` directories;
personal captures, SDK caches and generated binaries are not committed.

No connected-device or new 384-photo visual qualification is claimed here.
Earlier blur/alignment work and its separate evidence remain in this branch.
