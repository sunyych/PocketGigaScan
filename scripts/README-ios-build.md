# iOS build artifacts

The `ios-build.yml` workflow runs on GitHub's `macos-15` runner with Flutter 3.44.2. It builds the pinned Rust/OpenCV/libjxl core first, then builds two unsigned app bundles:

- PocketGigaScan-iOS-device-release-unsigned.zip: iPhoneOS Release app.
- PocketGigaScan-iOS-simulator-debug-unsigned.zip: iOS Simulator Debug app.

Each ZIP contains the corresponding `Runner.app` bundle and a `native-evidence/` directory with the exact native build manifest and dependency license/notice files. The workflow also uploads a JSON build manifest, a README, and a SHA-256 sidecar for each ZIP. The packager checks the bundle ID against `com.lumiaiq.pocketgigascan`, checks the app version and build number against `pubspec.yaml`, confirms the device or simulator platform and arm64 executable slice, verifies that Xcode compiled the `AppIcon` catalog into `Assets.car`, validates the native archive SHA-256 entries and license files, and inspects the built app executable with `nm` for the Rust FFI ABI exports `lumia_gigascan_abi_version`, `lumia_gigascan_job_json`, `lumia_gigascan_free`, and `lumia_gigascan_is_available`. Codec capabilities in the manifest are the native build's declared contract; CI separately confirms runtime capabilities and exports with a synthetic 128×96 single-tile job through the public `NativeJobApi`, including PNG/TIFF/JPEG and JXL when available.

These are unsigned build-verification packages, not installable IPAs. The ABI check confirms the linked symbols, and the simulator smoke confirms basic job/export runtime behavior; neither qualifies image quality on real photographs. Apple code signing, TestFlight distribution, and physical-device installation are not qualified by this workflow.

## Build locally on a Mac

Use a Mac with Xcode command-line tools, Flutter 3.44.2, Rust 1.88, and the Apple SDKs available. From the repository root, build both unsigned app bundles and their verification archives with:

```sh
scripts/build-stitch-ios.sh --cache-dir .build/ios-core-cache --output-dir .build/ios-artifacts
```

The first native build downloads pinned source/dependency archives into the selected cache and can take a long time. The helper builds arm64 device and Apple Silicon simulator slices; use `--include-intel-simulator` only when a local Intel simulator is required. It stages native archives and a generated Xcode configuration inside the iOS project. Review `ios/Native/build-manifest.json` and each packaged manifest for source revision, dependency pins, target, architecture, and archive hashes.

The builder identifies the source with the current Git commit. If building from a source archive without `.git`, provide the archive's 40-character source revision through `LUMIA_SOURCE_REVISION` or a repository-root `SOURCE-REVISION` file.

CI reuses only the pinned OpenCV/libjxl dependency source and SDK build directory, keyed by runner OS, architecture, and `scripts/ios-dependencies.lock.json`. It does not cache Cargo's Rust target directory, staged app archives, or the generated native manifest; Rust and current-source packaging are rebuilt on each run.

The resulting packages use `--no-codesign`; they cannot be installed directly on an iPhone. To create a locally signed development archive, select the `Runner` target in `Apps/Flutter/stitch_app/ios/Runner.xcworkspace` → **Signing & Capabilities** → **Team**, and choose the Apple Developer Team that owns the registered test device and provisioning profile. The equivalent command uses that Team ID explicitly:

```sh
xcodebuild -workspace Apps/Flutter/stitch_app/ios/Runner.xcworkspace \
  -scheme Runner -configuration Release -destination 'generic/platform=iOS' \
  -archivePath .build/ios/PocketGigaScan.xcarchive \
  DEVELOPMENT_TEAM=ABCDE12345 CODE_SIGN_STYLE=Automatic archive
```

Replace `ABCDE12345` with the Team ID selected in Xcode. Do not treat a successful unsigned CI artifact as an App Store or TestFlight release; signing, provisioning, archive validation, and a real-device run remain separate checks.

`integration_test/ios_native_smoke_test.dart` creates its own small JPEG from a generated color pattern in the app temporary directory. It does not read user photos, invoke image pickers, or load scene-analysis models. The test uses a nominal 1×1 grid only to exercise the native job lifecycle without requiring feature matching; its output is a contract smoke, not a panorama quality test.
