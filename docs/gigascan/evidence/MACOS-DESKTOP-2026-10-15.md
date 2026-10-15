# PG-069 macOS desktop client qualification

Date: 2026-10-15. Branch: `codex/macos-desktop`. This development uses an isolated managed worktree based on `605d67c`; the dirty original checkout, its photographs, task records and exports are preserved.

## Product scope

- Windows and macOS expose independent people protection and water smoothing. The desktop test package includes the fixed ONNX model and CPU runtime; end users need no login, network or Python.
- Android/iOS hide scene controls, do not initialize or prepare the model service, and send both flags as false even for saved tasks that contain true values. Ordinary mobile stitching is retained.
- Initial Mac target: Apple silicon arm64, macOS 14 or newer. This minimum comes from the actual official ONNX Runtime 1.31.0 dylib load command (`LC_BUILD_VERSION minos 14.0.0`), not an assumed SDK default. Intel Mac distribution is not qualified.
- Normal Flutter Release entrypoint, portable Rust core, bundled OpenCV dylibs and static JPEG XL. The Mac model lives at `Contents/Resources/models`; the core and ONNX Runtime live together under `Contents/Frameworks`.
- Mac system memory reads `hw.memsize`, `hw.pagesize` and Mach VM statistics. Free plus inactive pages provide a conservative reclaimable estimate; speculative/purgeable counts are not added twice. Mac single-task exports write directly to the selected folder.
- Ad-hoc signing is for testing. No Apple Developer credentials or notarization are part of this package.

## Independent review and handoffs

Luna native, Flutter and packaging coders owned disjoint files. Coordinator review corrected UTF-8 path validation and bounded FFI errors, retained ONNX TypeInfo object lifetimes, identified the missing Mac memory reading, corrected the Mach ABI cast, repaired Mac export destination handling, and reviewed native dependency closure, actual runtime deployment floor, arm64 Flutter SDK, Xcode embedding environment, model artifact action pin and smoke-test public API. No inference ABI was added to the public interface.

Review of existing hosted failures also found two independent build issues: the Windows builder tried to copy its native DLL over itself when Cargo used its default target directory; Android setup passed a literal newline-separated SDK package list as one argument, leaving the pinned NDK absent. Both have narrow fixes and executable/contract regressions. These are CI repairs, not new mobile features.

## Local Windows evidence

| Check | Result |
| --- | --- |
| Rust formatting | Passed |
| Native core tests with pinned OpenCV/JXL/ORT | 243 passed, 3 ignored (both full Windows builds) |
| Flutter analysis | No issues |
| Flutter full suite | 337 passed (both full Windows builds) |
| Normal Windows source Release builder | Passed, 1.5.1+30 signing input; not a signed distribution |
| Windows and Android build contracts | Passed; Windows contract executes both same-path and external-target DLL staging |
| Mac shell syntax and package contracts on Windows | Passed; these do not constitute a Mac build |
| Canonical model verifier on actual ONNX + exporter manifest | Passed: 237503947 bytes, SHA-256 a997b66ac8ca75632817a62f253e47300b29edbeed6f62b1f04d98fe5bc12a13 |
| UTF-8 private bridge regression | Real public people fixture with model path containing Chinese and emoji: scene analysis/render and PNG/TIFF/JXL exports passed |

The Unicode-path run used the freshly source-built Windows DLL, preserved both input photos, reused the baseline geometry, and checked final tile/export pixels through the existing private verifier. Artifacts remain local under `.local/macos-desktop/unicode-scene-smoke`; no model, cache, photograph, export or executable is committed. This is Windows native functional evidence, not Mac visual acceptance.

## Hosted Mac checks and remaining acceptance

The new workflow consumes the fixed canonical model dependency ZIP and transfers its verified graph, manifest and source/license notices to the Mac arm64 job. The Mac build is required to run core tests, Flutter analysis/tests, source Release build, architecture/minimum-OS/dependency/signature checks, and scene-enabled public-job rendering plus PNG/TIFF/JXL export against the packaged core. Actual hosted results will be recorded after the branch is pushed.

A Windows host cannot establish that Xcode builds or launches the app. Mac build success, Mac application launch/import/resume behavior, and real-photograph visual quality are separate evidence. The user will test final tiles and exported same-coordinate crops on their Mac, especially small people, crowded areas, source/tile boundaries, shoreline people and water ripples. Original missing body parts are not reconstructed.

The final Windows regression rerun after direct-export and CI staging fixes also passes all 243 native / 337 Flutter tests, analysis and normal Release packaging. The Mac public-job smoke logic was additionally executed on Windows with explicitly mocked Mach-O/signature checks: this found and fixed missing global resource configuration before a 2048 MiB scene job. That script regression now passes render, mask-manifest and PNG/TIFF/JXL checks; it is not Mac binary qualification. The model-preparation job caches only the canonical export and verifies size, digest, manifest and license on every use.

Hosted model re-export attempts exposed backend-dependent Conv/BatchNorm folding: 965 graph nodes and all non-initializer bytes match, but 24 of 212 initializers differ in floating-point tails (maximum absolute difference about 9.54e-7). Both local AVX2 and AVX512 reference exports still reproduce the old canonical a997 hash. No alternate model hash was accepted. Product builds now consume a fixed dependency ZIP (219959932 bytes; SHA-256 cb9769f81929590711a2a0b84373946c1b429c96ff4eac6bfc4ebe22eb250c41); installed apps remain offline. Public model asset publication is awaiting explicit user authorization after automatic approval review rejected that remote action. Hosted Mac compilation is pending this dependency delivery.

After the frozen-asset resolver and notice packaging changes, a third normal Windows Release build passed 243 native tests, 337 Flutter tests and analysis. This run omitted `-SceneModel` and consumed the exact prepared ZIP from the verified dependency cache, exercising archive/model checks and new notice staging through the normal builder. It validates the build flow with the frozen asset, not anonymous public delivery (publication remains pending). The resulting signing input is unsigned developer material. Three Flutter-generated Windows plugin files were retained after cleanup was rejected by automatic review; no original-checkout work was discarded.
