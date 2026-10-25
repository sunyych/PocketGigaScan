# iOS build artifacts

The `ios-build.yml` workflow runs on GitHub's `macos-15` runner with Flutter 3.44.2. It builds the pinned Rust/OpenCV/libjxl core first, then builds two unsigned app bundles:

- PocketGigaScan-iOS-device-release-unsigned.zip: iPhoneOS Release app.
- PocketGigaScan-iOS-simulator-debug-unsigned.zip: iOS Simulator Debug app.

Each ZIP contains the corresponding `Runner.app` bundle and a `native-evidence/` directory with the exact native build manifest and dependency license/notice files. The workflow also uploads a JSON build manifest, a README, and a SHA-256 sidecar for each ZIP. The packager checks the bundle ID against `com.lumiaiq.pocketgigascan`, checks the app version and build number against `pubspec.yaml`, confirms the device or simulator platform and arm64 executable slice, verifies that Xcode compiled the `AppIcon` catalog into `Assets.car`, validates the native archive SHA-256 entries and license files, and inspects the built app executable with `nm` for the Rust FFI ABI exports `lumia_gigascan_abi_version`, `lumia_gigascan_job_json`, `lumia_gigascan_free`, and `lumia_gigascan_is_available`. Codec capabilities in the manifest are the native build's declared contract; CI separately confirms runtime capabilities and exports with a synthetic 128×96 two-tile 1×2-grid job through the public `NativeJobApi`, including PNG, TIFF, JPEG, and JPEG XL.

These are unsigned build-verification packages, not installable IPAs. Hosted run [40241795440](https://github.com/sunyych/PocketGigaScan/actions/runs/40241795440) built and package-verified the iPhoneOS arm64 Release app and arm64 simulator Debug app, and the complete simulator integration smoke passed. It exercised the two-tile native job and PNG/TIFF/JPEG/JPEG XL exports. Ordinary-app replay [40234798847](https://github.com/sunyych/PocketGigaScan/actions/runs/40234798847) showed the native-engine-loaded UI and process survival at 2, 15, and 30 seconds on an arm64 simulator. See [current four-platform build evidence](../docs/gigascan/evidence/FOUR-PLATFORM-BUILD-2026-10-25.md); the [2026-10-17 record](../docs/gigascan/evidence/FOUR-PLATFORM-BUILD-2026-10-17.md) remains historical. Apple code signing, TestFlight, physical iPhone use, and real-photo image quality are separate unqualified checks.

## Build locally on a Mac

### Check out the source

On a fresh Mac, clone the current `codex/security-cleanup` branch:

```sh
git clone --branch codex/security-cleanup --single-branch https://github.com/sunyych/PocketGigaScan.git
cd PocketGigaScan
```

For an existing clone, fetch and switch to that branch, then fast-forward it:

```sh
git fetch origin
git switch codex/security-cleanup
git pull --ff-only origin codex/security-cleanup
```

### Install the pinned tools

The exact pins are recorded in `scripts/ios-dependencies.lock.json`. Install Flutter from its 3.44.2 release tag, then verify that it resolves to the locked framework revision `c9a6c484230f8b5e408ec57be1ef71dee1e77020`:

```sh
mkdir -p "$HOME/development"
git clone --branch 3.44.2 https://github.com/flutter/flutter.git "$HOME/development/flutter-3.44.2"
git -C "$HOME/development/flutter-3.44.2" checkout --detach c9a6c484230f8b5e408ec57be1ef71dee1e77020
export FLUTTER_ROOT="$HOME/development/flutter-3.44.2"
export PATH="$FLUTTER_ROOT/bin:$PATH"
flutter --version --machine
```

The builder checks both the Flutter version and revision against the lock file and exits if either differs. Install the pinned Rust toolchain and targets:

```sh
rustup toolchain install 1.88.0 --profile minimal
rustup target add aarch64-apple-ios aarch64-apple-ios-sim --toolchain 1.88.0
```

The native builder invokes Cargo with `+1.88.0`, so changing the machine-wide default Rust toolchain is not required. Only when building an Intel simulator, also install its target:

```sh
rustup target add x86_64-apple-ios --toolchain 1.88.0
```

Install Xcode with the iOS device and simulator SDKs, accept its license, and select the Xcode developer directory. CMake is also required; with Homebrew, install it using `brew install cmake`.

```sh
sudo xcodebuild -license accept
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
xcode-select -p
xcrun --sdk iphoneos --show-sdk-path
xcrun --sdk iphonesimulator --show-sdk-path
cmake --version
rustc +1.88.0 --version
rustup target list --installed --toolchain 1.88.0
```

These checks confirm the selected Xcode and SDKs are visible; they do not imply that Apple CI has passed.

### Build the unsigned verification packages

From the repository root on macOS, build both unsigned app bundles and their verification archives with:

```sh
scripts/build-stitch-ios.sh --cache-dir .build/ios-core-cache --output-dir .build/ios-artifacts
```

The first native build downloads pinned source/dependency archives into the selected cache and can take a long time. By default, the helper builds arm64 device and Apple Silicon simulator slices. For an Intel Mac simulator, add `--include-intel-simulator`; this also requires the installed Flutter SDK and Xcode toolchain to support the x86_64 simulator destination. It stages native archives and a generated Xcode configuration inside the iOS project. Review `ios/Native/build-manifest.json` and each packaged manifest for source revision, dependency pins, target, architecture, and archive hashes.

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

### Run the native smoke on an already-booted simulator

On a Mac with Xcode, resolve the pinned Flutter dependencies, boot an iOS simulator, and pass its UDID from the repository root. The helper verifies the simulator is booted, builds the existing integration test as the app entrypoint, launches it normally, then attaches `flutter drive` after reading the VM Service URI from that Runner process. Build, URI discovery, and test execution each have a bounded 480, 90, and 240 second budget. Sanitized output is written to `.build/ios-smoke.log`; the VM authentication URI is not written there.

```sh
cd Apps/Flutter/stitch_app
flutter pub get --enforce-lockfile
cd ../../..
SIMULATOR_ID=<booted-simulator-udid> scripts/run-ios-native-smoke.sh
```

This describes how to run the smoke; it is not evidence that it passed on a user's Mac.

`integration_test/ios_native_smoke_test.dart` creates two small JPEG fixture files from the same generated color pattern in the app temporary directory. It does not read user photos, invoke image pickers, or load scene-analysis models. The test uses a nominal 1×2 grid with both cells forced, so it exercises the native job lifecycle without requiring feature matching; its output is a contract smoke, not a panorama quality test.
