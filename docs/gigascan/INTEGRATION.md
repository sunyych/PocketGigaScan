# Core integration boundary

`lumia-gigascan-core` is an independent Rust repository at
`C:\Users\sunyy\Projects\lumia-gigascan-core`. The reviewed local dependency
pin is commit `20e8c5f` (`feat: preserve projective registration geometry`). No remote
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

The current renderer reports `planarTranslationFeather`. Projection and lens
calibration are accepted by ABI v1 but are not applied by the production
pipeline; the Core response includes warnings instead of silently claiming
support.

Passing synthetic Core tests does not prove mobile packaging, hardware,
visual seams, or end-to-end behavior. iOS and Android artifacts still require
their platform OpenCV SDKs and physical-device verification when an
operator-visible GigaScan workflow is added.
