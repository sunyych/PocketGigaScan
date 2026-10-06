# PocketGigaScan Android Stitching Implementation Plan

> **For agentic workers:** Use coordinator plus Luna coder subagents with disjoint ownership and independent review. Steps use checkbox syntax for tracking.

**Goal:** Desktop processing parity on the connected Android device, unrestricted
photo counts with a large-grid confirmation, and bounded-memory result viewing.

**Architecture:** Keep the shared Flutter task/queue/viewer and Rust/OpenCV C ABI.
Add Android storage/runtime adapters; improve sparse registration storage for
unrestricted grids. Preserve this boundary for later iOS adapters.

**Tech Stack:** Flutter 3.44.2, Dart 3.12.2, Rust 1.88, OpenCV 4.13, libjxl 0.12,
Kotlin/Android, NDK 28.2.13676358, API 29 minimum.

**Spec:** [Android design](ANDROID-STITCH-DESIGN.md).

## Global constraints

- No arbitrary photo/grid ceiling; checked positive dimensions and complete grids.
- Confirmation when rows > 6, columns > 6, or photos > 36; cancellation starts nothing.
- Preserve all originals/exports, adjacent-only registration and checkpoint identities.
- PNG/TIFF/JXL automatic exports; TIFF default; English/Chinese follow the system.
- Root owns serial SDK/device execution; coders do not run overlapping SDK builds.
- Current device is ARM64 Android 14. Future iOS packaging remains separately planned.

## Task 1: Native scalable grid and Android codecs — Luna core coder

Files: `native/core/src/spherical.rs`, `job.rs`, `spherical_renderer.rs`, native
tests, `native/core/build.rs`, new `scripts/build-stitch-android-core.ps1` and
`scripts/test-build-stitch-android-core.Tests.ps1`.

- [x] Add acceptance regressions for 33×33 and 129×2 and checked-overflow rejection.
- [x] Replace large dense normal assembly with sparse blocks, checked dimensions,
  cancellation and PCG true-residual checks; compare against small dense cases.
- [x] Extend target-specific C++/JXL linking to Android while preserving Windows.
- [x] Verify the pinned OpenCV Android SDK and source-build JXL dependencies, verify ELF exports/dependencies
  and alignment, and stage ABI-matched libraries with provenance manifests.
- [x] Root runs native format/tests and builds; review numerical and memory evidence.

## Task 2: Storage and runtime adapter — Luna Android platform coder

Files: Android runner/Gradle/manifest and separate Kotlin storage/service helpers;
new Dart `mobile_storage_service.dart`, `mobile_runtime_service.dart`, unit tests.

Interface consumed by shared UI:

```dart
const MobileStorageService({MethodChannel? channel});
Future<String?> pickBatchParent();
Future<bool> saveExport(String sourcePath, {
  required String mimeType, required String suggestedName,
});
Future<bool> shareExport(String sourcePath, {required String mimeType});
```

- [x] Test cancellation and exact MethodChannel payloads for all three MIME types.
- [x] Implement SAF tree import and destination export as bounded streams.
- [x] Implement foreground/runtime guards with API/version checks,
  notification state and stop/recovery behavior; publish exact Dart API to UI coder.
- [x] Brand the Android launcher and fail the native packaging gate for absent ABI libraries.
- [x] Root runs normal Android JVM tests and lint with native preBuild enabled.
- [x] Root builds and verifies the actual APK, not only staged files.

## Task 3: Shared mobile parity and approval — Luna UI coder

Files: `main.dart`, `batch_queue_page.dart`, shared task/queue/grid models,
photo/folder importers, queue controller, localization and their tests.

- [x] Write 6×6 / 7×6 / 7×1 approval/cancellation and >1024-photo regressions.
- [x] Remove model/import caps and preserve structural validation before allocation.
- [x] Persist scoped approval, block unapproved batch starts/reloads and invalidate
  changed configurations/new runs; test zero native calls on cancellation.
- [x] Enable mobile batches through the adapter; keep the app-owned controller.
- [x] Align mobile quality and export defaults with desktop; connect save/share,
  runtime budgets/guard and lifecycle recovery without charger hard blocking.
- [x] Root runs all Flutter tests/analysis and reviews old desktop strict screenshots.

## Task 4: Huge result viewer — Luna platform coder after UI handoff

Files: `widgets/exported_image_viewer.dart` and viewer tests.

- [x] Add touch pinch/pan tests, fit/zoom boundaries, narrow layouts and hidden status.
- [x] Preserve visible-tile culling/bounded cache for PNG/TIFF/JXL results.
- [ ] Root tests gestures on the device and reviews captured supported states.

## Task 5: Physical qualification and delivery — coordinator

Files: `integration_test/android_parity_test.dart` (UI coder), root-owned evidence
and roadmap/collaboration docs; ignored logs/APK/fixtures under `.local`.

- [x] Build a fresh ARM64 APK with the current vendored core.
- [ ] Install that APK on the connected Android device.
- [ ] Run the screenshot integration driver against `DEVICE_SERIAL`
  with actual FFI three-format exports, isolated fixtures, viewer and confirmation.
- [ ] Exercise native SAF, export destination, share MIME, background/recovery and
  task deletion preserving outputs; record reproducible results/screenshots.
- [x] Restore the normal release entry point, verify package/version/signature/SHA,
  and deliver APK path and explicit remaining iOS/visual/device boundaries.
