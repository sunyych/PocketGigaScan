# Apple native build

The Flutter project can still build without the Rust panorama core. In that
mode the app reports native processing as unavailable. Apple native processing
is opt-in and requires macOS, Xcode command-line tools, Rust Apple targets, and
OpenCV libraries built for each Apple SDK. The Windows build host cannot build
or qualify iOS/macOS artifacts.

The default core is this repository's `native/core`; no sibling checkout is
required. The script uses Rust 1.88.0 and locked Cargo dependencies. Install that
toolchain before running it; `LUMIA_RUST_TOOLCHAIN` explicitly overrides the
toolchain for a future migration.

Install the Rust targets needed for the platforms you intend to build:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

## OpenCV inputs

Use OpenCV builds that provide `include/` and `lib/` directories. The core's
`build.rs` links `opencv_stitching`, `opencv_calib3d`, `opencv_features2d`,
`opencv_flann`, `opencv_imgcodecs`, `opencv_imgproc`, `opencv_core`, and
`opencv_photo`.
For iOS, each required archive must be named `lib<name>.a`. For macOS, each
required OpenCV module must have a `.dylib` of that name in both architecture
roots; the script embeds these and their runtime dependencies. Add any codec
dependencies required by your OpenCV build to `LUMIA_APPLE_EXTRA_LIBS` as
space-separated library names. The script passes the complete list to Cargo
and the iOS app linker and fails before building if a required input is absent.

For iOS, provide static OpenCV builds for the device and each simulator
architecture. The script verifies the expected architecture in every archive
and combines the two simulator core/library slices for Xcode:

```sh
export OPENCV_IOS_DEVICE_ROOT=/opt/opencv/ios-device
export OPENCV_IOS_SIMULATOR_ARM64_ROOT=/opt/opencv/ios-simulator-arm64
export OPENCV_IOS_SIMULATOR_X86_64_ROOT=/opt/opencv/ios-simulator-x86_64
export LUMIA_APPLE_EXTRA_LIBS='jpeg png tiff webp'
bash tool/native/apple/build_apple_native.sh ios
flutter build ios --no-codesign
```

The script builds `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and
`x86_64-apple-ios`, stages the forced static core archive and OpenCV archives
under `ios/Native`, and writes an optional `ios/Flutter/NativeCore.generated.xcconfig`.
That config applies `-force_load` and `-export_dynamic` so the process lookup
used by Dart FFI retains the core C ABI symbols. `Debug.xcconfig` and
`Release.xcconfig` include it only when present, preserving the native-free
Flutter build when staging has not been run.

## macOS

Provide matching per-architecture OpenCV installations, with the required
module dylibs and same runtime dylib filenames under each `lib/` directory.
The script checks each input
architecture and combines the Rust core and OpenCV runtime dylibs with `lipo`.
OpenCV module dependencies and their runtime dylibs are copied into the app
bundle's `Frameworks` directory by the Runner build phase, their load paths are
rewritten to `@rpath`, and each copied library is signed before Xcode signs the
app:

```sh
export OPENCV_MACOS_ARM64_ROOT=/opt/homebrew/opt/opencv-arm64
export OPENCV_MACOS_X86_64_ROOT=/opt/homebrew/opt/opencv-x86_64
export LUMIA_APPLE_EXTRA_LIBS='jpeg png tiff webp'
bash tool/native/apple/build_apple_native.sh macos
flutter build macos
```

The script produces an arm64/x86_64 `liblumia_gigascan_core.dylib`, stages all
OpenCV runtime dylibs, and writes an optional
`macos/Flutter/NativeCore.generated.xcconfig` to enable embedding. A missing
non-system runtime dependency stops staging with its name so it can be added to
the OpenCV runtime directory.

## Validation boundary

This is a build recipe, not evidence that Apple targets compiled here. Run the
commands on a Mac with the matching Xcode SDKs, inspect the resulting app
bundle's architectures and signatures, then smoke-test FFI on an iPhone and a
macOS host. Keep those results separate from Windows/Android checks.
