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

- [ ] Add failing tests that sweep blur and obstruction thresholds and check bounded adjacent weight changes, source permutation, flat/no-peer coverage and finite weights.
- [ ] Replace binary eligibility/reference changes with continuous quality suppression, retain strong-evidence cap behavior and use stable softmax normalization.
- [ ] Bump deghost renderer identity; keep feather compatibility and fail closed on mixed render caches.
- [ ] Run `cargo +1.88.0 fmt --check` and source-native tests with pinned OpenCV/JXL dependencies.

### Task 2: Real-photo comparison

Files: new `scripts/verify-deghost-continuity.py`; private outputs under `.local/scale-artifact-diagnosis`.

- [ ] Extract level-zero crop and generate same-angle/full-resolution ROI layout through CLI arguments without committed personal paths.
- [ ] Render baseline/current/fixed variants into independent directories. Inspect static container edges and vehicles separately; record crop-lattice limitations.
- [ ] Preserve diagnostic measurements and before/after crops privately; record reproducible commands and evidence boundaries in repository docs.

### Task 3: Qualification and handoff

Files: `docs/gigascan/COLLABORATION.md`, `docs/gigascan/ROADMAP.md`, new evidence document.

- [ ] Independently review both coder patches; run native suite/formatting, Flutter analysis/tests and Windows/Android builder contracts.
- [ ] Build normal Windows Release using `scripts/build-dwarf-stitch-windows.ps1 -PrepareSigning` with verified cached dependencies.
- [ ] Build Android shared native engine and APK where local toolchains permit; report actual device-validation boundary.
- [ ] Commit only owned changes with a conventional commit on a `codex/` branch; record source identity and deliverables without committing private photos/caches/binaries.
