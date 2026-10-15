# macOS desktop client implementation plan

> For agentic workers: use the user-requested coordinator and Luna coders with disjoint files. The coordinator reviews, qualifies, commits and pushes the resulting branch.

**Goal:** Deliver a macOS desktop client with the existing panorama pipeline and offline people protection/water smoothing, while keeping semantic inference unavailable on phones.

**Architecture:** Extend the existing Flutter desktop shell and Rust/OpenCV pipeline. Reuse the pinned UPerNet ONNX graph and CPU runtime through a portable private native bridge. Bundle model/resources and architecture-matched dylibs in an ad-hoc-signed macOS app; build the app on a real hosted Mac runner.

**Tech stack:** Flutter 3.44.2, Rust 1.88.0, OpenCV 4.13.0, libjxl 0.12.0, pinned ONNX Runtime 1.31.0, existing SHA-256-verified scene model.

**Spec:** User request on 2026-10-15: people-aware merging is desktop-only (Windows/macOS); no mobile semantic feature; develop the Mac client for subsequent user testing.

## Global constraints

- Keep geometry, neighbor-only matching, originals, stored tasks and existing exports intact.
- People protection and water smoothing stay independent, default off, with people taking priority.
- Phones hide both controls, never prepare/package the model, and force native scene flags off even for imported desktop task settings.
- Model path: Windows `data/models/scene-model-v1.onnx`; macOS `Contents/Resources/models/scene-model-v1.onnx`.
- Runtime path: absolute sibling of the core module in `Contents/Frameworks`; no system/PATH fallback.
- Minimum macOS is 14.0, verified from the actual ORT 1.31 arm64 Mach-O load command.
- Initial package defaults to Apple silicon while the optional user architecture answer is pending. Official ORT 1.31 has an arm64 Mac asset; do not silently downgrade the runtime for Intel.
- No Apple ID, notarization or runtime account is required for this developer test package. Record ad-hoc signing separately from public notarized distribution.
- Work only in the clean `codex/macos-desktop` worktree; preserve the original checkout's unrelated changes. Commit and push completed work.

## Task 1: portable native scene bridge — Luna native

Files: `native/core/build.rs`, `src/scene_analysis.rs`, `src/native/scene_bridge.cpp`, `src/job.rs`, `src/job_resources.rs`.

- [x] Compile the bridge for Windows/macOS and enable static JXL SDK linkage on macOS; keep Android/iOS semantic execution rejected.
- [x] Use a private UTF-8 path/error C ABI, Windows UTF-16 conversion, and macOS `dladdr`/absolute `dlopen`/`dlsym` validation.
- [x] Preserve model preprocessing, shared analysis, CPU reservation, mask validation and legacy disabled request identity.
- [x] Run `cargo +1.88.0 fmt --check --manifest-path native/core/Cargo.toml`; coordinator runs the full Windows source builder and actual macOS CI checks.

## Task 2: desktop capability and bundle paths — Luna Flutter

Files: `Apps/Flutter/stitch_app/lib/**`, relevant `test/**`, `pubspec.yaml`.

- [x] Centralize a testable Windows/macOS capability and use it for controls, model preparation and native request construction.
- [x] Resolve the Mac model relative to `Contents/MacOS`, retaining the Windows path and exact model SHA/size verification.
- [x] Keep English/Chinese UI and default-off storage compatibility; bump client version to 1.5.1+30.
- [x] Test Windows/macOS paths, both locales and mobile options-off behavior, then run Flutter analysis and the full test suite.

## Task 3: Mac app, source build and packaging — Luna package

Files: `macos/**`, `tool/native/apple/**`, `APPLE-BUILD.md`, `scripts/build-stitch-macos.sh`, `macos-dependencies.lock.json`, `verify-macos-package.py`, `scripts/tests/test_macos_build.py`, `.github/workflows/macos-build.yml`.

- [x] Add the real tracked Runner, PocketGigaScan identity and a direct-distribution entitlement configuration that supports photo import, arbitrary exports and task recovery.
- [x] Source-build verified OpenCV/JXL, use a verified official arm64 ORT SDK, and compile this repository's Rust engine.
- [x] Stage model/resources/licenses, rewrite/verify dylib dependency closure, ad-hoc sign inside-out, and ZIP the resulting app with a build manifest.
- [x] Export the model in a Windows CI preparation job using the existing pinned exporter; Mac jobs consume the verified artifact, avoiding unsupported Intel PyTorch wheels or architecture-dependent re-exports.
- [ ] Run `python -m unittest discover -s scripts/tests -p 'test_macos_build.py'`, shell syntax checks, then native Mac CI build and packaged-FFI/model/export smoke tests.

## Coordinator acceptance

- [x] Independently review platform gates, Unicode paths, model/runtime loading and packaging contracts.
- [x] Run Rust formatting/native tests, Flutter analysis/full tests, Windows/Android/Mac build contracts and a normal Windows Release build for regression.
- [ ] Push the branch and inspect actual Mac CI results; collect the usable Mac test app when available.
- [x] Record local/static, hosted Mac native, and user physical/visual evidence separately in the collaboration ledger and roadmap.

Implementation and local validation are complete. Hosted Mac compilation/package smoke and user physical/visual acceptance are pending, and are tracked separately. Windows/Android CI staging/install regressions received narrow contract-tested fixes during review.
