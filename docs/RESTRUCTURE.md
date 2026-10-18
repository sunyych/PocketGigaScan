# PocketGigaScan architecture and platform boundaries

PocketGigaScan is an independent panorama stitcher for DWARF photo grids.
The Flutter application in `Apps/Flutter/stitch_app` provides the shared task,
queue, import, viewer and export experience. The Rust/OpenCV engine in
`native/core` performs registration and rendering. Platform runners adapt those
shared layers to Windows, Android, macOS and iOS.

## Shared processing

The Flutter task and queue models own user-visible task state and durable
workflow. The native engine owns image registration, panorama geometry,
rendering and resumable processing. Inputs selected by the user are copied into
task-owned storage; task cleanup preserves original photographs and exported
results. Windows task storage retains compatibility with earlier PocketGigaScan
records.

The Android runner builds the Rust/OpenCV engine for ARM64. The macOS runner
builds it for Apple silicon. Windows builds the engine from source with pinned
dependencies. The current iOS runner compiles for device and simulator without
linking the native stitching engine; native iOS processing and Apple signing
remain unqualified.

## Product boundary

The app imports local image files and folders through platform pickers. Its
shared Dart DWARF client also connects to a camera's local network, lists
panorama packages and downloads original photos into app-owned storage. Android
camera and phone behavior has real-device evidence; iOS camera-transfer runtime
behavior remains unqualified. Remote capture/control is outside product scope.

Platform-specific services handle file picking, storage, lifecycle and device
resources while preserving shared task and processing semantics. A platform
build proves compilation and packaging only to the extent described in its
evidence record; it does not prove physical-device behavior, visual quality,
signing or native stitching support where those are not explicitly qualified.

See [build instructions](BUILD.md), the [Android design](gigascan/ANDROID-STITCH-DESIGN.md),
and [four-platform build evidence](gigascan/evidence/FOUR-PLATFORM-BUILD-2026-10-17.md).
