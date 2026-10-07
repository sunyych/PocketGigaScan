# PG-054 retry progress and weak neighbor registration

Qualified final source: `a6a5868`, version **1.3.1+15**. Initial
candidate `28e94c3` establishes the automatic-request repair. Codex coordinates
and independently reviews three Luna coders with disjoint native job/pipeline,
spherical geometry and Flutter timeline ownership. This extends PR #5.

## Reproduction and cause

Preserved local jobs contain **364 full-resolution 3840x2160 photographs in a
14x26 grid**. Original tasks, photos, caches and exports are left untouched;
replays use fresh ignored output directories with alignment-cache reuse disabled.

The first automatic-overlap failure terminates after about six minutes with
1.96px global RMS and a 55.01px worst edge. Its 171 alternating extraction and
matching events describe a finite neighbor retry pass. The old 2% checkpoint and
ungrouped log made this look like a restart loop; the terminal failure is a
separate geometric problem. Local warp did not iterate indefinitely.

The exact automatic request fails identically with packaged **1.3.0 and 1.2.2**:
RMS 1.95550356px, worst edge 55.01343566px. These runs took 417.688s and
479.391s on a machine with other jobs, so they are not isolated speed benchmarks.
The user's running older successful application is **1.2.1**, not 1.2.2; the
1.2.2 comparison cannot establish the behavior of 1.2.1. A separate exact manual
replay with the packaged **1.2.1** engine succeeds: RMS 1.50270439px, worst edge
9.71433971px, all 364 tiles; 960.922s while other verification/builds run. This
confirms the reported distinction for the manual cohort and must not be obscured
by the automatic-parameter 1.2.2 comparison.

The latest manual-overlap failure has RMS 1.92px and worst edge 56.83px. Its
scalar registration parameters match the preserved completed older task:
manual overlap 0.3/0.3, explicit force-grid fallback, local texture correction,
neighbor refinement, 14x26 and fx/fy 75000. The initial automatic request uses
different overlap/fallback settings. Both parameter cohorts are checked separately.

Captured worst cardinal edges 76->77 and 50->76 have only 8 and 9 unique inlier
coordinate pairs. Their points occupy thin horizontal bands on both photos,
with cycle disagreement about 520px and 946px. Pairwise fits appear acceptable,
but including these constraints produces a globally contradictory layout.

## Repair

- Reject a visual constraint only when it has fewer than 16 unique valid
  correspondences, sparse one-dimensional spatial support and a bounding-box
  thin axis at most one eighth of the image on both ends, and cycle disagreement
  at least 48px. Preserve broad ordinary overlap and dense evidence for the
  existing acceptance checks. The ordinary 12px worst-edge gate is unchanged.
- Recompute visual components and estimated provenance before measured-grid
  bridges are synthesized. Keep every original photo vertex. Rejections remain
  explicit in diagnostics and force `needs-visual-review`; grid assistance does
  not become visual proof. Cache version 17 prevents old layout reuse.
- Keep the normal eight local-warp rounds. Only when the eighth accepted round
  is still above the 12px worst-edge gate and improves it by at least 0.01px,
  allow at most four more rounds. Stop additional work once the gate is met.
  Keep same-set RMS descent, worst-edge non-regression, inverse checks and
  existing displacement/strain limits. This reports a quality stop separately
  from solver convergence; stalled or exhausted fits still fail the quality gate.
- Batch failed-neighbor matching within the existing worker limit. Endpoint
  caches, deterministic ordering, release points and cancellation remain. Feature
  extraction stays serial under the native OpenCV lock; this is not a claim of
  parallel feature extraction or a measured overall speed multiplier.
- Advance registration progress at real stage and completed-batch boundaries.
  Group retry substages into one timestamped timeline phase, preserving job,
  operation and pause boundaries. Translate phase/count labels in English and
  Chinese; unchanged status does not grow logs or start another export.
- Persist complete registration diagnostics in job-owned
  `registration-failure.json`, with an explicit `registration-failed` terminal
  stage and a structured `REGISTRATION_FAILED` error. Preserve cancel/pause races
  and old task-storage compatibility.

Independent geometry review found no blocking tile/provenance issue. This narrow
gate does not detect every possible weak match: long diagonal collinear support
may evade the axis-aligned support test. Remaining bad evidence still goes
through the unchanged reprojection quality checks.

## Executed checks

- Rust 1.88 formatting and **186 native tests pass** (153 unit, 33 integration);
  two path-dependent real-photo fixture tests remain intentionally ignored.
  Tests include captured weak-point geometry, legitimate 20% overlap controls,
  graph connectivity, measured-grid repair, serial/parallel low-contrast matching,
  bounded progress, diagnostics, cancellation and cache-version invalidation.
  The final candidate additionally has actual three-tile solver tests: a 26px
  fixture extends to ten rounds and reaches 11.694px; a 32px fixture stops at
  twelve rounds while still above 12px; cancellation is observed at round nine.
- Flutter analysis is clean and **213 tests pass**, including 418 legacy retry
  events, repeated polling, job/pause boundaries, automatic-export ownership and
  English/Chinese progress counts. Host APIs use explicit fakes where appropriate.
- Windows and Android build-script contracts pass. Normal Windows Release builds
  the vendored core from source and verifies runtimes, licenses and ZIP integrity.
