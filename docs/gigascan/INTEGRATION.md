# Core integration boundary

`lumia-gigascan-core` is an independent Rust repository at
`C:\Users\sunyy\Projects\lumia-gigascan-core`. The reviewed local dependency
pin is commit `d596cd2` (`feat: report mobile render preference`). No remote
or release tag is configured, so mobile build artifacts are still supplied
locally or by a future artifact pipeline.

The observed public surface is:

- `ScanPlanner`, `ScanRequest`, `ScanPlan`, `Tile`, `Roi`, `Pose`, `Fov`,
  `Grid`, and `Traversal` in `src/scan.rs`.
- `CaptureTile`, `CaptureGeometry`, `StitchOptions`, `StitchReport`, and
  related report types in `src/metadata.rs`.
- `StitchJob`, `StitchResult`, `Progress`, and `CancellationToken` re-exported
  by `src/lib.rs`.
- Versioned JSON C ABI `ABI_VERSION = 1`,
  `lumia_gigascan_stitch_json`, `lumia_gigascan_plan_json`,
  `lumia_gigascan_free`, and `lumia_gigascan_abi_version` in `src/ffi.rs`.
- `FocusStacker` and `PyramidGenerator` are contracts, not shipped
  implementations.

The app supplies image paths, row/column, pan/tilt/FOV metadata, and capture
state. Camera discovery, BLE, Wi-Fi, DUML, movement, focus, storage, and UI
remain shell responsibilities. Do not copy PTZ Manager stitching code or
couple the Rust core to DJI.

## Consumer bindings

- Swift package target: `Sources/LumiaGigaScanCore/`
- Android Kotlin/JNI boundary:
  `Apps/Android/app/src/main/kotlin/com/opencapture/openpocketcine/gigascan/`
  and `Apps/Android/app/src/main/cpp/lumia_gigascan_jni.cpp`

Both bindings report an explicit unavailable state when the native artifact is
absent. Android stages `liblumia_gigascan_core.so` from
`LUMIA_GIGASCAN_CORE_DIR` or the sibling Core target directory. iOS resolves
the same ABI from a bundled library or statically linked process symbols.

The current renderer reports `planarPairwiseHomographyFeather` and preserves
pairwise 3×3 transforms through a globally anchored projective layout. It is
still CPU-only feather blending, not bundle adjustment, APAP, content-aware
seams, or verified deghosting. Projection and lens calibration requests remain
forward-compatible fields and report warnings where they are not applied.

PTZ Manager's opt-in 5×4 real scan baseline produced a 7491×5943 PNG with all
20 tiles connected, but only 94.16% rectangular canvas fill and visible
foreground feather ghosts. Mobile acceptance must run the same source set and
must not lower that measured floor.

## Mobile execution and acceleration

Mobile stitch requests default to `renderBackendPreference=gpuPreferred`.
Production physical-device acceptance requires a GPU renderer; CPU is a
compatibility fallback, not the preferred mobile path:

- keep SIFT/RANSAC registration and quality decisions deterministic on CPU;
- run projective warp, bilinear sampling, and feather accumulation on Metal
  (iOS) or Vulkan compute (Android);
- use bounded output bands so GPU accumulation does not allocate the complete
  full-resolution panorama;
- report the actual `renderBackend` and `renderBackendFallback`; never label a
  CPU fallback as hardware accelerated;
- compare GPU/CPU dimensions, connectivity, coverage, seam regions, and pixel
  error on the same manifest.

ABI v1 now accepts the preference and reports the actual backend. Until the
Metal/Vulkan renderer is linked, Core explicitly returns
`renderBackend=cpu-rust-banded` and `renderBackendFallback=true`; this state is
not mobile performance acceptance.

Passing synthetic Core tests does not prove mobile packaging, hardware,
visual seams, or end-to-end behavior. iOS and Android artifacts still require
their platform OpenCV SDKs and physical-device verification when an
operator-visible GigaScan workflow is added.
