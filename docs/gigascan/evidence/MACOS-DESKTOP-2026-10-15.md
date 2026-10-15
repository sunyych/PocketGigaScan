# PG-069 macOS desktop client qualification

Date: 2026-10-15. Branch: `codex/macos-desktop`. This development uses an isolated managed worktree based on `605d67c`; the dirty original checkout, its photographs, task records and exports are preserved.

## Qualified test package

[Hosted Apple Silicon run 38817678302](https://github.com/sunyych/PocketGigaScan/actions/runs/38817678302) **passes** the normal source Release and final packaged checks at `96c6ae5d1e98c8719a91e40f17bfe336e30a6c0d`. Version: **1.5.1+30**, arm64, declared minimum macOS 14.0. The runner is native Apple silicon on macOS 15; a separate physical Mac 14 launch is not claimed.

| Check | Final result |
| --- | --- |
| Flutter analysis and full tests on Mac | Clean; 340 passed, including strict separate Mac goldens |
| Rust formatting and native tests on Mac | Passed; 241 passed, 3 optional fixtures ignored |
| Mac packaging contracts | 12 passed |
| Normal source Release app | Built successfully with Xcode 16.4 |
| arm64 slice, deployment floor, bundled dependency closure, ad-hoc signature | Passed on the final staged app |
| Packaged model/public-job smoke | Actual CPU inference, two persisted source masks and scene-enabled rendering passed with both options enabled, deghost and local warp |
| Packaged PNG / TIFF / JPEG XL exports | All passed; source/cache/export paths include Chinese and emoji |
| Downloaded distribution integrity | Sidecar matched; all 263 manifest file hashes, model, version, core arm64 header, executable permission and framework links verified without unpacking or modifying the inner ZIP |

Distribution artifact ID: `12011978126`. Inner ZIP: `PocketGigaScan-macos-arm64.zip`, **273055977 bytes**. SHA-256: `b5cb6c2bc4f430c4c51ae08b0aaf636b475dd156db0908bed36d3edd21dabdf1`. The adjacent `.sha256` uses the relative ZIP filename. A persistent local delivery copy is under `.local/deliverables/macos-1.5.1+30-96c6ae5/`; the original CI artifact ZIP, full job log and independent ZIP verification JSON are under `.local/macos-desktop/`. All remain excluded from Git. The package contains the fixed offline model, ONNX Runtime and dependency notices; users need no account, network or Python. It is ad-hoc signed for testing and is not notarized.

**Remaining user acceptance:** launch/import/resume on the user's Mac and real-photograph final tiles/export crops. Hosted synthetic inputs prove execution and packaging; reviewed test goldens prove expected test rendering. Neither establishes small-person, dense-crowd, shoreline or water-ripple visual quality on a real panorama. Original missing body parts are not reconstructed.

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
| Native core tests with pinned OpenCV/JXL/ORT | 243 passed, 3 ignored (three normal Windows builds) |
| Flutter analysis | No issues |
| Flutter full suite | 337 passed in normal builders; current separate full rerun 340 passed |
| Normal Windows source Release builder | Passed, 1.5.1+30 signing input; not a signed distribution |
| Windows and Android build contracts | Passed; Windows contract executes both same-path and external-target DLL staging |
| Mac shell syntax and package contracts on Windows | Passed (12 contracts); these alone do not constitute a Mac build |
| Canonical model verifier on actual ONNX + exporter manifest | Passed: 237503947 bytes, SHA-256 a997b66ac8ca75632817a62f253e47300b29edbeed6f62b1f04d98fe5bc12a13 |
| UTF-8 private bridge regression | Real public people fixture with model path containing Chinese and emoji: scene analysis/render and PNG/TIFF/JXL exports passed |

The Unicode-path run used the freshly source-built Windows DLL, preserved both input photos, reused the baseline geometry, and checked final tile/export pixels through the existing private verifier. Artifacts remain local under `.local/macos-desktop/unicode-scene-smoke`; no model, cache, photograph, export or executable is committed. This is Windows native functional evidence, not Mac visual acceptance.

## Hosted bring-up history and manual acceptance

The new workflow consumes the fixed canonical model dependency ZIP and transfers its verified graph, manifest and source/license notices to the Mac arm64 job. The Mac build is required to run core tests, Flutter analysis/tests, source Release build, architecture/minimum-OS/dependency/signature checks, and scene-enabled public-job rendering plus PNG/TIFF/JXL export against the packaged core. The final qualified result is recorded above. The following notes retain intermediate failures and repairs; their pending statements describe those earlier runs.

A Windows host cannot establish that Xcode builds or launches the app. Mac build success, Mac application launch/import/resume behavior, and real-photograph visual quality are separate evidence. The user will test final tiles and exported same-coordinate crops on their Mac, especially small people, crowded areas, source/tile boundaries, shoreline people and water ripples. Original missing body parts are not reconstructed.

The final Windows regression rerun after direct-export and CI staging fixes also passes all 243 native / 337 Flutter tests, analysis and normal Release packaging. The Mac public-job smoke logic was additionally executed on Windows with explicitly mocked Mach-O/signature checks: this found and fixed missing global resource configuration before a 2048 MiB scene job. That script regression now passes render, mask-manifest and PNG/TIFF/JXL checks; it is not Mac binary qualification. The model-preparation job caches only the canonical export and verifies size, digest, manifest and license on every use.

Hosted model re-export attempts exposed backend-dependent Conv/BatchNorm folding: 965 graph nodes and all non-initializer bytes match, but 24 of 212 initializers differ in floating-point tails (maximum absolute difference about 9.54e-7). Both local AVX2 and AVX512 reference exports still reproduce the old canonical a997 hash. No alternate model hash was accepted. Product builds now consume a fixed dependency ZIP (219959932 bytes; SHA-256 cb9769f81929590711a2a0b84373946c1b429c96ff4eac6bfc4ebe22eb250c41); installed apps remain offline. The exact ZIP is now published as the non-latest [scene-model-v1 prerelease](https://github.com/sunyych/PocketGigaScan/releases/tag/scene-model-v1), under the original independent-asset plan. Anonymous public download verifies the exact size and SHA-256, as does the hosted model-preparation job. The first actual Mac attempt reached dependency extraction and exposed incorrect source-marker paths; those paths and failed-build cache retention are repaired in 79b7d7c. Mac compilation/package qualification continues.

After the frozen-asset resolver and notice packaging changes, a third normal Windows Release build passed 243 native tests, 337 Flutter tests and analysis. This run omitted `-SceneModel` and consumed the exact prepared ZIP from the verified dependency cache, exercising archive/model checks and new notice staging through the normal builder. It validates the build flow with the frozen asset; anonymous public delivery is separately verified above. The resulting signing input is unsigned developer material. Three Flutter-generated Windows plugin files were retained after cleanup was rejected by automatic review; no original-checkout work was discarded.

Hosted bring-up: [38804495223](https://github.com/sunyych/PocketGigaScan/actions/runs/38804495223) compiled and installed OpenCV/JXL from source, then exposed the official ORT archive's extra `./` path component. The fixed extraction preserves the pinned archive digest and verifies headers, runtime, version and notices. [38806112948](https://github.com/sunyych/PocketGigaScan/actions/runs/38806112948) compiled the Rust test binaries and passed 206 unit tests (3 ignored), 6 alignment-cache integration tests and the exact serial/parallel matching output comparison. It then stopped on a test-only four-worker expectation because the runner has three logical CPUs. Two host-aware expectations replace the incorrect fixed count; all 11 relevant Windows integration tests, Rust formatting and seven Mac package contracts pass. Production matching is unchanged. Hosted full Release/package and user visual acceptance are still pending.

[38808362645](https://github.com/sunyych/PocketGigaScan/actions/runs/38808362645) passes all 241 Mac native tests (3 optional ignored), normal native Release compilation, and Flutter analysis. The full Flutter run has 312 passing tests and 25 failures: five task-record fixture failures caused by applying Windows path rules to POSIX paths, and twenty screenshot-comparison failures. The helper-only path correction passes all 13 relevant Windows service tests and analysis; production provenance checks are unchanged. Mac native-menu/permission localization is also now wired and covered by eight package contracts. Actual Mac golden failure PNGs and explicitly non-qualifying full snapshot diagnostics are collected before approving any new baseline. Flutter checks now run before expensive native compilation; Cargo outputs use the source fingerprint cache. Full app/Xcode/package qualification remains pending.

[38811272193](https://github.com/sunyych/PocketGigaScan/actions/runs/38811272193) confirms the POSIX fixture correction: 317 Flutter tests pass and only 20 screenshot methods fail against Windows raster baselines. Its diagnostic-only capture runs all 40 relevant screenshot/interaction tests and supplies 30 complete PNGs. Luna Flutter and Codex independently inspect the actual/expected/difference images: dimensions and layout match; changed pixels stay within one pixel of existing glyph/stroke edges in all 30 pairs (zero changes outside that edge band). The reviewed Mac PNGs now have separate exact baselines, documented provenance and byte-for-byte checks against the artifact. All 30 old Windows PNGs match HEAD unchanged. No tolerance or test skip was added. Windows full Flutter validation now passes 340 tests, including three routing cases, with clean analysis; eight Mac contracts also pass. The next actual Mac run must qualify these committed baselines and the complete Xcode/app/model/export package.
