# PocketGigaScan

PocketGigaScan is a local panorama stitcher for DWARF photo grids. The Flutter app imports JPEG originals, retains every selected photo in a task, maps photos to a grid, and calls the `lumia_gigascan_job_json` native job API for alignment, tiled rendering, pause and resume, and full-resolution export. The interface defaults to English and follows the system language; Chinese system locales use the Chinese interface. Task storage continues to use the existing application-support `LumiaStitch/tasks` directory so older local tasks remain available.

The app does not control a camera. It does not upload photos or task data. Missing or incompatible native libraries leave stitching unavailable and are reported in the app.

## Stitching and output

Tasks preserve the copied JPEG originals, their original names, and SHA-256 values. A fresh run uses the saved photos and settings with a new output directory. Grid mapping supports filename row/column numbering and selection order. Forced grid placement estimates positions when visual matches fail; review the estimated layout and the final seams. DWARF3 TELE EXIF can select the nominal 150 mm profile, using `fx=75000 px` at a 3840 px image width. This nominal profile is uncalibrated.

The Windows build supports PNG, TIFF, and JPEG XL full-resolution export and a tiled output viewer. A completed single-task stitch exports automatically in its saved format. Batch queues create one task for each immediate subfolder, retain item-specific settings and export state, and write unique output names. The renderer supports measured horizontal and vertical overlap, neighboring-photo refinement, seam deghosting, and local texture correction. These settings cannot establish camera calibration or guarantee seam quality for every scene; inspect the output.

Mobile platforms retain the portable Flutter task and stitching interface. Their current export settings use PNG. Starting, resuming, and exporting on mobile requires external power. Camera control and physical camera qualification are outside this app.

## Native core staging

Place ABI-compatible native core files at these paths, relative to this directory:

- Windows: `../../../.local/flutter-stitch-core/windows/lumia_gigascan_core.dll`
- Android: `../../../.local/flutter-stitch-core/jniLibs/arm64-v8a/liblumia_gigascan_core.so` and `x86_64/liblumia_gigascan_core.so`
- macOS: `macos/Native/liblumia_gigascan_core.dylib`
- iOS device: `ios/Native/iphoneos/liblumia_gigascan_core.a`
- iOS simulator: `ios/Native/iphonesimulator/liblumia_gigascan_core.a`

Windows and Android builds include a staged core when present. Apple artifacts are prepared with `tool/native/apple/build_apple_native.sh`; see [APPLE-BUILD.md](APPLE-BUILD.md). Generated Apple native artifacts are ignored by Git.

## Build and checks

Run these commands from this directory in PowerShell:

```powershell
D:\Flutter\bin\flutter.bat pub get --offline
D:\Flutter\bin\cache\dart-sdk\bin\dart.exe format lib test integration_test
D:\Flutter\bin\cache\dart-sdk\bin\dart.exe analyze
D:\Flutter\bin\flutter.bat test
D:\Flutter\bin\flutter.bat build windows
```

Android builds can target `android-arm64,android-x64` with `--split-per-abi`; stage matching native libraries before packaging. The Android app targets API 29 and later.

The native integration tests under `integration_test/` exercise real ABI calls. `TEST_SOURCE_DIR` can point to readable JPEG fixtures for the native smoke test. Synthetic Dart and widget tests verify application behavior, but do not prove image geometry or seam quality on a real photo set.

## Quality and task behavior

The full-resolution export reuses the rendered pyramid, supports TIFF/BigTIFF where needed, and avoids overwriting an existing export. The output viewer loads only visible pyramid tiles and checks the exported file association where a fingerprint is available. Older task records without fingerprints are identified as such in the viewer.

Deleting a task removes its local record and queue reference; imported originals, tiles, and exported images remain on disk. A running native task must first confirm that it stopped. Paused work remains attached to its task and is not silently resumed after an app restart.

Batch resources set the app-wide CPU worker budget, memory estimates, and task concurrency. Memory estimates cover scheduling and renderer buffers, not all OpenCV or operating-system process memory. The current native package uses the CPU backend.

See the repository [stitching test coverage](../../../docs/gigascan/STITCH-TESTING.md) for module checks, screenshot coverage, and Windows native integration evidence. The repository runner is `scripts/test-stitch-windows.ps1`.