- Android ARM64 core and normal Flutter Release APK build from source. Seven
  Kotlin platform tests pass; lint reports 0 errors and 9 existing warnings.
  Inspection verifies ARM64 FFI exports, allowed native dependencies, 16 KiB ELF
  and ZIP alignment, signature and all 135 license files against their manifest.

## Packages and real-photo qualification

Windows x64 ZIP: `PocketGigaScan-Windows-x64-v1.3.1-15-completion-fix.zip`,
20,607,229 bytes; SHA-256
`aabc353cf012de214e4d846c8015046628431f58662022764315673642b67851`.
Production DLL SHA-256
`fc8025ed99a704b32bf460df7e92ed26781339122e3c36159195c3445305fbb8`.
The full real-photo replay loads an isolated copy with this exact DLL hash.
Use the EXE with its bundled runtime and license files.

Android APK: `PocketGigaScan-Android-arm64-v1.3.1-15-completion-fix.apk`,
38,811,895 bytes; SHA-256
`31304bf71e75aea5d771537049eee899da671fb5b782e32c1d5c30af78efab4c`.
Package `com.lumiaiq.pocketgigascan`, version 1.3.1/code 15, ARM64 only,
minimum API 29 (Android 10), target API 36, development signing.

The repaired **automatic-overlap** registration succeeds with all 364 photos:
RMS **1.63964950px**, worst edge **9.14488574px**, unchanged 12px gate.
Ten sparse, thin, cycle-conflicting visual constraints are excluded, including
the captured 50->76 and 76->77 failures. There are 248 tiles with direct accepted
visual evidence and 278 measured-grid bridges. All 364 remain classified as
outside the root-anchored visual component because the sky reference has no
accepted visual edge; the report remains `needs-visual-review`. Registration
took 577.203s under concurrent verification, not an isolated speed benchmark.
This registration-only run does not qualify its final rendering/export.

The first repaired manual replay (`28e94c3`) reduces the original 56.83px worst
edge to 12.08566642px, RMS 1.60957605px, but correctly fails the unchanged 12px
gate. Its diagnostics persist correctly in `registration-failure.json` and the
job terminates as `registration-failed`. Eight local-warp rounds are accepted,
with `iteration_limit` and `converged=false`; the worst remaining edge is diagonal
309->336. This evidence motivates the bounded extra work above rather than a
looser gate or deletion of the remaining measured edge.

Independent cardinal-neighbor holdout comparison of the preserved 1.2.1 manual
layout and the initial repaired automatic layout attempts 688 neighbor pairs,
measures 334 and accepts 10,696 held-out correspondences. Median/P95 errors are
0.976/2.473px before and 1.005/2.589px after. Whole-set RMS is 164.111/164.104px,
dominated by a repetitive-texture pair at (8,15)->(8,16) with about 4242px RMS in
both layouts. The explicitly forced tile (9,13) also has adjacent errors around
20px in both. These results do not establish all-seam acceptance or an overall
texture improvement, and the comparison uses distinct parameter cohorts.

The corresponding final **manual-to-manual** holdout comparison measures the
same 334 edges and 10,696 accepted points: median/P95 0.976/2.473px before and
0.996/2.518px after; RMS 164.111/164.110px. The large repetitive-texture outlier
and the explicitly forced cell remain. This restores completion with similar
typical held-out accuracy, not proof that all existing seam errors were repaired.

The final manual registration succeeds with all 364 original photos at
**80855x25050** output dimensions: RMS **1.60388029px**, worst edge
**11.94644369px**, unchanged 12px gate. Eight normal warp rounds plus two
additional accepted rounds stop with `quality_limit_reached`, not a fabricated
convergence claim. Ten weak conflicting edges remain explicitly excluded, 248
tiles have direct visual evidence, and 278 measured-grid bridges retain every
tile. Root-reference limitations still classify all tiles as estimated;
`needs-visual-review` is retained. Alignment time is 552.157s during concurrent
SDK work, not an isolated speed benchmark.

Full final manual rendering and automatic TIFF export both complete. The replay
renders 7,742 level-0 tiles and 18 pyramid levels, then automatically queues
lossless BigTIFF export. The output is **8,101,804,932 bytes** at
**80855x25050**. Total wall time including export is **1,864.641s** (31m05s)
under concurrent host verification; registration is 552.282s, level-0 rendering
1,099.901s, pyramid generation 144.497s, and export 61.272s. These are observed
phase timings, not an isolated before/after speed benchmark.

After the terminal export completion, independent TIFF directory parsing
verifies all 8,350 strip ranges, the exact raw pixel byte count, uncompressed
RGBA8 with unassociated alpha and offsets beyond 4GiB. First/middle/last occupied
tile-center samples exactly match the lossless level-0 PNG pixels. Validation
uses bounded seeks and small tile decodes rather than loading the 2-gigapixel
image into memory. The viewer pyramid and full-resolution export stay separate.

Codex visually inspects the final overview and corresponding 768px source-scale
before/after crops at the independently selected row 13, column 15->16 edge
(zero-based). The tree/branch textures look comparable, with no obvious new
straight seam in that crop. This sampled visual check does not qualify every
seam or the user's earlier building screenshot. Original tasks, photographs and
prior outputs are preserved; the fresh validation job is isolated.

ADB reports no connected device. No physical Android or all-panorama-seam
acceptance is implied by host tests or package construction.

Reproduce host builds using [BUILD](../../BUILD.md) and
[STITCH-TESTING](../STITCH-TESTING.md). Logs, requests, correspondence diagnostics,
personal photographs and generated packages remain in ignored local directories.
