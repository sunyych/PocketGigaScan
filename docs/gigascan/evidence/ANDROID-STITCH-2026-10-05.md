# Android stitcher qualification

PG-049 is in progress on `codex/android-stitcher`, based on Windows baseline
`846ec8e5671f804911d03d785d8bcb85226c8f79`. Android implementation uses the
retained Flutter application and vendored `native/core`; retired camera apps
are not restored. The coordinator owns build/device execution and independent
review; Luna coders own native, platform and shared UI changes.

## Connected device inventory

ADB initially identified Moto g play (2024), Android 14
(API 34), ARM64, 720×1600 pixels, density 280. Reported physical memory is
3,747,716 KiB, with approximately 1.4 GiB available at inspection. Internal
storage had approximately 36 GiB free. The device reports 4096-byte pages;
16 KiB ELF/ZIP checks do not establish physical 16 KiB runtime qualification.
No existing `com.lumia.stitch_app` package was present at inspection. The USB
serial is retained only in local validation records.

The device subsequently disappeared from `adb devices -l`. Reconnection was
requested while source builds and host tests continue. Physical qualification
is pending until it reconnects and the new APK runs there.

## Results recorded so far

- Flutter storage/runtime bridge tests: 5 passed. These use mocked method
  channels and qualify Dart argument/result handling, not Android SAF or
  foreground service operation.
- JPEG XL source inputs are official v0.12.0 and the exact Brotli, Highway and
  skcms revisions pinned by its dependency script. Archive SHA-256 pins are in
  `scripts/build-stitch-android-core.ps1`.
- The first Android JPEG XL configure exposed empty archive submodule
  directories. The coder corrected marker-based dependency population; the
  repeated configure and ARM64 dependency build passed.
- Actual Android Kotlin compilation and 4 JVM policy tests passed after fixing
  an untyped empty-list timeout event. The unit-test invocation temporarily
  excluded `preBuild` and Flutter Dart compilation because the new native core
  had not yet been staged; this result does not qualify a complete APK.
- `cargo fmt --check` passed for the native changes. The first production ARM64
  core compile exposed Windows-only UTF-16 JPEG XL path handling. A portable
  path-ABI repair now preserves Windows UTF-16 and uses native Unix path bytes;
  the subsequent production ARM64 core build passed. Independent ELF inspection
  found four LOAD segments aligned to 0x4000 and a 16 KiB-aligned GNU_RELRO end.
- Full Windows native unit and functional regression: 161 passed, 0 failed,
  2 real-data tests ignored by default. This includes texture seam displacement
  negative controls and horizontal/vertical forced-grid reconstruction. The
  ignored real-data tests were not rerun in this Android task.
- New native coverage checks 33×33 complete grids, 129×2 axes, integer overflow,
  sparse block storage and true PCG residual acceptance. A separate read-only
  review found no blocking sparse-solver correctness defect; a possible pause
  delay in pre-solve O(E) component scans remains a performance consideration.
- Initial full Flutter run: 128 passed, 12 failed. Several assertions describe
  retired mobile charger/disabled-batch behavior; timer ownership and dialog
  pumping also require repair. These failures are not a passing application gate.
- Real-photo device fixtures are copies of central originals from the existing
  384-photo dataset: 2×2, 3×3, and a 1×7 confirmation case. Source and copied
  SHA-256 values match; originals were not modified.
- The repeated ARM64 production and separate test-executable builder passed
  after moving all temporary staging/backups outside APK source roots. Native
  source-tree SHA-256 is `24aa7ca5319e86c0b49bd12d001d09268aa09338a374113b34a9d367b46a3aec`;
  staged production core SHA-256 is `4a53804a0364345847a482390b4eb6a0caf14db8256c74938ae59a3f9ed15d42`.
  Compiling the ARM64 unit executable is not execution evidence.
- Actual Gradle `:app:preBuild` verifies native ABI, file hashes, link metadata
  and the complete dependency license inventory. A deliberately changed
  native-core hash was rejected for that reason, with the original manifest
  restored byte-for-byte afterward.
- Independent review of the mobile viewer covered touch scaling/panning and
  visible-tile eviction. The maximum 131072×131072 sparse canvas test passed
  after correcting the gesture distance needed to reach its far boundary.
  This fixture uses a few small tiles and does not qualify an actual
  multi-gigabyte image on the phone.
- Further application regressions caught and repaired PNG-only mobile format
  policy, queue source-path persistence, and delayed exports incorrectly entering
  a new render. Queue tests now retain the selected-parent path separately from
  verified task-owned input copies. Foreground-service timeout requests are
  persisted for engine reattachment; an absent Activity does not imply immediate
  native pause. The new recovery tests and full application gate are still pending
  execution at this point in the record.

