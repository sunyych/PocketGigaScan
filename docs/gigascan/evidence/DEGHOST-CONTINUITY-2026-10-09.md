# Continuous deghost quality weights

## Scope and observed evidence

The reported small polygon patches are present in the preserved full-resolution level-zero PNG tiles, before JPEG XL export. The original exported panorama is 80855 by 25050 pixels with 364 inputs and used `sharpness-aware-max-score-softmax-ownership` algorithm version 1. The same-region GigaPan screenshot does not show these patches. No private source paths or photographs are committed.

The targeted defect is an abrupt per-pixel change in blur/obstruction eligibility and in the normalization reference as interpolated source-quality fields cross fixed thresholds. The historical export did not use the current global coarse ownership map; the latter is therefore not established as the cause of that export.

## Change

- Smooth quality support replaces binary local blur/obstruction gates.
- Each source's quality-adjusted ownership approaches its best other geometric source minus the existing 32-source-pixel margin as evidence strengthens. Strong quality evidence still overrides geometric preference.
- Unrounded per-pixel quality maxima and a common adjusted-score reference avoid quantized eligibility/reference switches. Sharpness evidence is weighted by the same source's texture support.
- Flat/single-source regions retain coverage; geometry, registration, local warps, exposure, all input photographs and preview/final separation remain intact.
- Deghost renderer identity advances to algorithm version 2. Existing deghost partial tiles must not be mixed with new tiles; use a task copy and restitch. Feather identity remains version 1. No old output is deleted.
- Tile memory reserve increases to 64 bytes per pixel to cover the additional score/reference maps.

This portable Rust code is used by Windows and Android. iOS native build qualification is outside this Windows host.

## Reproducibility

`scripts/verify-deghost-continuity.py --layout <layout.json> --tiles <level-0-directory> --out-dir <new-private-directory>` extracts the reported crop and writes deghost/feather/warp ablation layouts while retaining all source entries. The extracted crop has full tile coverage and exactly matches the initial private baseline. Cropped-layout rerenders change the coarse ownership lattice, so they are local comparative evidence rather than an equivalent replay of the full output.

No full-panorama visual acceptance or Android device seam acceptance is claimed by this record.

## File access and qualification

The original shared-tree job-state persistence fixes remain present: close the synced temporary file before replacement, retry transient Windows errors 5/32, and preserve authoritative state when replacement fails. Repeated replacement and locked-target preservation tests pass in the source-native run.

Workspace executables can inherit Low Mandatory Level. The verified djxl executable in the workspace had that label and could not write normal-user temporary files; a byte-identical executable created in a fresh normal-user build directory passed independent JPEG XL decode tests. Native compilation likewise uses a fresh normal-user Cargo target. Do not grant broad AppData permissions or require the end-user application to run as administrator. Extract the complete test package into a new normal-user Downloads directory.

Source-native qualification passes 228 tests (193 unit tests plus 35 integration tests), with 2 optional real-data tests ignored. The strengthened blur/obstruction endpoint-and-continuity regression also passes in a separate final unit run. Rust 1.88 formatting, Windows builder contracts and Android builder contracts pass.

Android ARM64 shared core builds successfully with pinned native dependencies, required FFI exports and the builder's ELF/16 KiB alignment checks. Normal Windows Flutter Release 1.4.8+27 builds successfully (193.2 seconds for the Flutter build), with clean Flutter analysis and all 330 Flutter tests passing. Both English and Chinese test coverage is retained. Android ARM64 Release APK builds successfully (464.6 seconds for Gradle).

Implementation commit: `ffe9855`. The build uses the shared working tree, including pre-existing uncommitted task/UI/registration/persistence changes preserved from other work. The commit alone does not identify those changes; a private working-tree patch snapshot is retained alongside the build logs. The renderer file SHA-256 is `eaaf8fed250a056288f82a98cb781f1213afb8189a2b116ba0092a08b8803e9b`.

## Windows package check

