# Deghost continuity implementation plan

> **For agentic workers:** Execute task-by-task with Luna coders and independent coordinator review, as required by AGENTS.md.

**Goal:** Remove abrupt quality-based source switching that produces small polygon patches in final panoramas, in the shared Windows/Android renderer.

**Architecture:** Preserve geometry, source coverage and global seam ownership. Replace binary quality caps with continuous suppression and a stable common normalization reference. Invalidate incompatible render caches without deleting old outputs.

**Tech Stack:** Rust 1.88, Flutter, OpenCV, Python/Pillow.

**Spec:** User-approved bounded design in this chat: real-photo old/new comparison, targeted shared-engine fix and regression coverage. No blur applied to final image to hide seams.

## Global constraints

- Preserve originals, exported results, task compatibility, neighbor-only registration, estimated-grid provenance, separate preview/final rendering and resumable ownership.
- Do not claim full-panorama or Android hardware acceptance from synthetic or cropped-layout tests.
- Preserve unrelated dirty working-tree changes; coder owns renderer, second coder owns a new validation script, coordinator owns docs and builds.

### Task 1: Continuous quality weights

Files: `native/core/src/spherical_renderer.rs`.

- [x] Add regression tests that sweep blur and obstruction thresholds and check bounded adjacent weight changes, source permutation, flat/no-peer coverage and finite weights.
- [x] Replace binary eligibility/reference changes with continuous quality suppression, retain strong-evidence cap behavior and use stable softmax normalization.
- [x] Bump deghost renderer identity; keep feather compatibility and fail closed on mixed render caches.
- [x] Run `cargo +1.88.0 fmt --check` and source-native tests with pinned OpenCV/JXL dependencies.

### Task 2: Real-photo comparison

Files: new `scripts/verify-deghost-continuity.py`; private outputs under `.local/scale-artifact-diagnosis`.

- [x] Extract level-zero crop and generate same-angle/full-resolution ROI layout through CLI arguments without committed personal paths.
- [x] Extract and reproduce the existing real-photo artifact; generate isolated comparison layouts. User explicitly took ownership of full restitch/visual comparison, so no new real-photo render is required for this build handoff.
- [x] Preserve diagnostic measurements and before/after crops privately; record reproducible commands and evidence boundaries in repository docs.

### Task 3: Qualification and handoff

Files: `docs/gigascan/COLLABORATION.md`, `docs/gigascan/ROADMAP.md`, new evidence document.

- [x] Independently review both coder patches; run native suite/formatting, Flutter analysis/tests and Windows/Android builder contracts.
- [x] Build normal Windows Release using `scripts/build-dwarf-stitch-windows.ps1 -PrepareSigning` with verified cached dependencies.
- [x] Build Android shared native engine and APK where local toolchains permit; report actual device-validation boundary.
- [x] Commit only owned changes with a conventional commit on a `codex/` branch; record source identity and deliverables without committing private photos/caches/binaries.


## Follow-up after user restitch

The same-position 1.4.8+27 comparison retains hard truck/SUV triangles. Continue the approved repair with a full-layout selected-tile diagnostic, preserving original coordinates and all source photos. Baseline must reproduce the completed task before implementation. Disjoint ownership remains Luna renderer coder, Luna independent reviewer, Codex docs/build/qualification.

1. Compare full saved layouts and extract the exact level-zero region.
2. Render selected tiles with original global ownership lattice; ablate coarse owner, actual local source warps and deghost.
3. Couple peer quality and support to a single best geometric other source, excluding self and continuously discounting near-edge evidence. Preserve conservative supported blur, flat/unique coverage, source-order stability and bounded memory. Advance deghost identity only.
4. Verify targeted real-source tiles plus native regressions, formatting, Flutter checks and build contracts; build 1.4.9+28 Windows/Android using normal-user toolchain/output paths.
5. Preserve old test builds and task data. Record exact artifact hashes and separate local real-crop acceptance from full panorama/device qualification.
