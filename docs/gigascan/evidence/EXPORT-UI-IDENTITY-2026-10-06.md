# Export, completed-task presentation and application identity

PG-050 follows the user's six explicit shared-platform corrections and their
additional application-ID instruction. Work uses the shared Flutter shell and
vendored native engine; no retired camera application is restored.

## Scoped implementation plan

- TIFF and PNG remain lossless; JPEG XL becomes actual high-quality lossy RGB
  compression at libjxl distance 1.0 (JPEG-style quality 90), with exact alpha.
  Existing exported files are not rewritten.
- Output format is selected before a new render. Completed tasks expose a
  create-copy action to return to editable pre-render settings.
- Completed tasks hide processing progress, mapping and stitch controls;
  result viewing/sharing and actionable export recovery remain available.
- Informational diagnostics/performance logs start collapsed, open on demand
  and reset when selecting another task. Actionable errors stay visible.
- English and Chinese follow the system for auto-export options, dynamic
  summaries, task phases and collapsed-panel labels.
- Current application identity becomes `com.lumiaiq.pocketgigascan`. Android's
  package and channels agree. Windows identifies the app with this namespace
  and retains lookup of old `com.lumia` task directories. The new Android ID
  coexists with the old package; no uninstall or user-data removal is performed.

## Verification

The coordinator runs formatting/core tests with independent `djxl` decoding,
both-locale shared Flutter tests/analysis, builder contracts, a normal Windows
Release source build and Android native/APK checks. The phone is still absent
from ADB at inspection on 2026-10-06; physical Android validation remains pending.
The final shared sources pass the complete normal Windows source builder:

- Rust formatting and 162 core tests pass; two real-data tests remain ignored.
  The independent official `djxl` decoder exercised Unicode paths, a
  2057×2065 tile-edge case and a 256×256 textured fixture. Dimensions and alpha
  are exact; alpha-weighted RGB mean absolute error is at most 8/255, and the
  textured fixture requires changed opaque RGB samples to reject accidental
  lossless encoding. This is synthetic codec/geometry evidence, not every-seam
  acceptance of the user's full photograph set.
- Flutter analysis is clean and all 175 normal tests pass, including both
  system locales, shared Windows/Android presentation, automatic export/retry,
  copied settings, queue ownership, preserved records and viewer interactions.
  The info panel starts collapsed; completed controls/progress are absent.
  Six intended queue/format screenshot baselines were reviewed and updated,
  followed by the full normal suite. Widget screenshots use test fonts and
  validate layout rather than native desktop/phone typography.
- Both Windows and Android builder contracts pass. The Windows builder performs
  a normal `lib/main.dart` Release source build, loads the packaged core to probe
  all three formats, verifies archive members and includes runtime/dependency
  licenses. The actual EXE reports company `com.lumiaiq`, product PocketGigaScan
  and version `1.2.1+12`. Its compiled runner sets the new AppUserModelID.
- Android's new Kotlin namespace passes all 5 JVM policy tests. Lint reports
  zero errors and 9 existing warnings; these host checks do not prove Android
  lifecycle, file-picker or device rendering behavior.

The Windows ZIP is 20,521,358 bytes, SHA-256
`18b22c3587aff664cfcb87816549a022200201282a497fd49380b24f4d0e4464`.
The local qualified copy is named
`PocketGigaScan-Windows-x64-v1.2.1-12.zip`; extract the complete ZIP.
The executable is unsigned. Native source builds used verified dependency SDKs;
no previously built sibling engine DLL was substituted.

## Android package and device boundary

The final ARM64 core and APK are rebuilt from this revision's vendored source.
Actual package inspection passes. The new
package uses `com.lumiaiq.pocketgigascan`, version `1.2.1+12`, minimum API 29 and
target API 36. The retained legacy package is not uninstalled or cleared; its
private tasks cannot be automatically read by the new package.

- APK: `PocketGigaScan-Android-arm64-v1.2.1-12.apk`, 38,668,439 bytes, SHA-256
  `806a529be36af3f4eec40fa43fd7c963f5e046d8e35b3f526abfbfc1a813532a`.
- Exactly five ARM64 libraries are bundled: Flutter/app/Dart JNI, the core and
  shared C++ runtime. No other ABI, native test executable or staging residue is
  included. All actual ELF LOAD segments and uncompressed ZIP library entries
  pass 16 KiB alignment checks. The core exposes the nine expected C ABI calls
  and depends only on the bundled C++ runtime and allowed Android system libs.
- The complete native license inventory verifies 135 files against their
  hashes. Flutter's compressed notices also include `jni` and `jni_flutter`.
- The source-tree hash matches the staged manifest:
  `c6c90ce1747b9454158155c7a7b815ec7b57e95b87dd401155335ad192e5078e`.
  The staged pre-strip core hash is
  `89d68b422bcff91b9dae2c85851da7dc82019886b9ea986df0635a59ae6efe8a`;
  Gradle's actual stripped APK core hash is
  `554fabcfdabba8f8b6ef8dbce2b0a7ce410b6f790f4590e21942504416b19433`.
- APK Signature Scheme v2 verifies using the development Android Debug key.
  This is a sideloadable development release, not a Play Store signing release.

Both source builds ran before committing the reviewed edits; historical Git
base IDs in local build manifests therefore precede this fix commit. The native
tree hash, actual binary hashes and checks above identify the tested content.

ADB again reports no device at the final pre-package check. Installation,
on-device FFI exports, system file picking/saving, background recovery, and
physical EN/ZH viewer screenshots remain pending. This does not qualify large
real Android exports or iOS execution. Future iOS packaging reserves the same
bundle ID; the ignored local iOS scaffold is not part of the published source.

JPEG XL mode choices follow the [official encoder API](https://libjxl.readthedocs.io/en/latest/api_encoder.html#c.JxlEncoderSetFrameDistance).
Logs, build caches and deliverables stay under ignored `.local/` paths.