The normal builder completed in `-PrepareSigning` mode with complete dependency licenses. This is an unsigned local test build, not a signed public release. EXE and DLL version metadata both report 1.4.8+27. The source-built DLL from the dedicated normal-user Cargo target was staged into the CMake-owned native release location; staged/package/extracted hashes are identical. This is the current vendored source build, not a replacement machine-local engine.

Private test ZIP: `.local/deliverables/PocketGigaScan-Windows-x64-v1.4.8-27-deghost-test.zip`.

- ZIP SHA-256: `b499815486bf02928f561a4989660caff3a64fac571fdf7b4cb7e9abebdc93ad`.
- Core DLL SHA-256: `eb9c1c43ef2db0b5fa4d1e0e8901db82cc76665a78888a880870511563cd3999`.

The complete ZIP was extracted into a fresh normal-user Downloads directory. The extracted EXE and DLL have user FullControl and no Low Mandatory Level label. This ACL check does not claim a full end-to-end AppData task run. Existing tasks, original photos and exported results were not changed.

## Android package check

Private APK: `.local/deliverables/PocketGigaScan-Android-arm64-v1.4.8-27-deghost-test.apk`.

- Package: `com.lumiaiq.pocketgigascan`; versionName 1.4.8, versionCode 27.
- Android 10 / API 29 minimum; target API 36; `arm64-v8a` only.
- APK Signature Scheme v2 verification passes with one signer (development signing; no public release signing claim).
- APK SHA-256: `ac975e3f42951f90a5accdba74cf5e6faf134e59b4a9bcca92af9759dde8716c`.
- The packaged stripped core's `.text`, `.rodata` and `.data.rel.ro` hashes exactly match the freshly built ARM64 core. Raw file hashes differ because Gradle strips symbols; this section comparison verifies the packaged native code and read-only data.

The APK was not installed on a device during this task. Phone runtime, storage behavior and full-photo seam quality remain device/user qualification boundaries.


## Full-lattice source-quality follow-up

The 1.4.8+27 comparison reports deghost algorithmVersion 2. Saved layouts have identical canvas dimensions, angular bounds and all 364 source entries; changed report fields are alignment timing/limit diagnostics. A remaining triangular artifact is present in the level-zero tiles, so it precedes JXL encoding. The first change improves the affected region but does not establish visual acceptance.

The remaining artifact coincides with a large difference in source distance to image edges. Source crops also show object motion between captures. This motivates investigating weak edge-source quality/ownership overrides; final causality and replacement behavior require the full-lattice selected-tile ablation.

The full-lattice regression preserves canvas coordinates and builds the complete coarse ownership map before rendering selected tiles. It compares deghost with and without the map, feathering, and source-warp availability. Private artifacts remain under `.local/scale-artifact-diagnosis/`; originals and prior results remain untouched.

Full-lattice baseline ablation passes in Release (57.71 seconds). All three selected output tiles are pixel-identical to the compared level-zero tiles. The artifact persists with source warps and coarse ownership disabled, supporting the near-edge quality override as the targeted mechanism.

The next bounded repair selects a single best geometric other source and obtains its ownership, quality and geometric support together. A smooth support gate prevents a few-pixel sliver from suppressing a well-supported source. This deliberately favors conservative retention if a third overlapping source is sharper than the best geometric peer; unrestricted quality maxima previously mixed evidence from different images.

Final peer-support source SHA-256: `b27878b868bd9b3d5ac6a996a124ce137d120db2379e99e2416e58d627ed668c`. Deghost algorithmVersion 3 uses model `sharpness-aware-peer-coupled-coarse-ownership-v2`; feather remains algorithmVersion 1. The actual deghost arrays occupy 56 bytes/pixel (16 accumulator + 24 score + 16 source IDs) within the unchanged 64-byte reserve. Stable ranking compares borrowed path, camera/warp bits and calibration, avoiding per-comparison key allocations.

