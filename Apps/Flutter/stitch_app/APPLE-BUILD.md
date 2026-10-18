# Apple native build

The Flutter project can still build without the Rust panorama core. In that
mode the app reports native processing as unavailable. Apple native processing
is opt-in for iOS. The standalone macOS client builder and its pinned
dependencies are documented below.

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

## Standalone macOS client

The first macOS package targets native Apple Silicon (`arm64`) and requires
macOS 14.0 or later. The ONNX Runtime 1.31.0 Apple Silicon release dylib has
`LC_BUILD_VERSION minos 14.0.0`; the app and every bundled native library are
checked against that actual Mach-O minimum. Intel Macs are not included in this
first package.

On macOS with Xcode command-line tools, CMake, Python 3, and Rust 1.88.0, build
with the fixed model release asset pinned in
`scripts/scene-model-export.lock.json`. Download and verify the ZIP, then
extract and validate its ONNX model and manifest:

```sh
set -euo pipefail
model_dir="$PWD/.build/scene-model-v1"
mkdir -p "$model_dir"
model_zip="$model_dir/PocketGigaScan-scene-model-v1.zip"
asset_url="$(python3 -c 'import json; print(json.load(open("scripts/scene-model-export.lock.json"))["releaseAsset"]["url"])')"
asset_sha="$(python3 -c 'import json; print(json.load(open("scripts/scene-model-export.lock.json"))["releaseAsset"]["sha256"])')"
curl --fail --location "$asset_url" --output "$model_zip"
actual_sha="$(shasum -a 256 "$model_zip" | awk '{print $1}')"
test "$actual_sha" = "$asset_sha"
ditto -x -k "$model_zip" "$model_dir"
python3 scripts/verify-macos-package.py \
  --model "$model_dir/scene-model-v1.onnx" \
  --manifest "$model_dir/scene-model-v1.manifest.json"

bash scripts/build-stitch-macos.sh \
  --scene-model "$model_dir/scene-model-v1.onnx" \
  --output-dir .build/stitch-macos
```

The fixed ZIP contains the model, manifest, `scene-model-README.md`, and
`scene-model-NOTICE.txt` beside the ONNX file; the builder validates and
packages them. CI verifies the ZIP SHA-256 and then the ONNX SHA-256 from the
shared lock before the Mac build. The pinned model card declares MIT, while the
pinned repository has no separate `LICENSE` file, so the notice preserves the
source attribution without inventing a holder or copyright year.

`scripts/export-scene-model.py` remains a reference and QA exporter for the
pinned upstream model. It enforces the canonical ONNX digest, but CPU backend
rounding can vary; the product build consumes the already validated release
asset instead of re-exporting the model on each runner.

The script installs Flutter 3.44.2 from its checksum-pinned official archive if
Flutter is not already available, then builds OpenCV 4.13.0 and libjxl 0.12.0
from SHA-256-pinned sources. It downloads ONNX Runtime 1.31.0 from Microsoft's
official Apple Silicon release asset and verifies its archive digest. The build
rejects a different model size or digest than
`scripts/scene-model-export.lock.json`.

The resulting `PocketGigaScan-macos-arm64.zip` contains the app bundle, the
CPU-only ONNX model, build manifest, and project, runtime, model, and native
dependency license notices. No GitHub or Hugging Face login is needed to run the
app. The app is non-sandboxed so macOS file open/save panels can access the
photos and export destinations the operator selects. Local-network access is
described for connecting to a DWARF3 camera.

This is an ad-hoc-signed developer-test package. It is not notarized and is not
an App Store release. On first launch, macOS may require opening the app through
Finder. If Gatekeeper blocks it, first verify the ZIP SHA-256, then use
**System Settings > Privacy & Security > Open Anyway** for this app. The build
writes a relative ZIP filename in the adjacent SHA-256 file; copy both files to
the Mac and verify the copied ZIP before extraction:

```sh
shasum -a 256 -c PocketGigaScan-macos-arm64.zip.sha256
```

### Manual Mac acceptance

Use a Mac running macOS 14 or later with Apple Silicon. Copy the ZIP and its
`.sha256` file together, verify the ZIP with the command above, extract the
archive, and open `PocketGigaScan.app`. Check that the app
starts without a native runtime or model error, import the original photos for
a small panorama, inspect its preview and final export, and export PNG, TIFF,
and JPEG XL. Close and reopen the app to confirm the task can resume and the
original photos remain available. This manual check is separate from the Mac
CI inference and package checks.

The macOS CI is configured for GitHub's `macos-15` Apple Silicon runner. It
downloads and verifies the fixed model asset, then builds the arm64 app and
runs the packaged core FFI, 512x512 ONNX CPU inference, Mach-O
architecture/minimum-version, signature, and dependency-closure checks on Mac.
Hosted run 38817678302 qualifies version 1.5.1+30 at source
commit `96c6ae5`: the normal Release app, all 340 Flutter / 241 native tests
(3 optional native fixtures ignored), 12 packaging contracts, and packaged
model/render/PNG/TIFF/JXL checks pass. The resulting ZIP and its relative
checksum file are available in that run's `PocketGigaScan-macos-arm64-96c6ae5...`
artifact. Those checks do not replace launch/import/resume and visual review of
a real panorama on a user's Mac.
