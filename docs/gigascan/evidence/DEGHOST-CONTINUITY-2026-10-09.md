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

The user will perform the full restitch comparison. No full-panorama visual acceptance or Android device seam acceptance is claimed by this patch.

## File access and qualification

The original shared-tree job-state persistence fixes remain present: close the synced temporary file before replacement, retry transient Windows errors 5/32, and preserve authoritative state when replacement fails. Repeated replacement and locked-target preservation tests pass in the source-native run.

Workspace executables can inherit Low Mandatory Level. The verified djxl executable in the workspace had that label and could not write normal-user temporary files; a byte-identical executable created in a fresh normal-user build directory passed independent JPEG XL decode tests. Native compilation likewise uses a fresh normal-user Cargo target. Do not grant broad AppData permissions or require the end-user application to run as administrator. Extract the complete test package into a new normal-user Downloads directory.

Source-native qualification passes 228 tests (193 unit tests plus 35 integration tests), with 2 optional real-data tests ignored. The strengthened blur/obstruction endpoint-and-continuity regression also passes in a separate final unit run. Rust 1.88 formatting, Windows builder contracts and Android builder contracts pass. Independent Luna review found no blocking issue in the final production patch.

Android ARM64 shared core builds successfully with pinned native dependencies, required FFI exports and the builder's ELF/16 KiB alignment checks. Normal Windows Flutter Release 1.4.8+27 builds successfully (193.2 seconds for the Flutter build), with clean Flutter analysis and all 330 Flutter tests passing. Both English and Chinese test coverage is retained. Android ARM64 Release APK builds successfully (464.6 seconds for Gradle).

Implementation commit: `ffe9855`. The build uses the shared working tree, including pre-existing uncommitted task/UI/registration/persistence changes preserved from other work. The commit alone does not identify those changes; a private working-tree patch snapshot is retained alongside the build logs. The renderer file SHA-256 is `eaaf8fed250a056288f82a98cb781f1213afb8189a2b116ba0092a08b8803e9b`.

## Windows test handoff

The normal builder completed in `-PrepareSigning` mode with complete dependency licenses. This is an unsigned local test build, not a signed public release. EXE and DLL version metadata both report 1.4.8+27. The source-built DLL from the dedicated normal-user Cargo target was staged into the CMake-owned native release location; staged/package/extracted hashes are identical. This is the current vendored source build, not a replacement machine-local engine.

Private test ZIP: `.local/deliverables/PocketGigaScan-Windows-x64-v1.4.8-27-deghost-test.zip`.

- ZIP SHA-256: `b499815486bf02928f561a4989660caff3a64fac571fdf7b4cb7e9abebdc93ad`.
- Core DLL SHA-256: `eb9c1c43ef2db0b5fa4d1e0e8901db82cc76665a78888a880870511563cd3999`.

The complete ZIP was extracted into a fresh normal-user Downloads directory. The extracted EXE and DLL have user FullControl and no Low Mandatory Level label. Application launch/full-photo replay was left to the user; this ACL check does not claim a full end-to-end AppData task run. Existing tasks, original photos and exported results were not changed.

## Android test handoff

Private APK: `.local/deliverables/PocketGigaScan-Android-arm64-v1.4.8-27-deghost-test.apk`.

- Package: `com.lumiaiq.pocketgigascan`; versionName 1.4.8, versionCode 27.
- Android 10 / API 29 minimum; target API 36; `arm64-v8a` only.
- APK Signature Scheme v2 verification passes with one signer (development signing; no public release signing claim).
- APK SHA-256: `ac975e3f42951f90a5accdba74cf5e6faf134e59b4a9bcca92af9759dde8716c`.
- The packaged stripped core's `.text`, `.rodata` and `.data.rel.ro` hashes exactly match the freshly built ARM64 core. Raw file hashes differ because Gradle strips symbols; this section comparison verifies the packaged native code and read-only data.

The APK was not installed on a device during this task. Phone runtime, storage behavior and full-photo seam quality remain device/user qualification boundaries.