Final Release native suite passes 231 tests (196 unit plus 35 integration); 3 optional real-data tests are ignored in the ordinary suite. The new full-lattice real-data test is explicitly run separately and passes in 50.80 seconds. The final four output tiles exactly match the prior successful peer-support render, confirming the allocation-free ranking change preserves this real result. At the truck point RGB changes from (164,155,134) to dark-trailer (11,39,62); at the SUV point RGB changes from foreign (106,117,125) to source vehicle (253,253,253). Independent visual review of the exact same-coordinate crop finds the reported truck and SUV triangles removed. Private comparison: `.local/scale-artifact-diagnosis/triangle-same-layout-comparison.png`. This is local real-source visual qualification, not full-panorama or phone-device acceptance.

New peer attribution tests cover actual source geometry edge taper, no-peer fallback, exclusion of crisp third-source evidence, stable equal-ownership ranks, and fine blur/obstruction support continuity. Fixture issues were corrected without changing production behavior; the complete suite passes. Flutter analysis is clean and all 330 tests pass. Both build-script contracts pass.


### 1.4.9+28 Windows follow-up build

Implementation commit: `3101df0`. Normal Windows builder completes successfully, including its own native/Flutter analysis/tests and 69.8-second Flutter Release build. The standard builder strips test-helper compilation for the production DLL; this freshly source-built DLL is synchronized to CMake's fixed native/core/target/release input after Cargo compilation. Normal-user Cargo output, CMake input, complete package and extracted DLL hashes are identical. EXE and DLL metadata both report 1.4.9+28.

- Unsigned local test ZIP: `.local/deliverables/PocketGigaScan-Windows-x64-v1.4.9-28-edge-peer-test.zip`. Complete dependency licenses are included; this is not a signed public release.
- ZIP SHA-256: `430b0e236017dbf00f848c41c8bc565a82c9a74325f7197f69177f6143b83a4e`.
- Production core DLL SHA-256: `1f6f60dc4ef812e73cb096ef6f453e6b579841ad9f0ce7a59bd4805be299d6f6`.
- Extracted into a fresh normal-user Downloads directory. User FullControl and absence of Low Mandatory Level labels verified for EXE/DLL. No broad AppData ACL change, no forced administrator launch, no original/task/result deletion. The application itself is not launched or used for a full task replay in this qualification.

Android ARM64 shared core also builds successfully (24.23-second Rust Release compile); APK packaging/section verification is recorded below when complete. The shared source includes preserved pre-existing Flutter/job/registration work; private `shared-tree-followup-build.patch` records that dirty-tree boundary.


### 1.4.9+28 Android follow-up build

ARM64 APK Release completes successfully (118.3-second Gradle assemble). APK Signature Scheme v2 verifies with one development signer. Package `com.lumiaiq.pocketgigascan`, versionName 1.4.9, versionCode 28, Android 10/API 29 minimum, target API 36, arm64-v8a only.

- APK: `.local/deliverables/PocketGigaScan-Android-arm64-v1.4.9-28-edge-peer-test.apk`.
- APK SHA-256: `afc7a997864225c1b0c30cea88df4aeb8eb5a1d56d6d359561d466bac1c9db87`.
- Staged core SHA-256: `11958ff5f64cfea6e3437ad19583c665956545155cbb0f9a1aa9b0fa66c45867`.
- APK stripped core SHA-256: `6061821b0c505a9b787e22af2af41a74dac65746d733e0af2dad1252b0a6f6de`. The `.text`, `.rodata` and `.data.rel.ro` hashes exactly match the freshly compiled staged core; raw file hashes differ only under the expected strip/sign/package transformation.

SHA-256 files are provided alongside both test artifacts. No APK installation, phone runtime/permissions qualification, iOS build or complete panorama replay is claimed. User should close the old Windows version, launch from the new normal-user extraction directory, and copy/new-create the task for a full restitch; algorithmVersion 3 prevents mixing old deghost partial tiles.
