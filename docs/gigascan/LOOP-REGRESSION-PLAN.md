# Stitch completion and neighbor regression repair

Goal: restore bounded, observable stitching and diagnose the supplied real-photo
neighbor failures without lowering geometric acceptance thresholds.

This repairs the already approved stitching and timestamped-log behavior. Codex
coordinates and reviews; Luna coders own disjoint source files. Windows and
Android share the repaired core and Flutter presentation.

## Evidence and constraints

- Preserve original task directories, photos, cached layouts and exports. Replay
  requests only into fresh ignored `.local/loop-regression-20261006` directories.
- Local records include a 364-photo 14x26 task that failed after 374 seconds with
  global RMS 1.96px but a 55.01px worst edge, and a 384-photo 16x24 failure with
  a 107.61px worst edge. Both retain the last source-plane warp checkpoint.
- The completed older task differs from the initial automatic failure in
  overlap/fallback parameters. The subsequently reported manual failure matches
  the completed task's scalar parameters. Check both cohorts and the actual
  older 1.2.1 engine; a 1.2.2 replay does not represent 1.2.1.
- Hundreds of alternating retry extraction/matching events are a bounded
  neighbor pass, not proof that the task restarts. Preserve cancellation and
  explicit estimated-grid provenance. Never compare arbitrary non-neighbors.

## Task 1: preserve registration failures and useful progress

Owner: Luna native coder. Files: `native/core/src/job.rs` and its unit tests.

- [x] Group inner retry substages into one timeline phase.
- [x] Advance registration progress at completed stage boundaries, monotonically
  within the existing registration interval; do not infer percentage from time.
- [x] Preserve complete spherical failure diagnostics in a job-owned JSON file,
  expose the failure stage clearly, and retain pause/cancel semantics.
- [x] Test timeline grouping, progress boundaries, diagnostic retention and
  cancellation; maintain old task/snapshot compatibility.

## Task 2: identify and repair actual bad neighbor evidence

Owner: Luna geometry coder after Codex reviews the real reproduction.
Files: `native/core/src/spherical.rs`, geometry regression tests.

- [x] Replay all 364 full-resolution originals with exact failed parameters and
  the packaged 1.3 DLL, capturing complete correspondence diagnostics.
- [x] Identify worst-edge points, spatial support and graph connectivity; compare
  the successful task without assuming its output is geometrically verified.
- [x] Implement only an evidence-supported correction; preserve bridges and all
  tiles, bounded solver work, and the existing reprojection thresholds.
- [x] Add a regression that demonstrates the original failure and the repaired
  behavior, then replay the preserved real evidence.

## Task 3: shared operator presentation and qualification

Owner: Luna Flutter coder; Codex runs SDK commands serially.
Files: timeline/localization models and targeted tests; main/controller only if
required by the diagnosed behavior.

- [x] Translate grouped retry and registration-failure phases in EN and ZH.
- [x] Repeated unchanged status cannot grow timeline or trigger another export.
- [x] Run native format/tests, Flutter analysis/tests, build-script contracts,
  and normal Windows Release build. Record physical-device and full-panorama
  visual checks separately from host/synthetic evidence.
- [x] Record handoffs and actual validation in ROADMAP/COLLABORATION and evidence.