## Final host and packaging gates

The normal Gradle `:app:testDebugUnitTest :app:lintDebug` invocation passed with
native `preBuild` and Flutter compilation enabled: 5 JVM tests, zero failures,
zero lint errors and 9 warnings. Warnings include the intentional synchronous
timeout-record write, conservative SDK guards and available dependency updates.
The SAF persisted-read permission argument was corrected after lint caught it.
The Windows Flutter SDK generates unescaped drive colons in `local.properties`;
a scoped pre-lint normalization now fixes those two generated SDK-path keys,
without editing the SDK or disabling lint checks.

The PowerShell Android builder contract passed, including invalid-ELF negative
controls. Native Windows tests remain 161 passed and 2 ignored; the ARM64 native
test executable has been compiled but has not run on the disconnected phone.

The frozen shared application passed `flutter analyze` with no issues and the
complete normal `flutter test --reporter expanded` run: **159 passed, zero failed**.
This includes desktop screenshot baselines, three mobile export choices,
large-grid cancellation/approval, task-only deletion, low-memory and thermal
admission, streamed-storage bridge payloads, touch/wheel/pan viewer behavior,
tile culling and persisted queue recovery. Delayed exports reuse the completed
render instead of starting it again. A timed-out completed render waits for
explicit continuation before export. The standalone resume regression verifies
that failed durable timeout acknowledgments block resume until saved and never
issue a duplicate native pause.

These host tests use policy mocks and small generated viewer tiles. They do not
establish device codec execution, native SAF UI behavior, background execution
or actual multi-gigabyte viewer memory use. The separate real-photo integration
harness remains ready for the phone to reconnect.

## Android package

The normal `lib/main.dart` release APK builds successfully. Inspection of the
first APK caught unwanted x86 and 32-bit JNI libraries despite NDK ABI filters;
the Flutter Gradle plugin resets those filters. Final packaging now excludes
unselected ABIs. The repeated actual APK contains **ARM64 only**, with exactly
five libraries: Flutter engine, Dart AOT application, `libdartjni`, C++ runtime
and the vendored stitching core. The JNI packages' notices are present in
Flutter's generated `NOTICES.Z`. The normal JVM/lint gate also passes after this
packaging correction, with no additional errors or warnings.

- Package: `com.lumia.stitch_app`; version `1.2.0`, code `11`.
- Minimum Android API 29 (Android 10); target/compile API 36.
- APK: `.local/deliverables/PocketGigaScan-Android-arm64-v1.2.0-11.apk`;
  38,669,259 bytes.
- SHA-256: `5e316574d78267ec2c55e699d40206a6218117fcd5a1db7d8e0292da5df55101`.
- APK v2 signature verifies, using the local Android development key. This is
  not a Play Store signing identity or a physically qualified production release.
- All five actual APK ELF files pass ARM64 and 16 KiB LOAD checks. ZIP alignment
  passes `zipalign -c -P 16 -v 4`; this does not establish physical 16 KiB-device
  execution.
- The actual core exports all nine required C ABI functions and depends only
  on the bundled C++ runtime and Android system libraries.
- 135 native dependency notice/license files match their complete manifest and
  SHA-256 inventory. No staging backups or native unit-test executable are bundled.
- Packaged stripped native-core SHA-256:
  `f9841c1c9abbf441cd3bc505dbde14c2a6658e27ef33c5897bfbf2e00a0abae4`.
  Its staged pre-strip hash and exact source-tree hash are recorded above.

Reproduce package identity and signature checks with the SDK build-tools
`aapt dump badging`, `zipalign -c -P 16 -v 4` and
`apksigner verify --verbose --print-certs` against the actual APK, plus NDK
`llvm-readelf --dyn-syms -d -lW` against libraries extracted from that APK.
The APK and checksum are ignored local deliverables; no binary, source photos,
USB serial or private build cache is staged in Git.

## Physical boundary

The last ADB inventory still reports no connected device. No APK installation,
device FFI export, SAF/save/share flow, on-device screenshots, actual phone
background recovery or multi-gigabyte image test has been performed. These
remain unchecked in the implementation plan. PG-049 stays physically pending;
the branch is suitable for a draft PR and does not replace the published Windows
release. Future iOS packaging and platform adapters remain separate work.

Ignored logs are retained under `.local/android-stitch-validation-20261005/`.
No Android or iOS runtime qualification is claimed from Windows or mocked tests.
