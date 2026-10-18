# iOS build artifacts

The ios-build.yml workflow runs on GitHub's macos-15 runner with Flutter 3.44.2. It builds two app bundles from the existing iOS runner:

- PocketGigaScan-iOS-device-release-unsigned.zip: iPhoneOS Release app.
- PocketGigaScan-iOS-simulator-debug-unsigned.zip: iOS Simulator Debug app.

Each ZIP contains the corresponding Runner.app bundle. The workflow also uploads a JSON build manifest, a README, and a SHA-256 sidecar for each ZIP. The packager checks the bundle ID against com.lumiaiq.pocketgigascan, checks the app version and build number against pubspec.yaml, confirms the device or simulator platform and arm64 executable slice, and verifies that Xcode compiled the AppIcon catalog into Assets.car.

These are unsigned build-verification packages, not installable IPAs. The existing iOS build does not link the Rust/OpenCV panorama core, so native stitching is not included. Apple code signing, TestFlight distribution, physical-device installation, and runtime stitching are not qualified by this workflow.
