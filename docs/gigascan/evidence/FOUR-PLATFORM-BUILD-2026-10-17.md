# Four-platform package qualification

The Windows, Android and macOS artifacts were built from source `db6e1fb`; the iOS-only compiler correction is at `fad7124`. All identify PocketGigaScan 1.5.1+30 (`com.lumiaiq.pocketgigascan`). The hosted checks below qualify platform compilation and package contents. They do not qualify physical-device operation, real-panorama image quality, public signing, notarization or iOS native stitching.

## Windows

The normal source-based Release builder passes 243 native tests (208 unit and 35 integration; three optional real-data fixtures ignored), clean Flutter analysis, 340 Flutter tests and Rust formatting. The unsigned x64 signing-input ZIP contains the source-built core, model, required runtimes and dependency licenses. Package ZIP SHA-256: `3f1ffaa083766c4b381690596621c9b0dd8cba293096dc47ba0354069ee7a486`. The separate signing job remains gated on complete SignPath configuration; no signed public release is qualified.

## Android

Hosted run `39099909168` builds the ARM64 native core and Release APK. The package uses `com.lumiaiq.pocketgigascan`, version 1.5.1/code 30, minimum API 29 and target API 36. APK ZIP integrity, v2 development signature, native symbols/dependencies, 16 KiB ELF load alignment and compiled launcher icon were checked. No phone installation, camera operation or real-panorama acceptance is established by these package checks.

## macOS

Hosted Apple Silicon run `39099909218` passes 12 package contracts, 340 Flutter tests, 241 native tests (three optional fixtures ignored), normal Release compilation, bundled model inference and PNG/TIFF/JPEG XL export checks. The app targets arm64 and macOS 14 or newer and is ad-hoc signed for testing, not notarized. ZIP size: 273,344,979 bytes. ZIP SHA-256: `836b98a197033920c83e027f325c293618b1ee29436b8005f614e67f2b8e8580`.

## iOS

Hosted run `39100727380` compiles an unsigned arm64 device Release app and unsigned arm64/x86_64 simulator Debug app. Bundle/version/platform/architecture metadata and compiled AppIcon assets were checked; both artifacts include SHA-256 receipts. The iOS build remains native-free: the existing Dart camera import and transfer code is present, but the Rust stitching engine is not linked into the iOS runner. Signing, physical-device installation, TestFlight and on-device camera transfer/stitching remain unqualified.
