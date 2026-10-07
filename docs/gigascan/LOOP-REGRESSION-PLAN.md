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
- The completed 1.2 task uses different overlap/fallback parameters, so it is not
  a controlled version comparison. Run the exact failing request first.
- Hundreds of alternating retry extraction/matching events are a bounded
  neighbor pass, not proof that the task restarts. Preserve cancellation and
  explicit estimated-grid provenance. Never compare arbitrary non-neighbors.

## Task 1: preserve registration failures and useful progress

Owner: Luna native coder. Files: `native/core/src/job.rs` and its unit tests.

- [ ] Group inner retry substages into one timeline phase.
- [ ] Advance registration progress at completed stage boundaries, monotonically
  within the existing registration interval; do not infer percentage from time.
- [ ] Preserve complete spherical failure diagnostics in a job-owned JSON file,
  expose the failure stage clearly, and retain pause/cancel semantics.
- [ ] Test timeline grouping, progress boundaries, diagnostic retention and
  cancellation; maintain old task/snapshot compatibility.

## Task 2: identify and repair actual bad neighbor evidence

Owner: Luna geometry coder after Codex reviews the real reproduction.
Files: `native/core/src/spherical.rs`, geometry regression tests.

- [ ] Replay all 364 full-resolution originals with exact failed parameters and
  the packaged 1.3 DLL, capturing complete correspondence diagnostics.
- [ ] Identify worst-edge points, spatial support and graph connectivity; compare
  the successful task without assuming its output is geometrically verified.
- [ ] Implement only an evidence-supported correction; preserve bridges and all
  tiles, bounded solver work, and the existing reprojection thresholds.
- [ ] Add a regression that demonstrates the original failure and the repaired
  behavior, then replay the preserved real evidence.

## Task 3: shared operator presentation and qualification

Owner: Luna Flutter coder; Codex runs SDK commands serially.
Files: timeline/localization models and targeted tests; main/controller only if
required by the diagnosed behavior.

- [ ] Translate grouped retry and registration-failure phases in EN and ZH.
- [ ] Repeated unchanged status cannot grow timeline or trigger another export.
- [ ] Run native format/tests, Flutter analysis/tests, build-script contracts,
  and normal Windows Release build. Record physical-device and full-panorama
  visual checks separately from host/synthetic evidence.
- [ ] Record handoffs and actual validation in ROADMAP/COLLABORATION and evidence.
