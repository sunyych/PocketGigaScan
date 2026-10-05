# PG-045 — texture registration and collapsed viewer details

Status: implementation and verification in progress. The user's screenshots show
building columns displaced at a seam and a sharp foreground foliage transition.
The existing9-source and reduced384 validation did not qualify this full384 output.

## Actual failed output

The filename identifies task1791133028895854-519f2dc1,16x24 originals at3840x2160.
Its completed76180x28515 BigTIFF is8689243212 bytes. Its actual old layout reports
430 accepted of728 cardinal edges, six visual components,42.710px ray RMS,
86.073px P95,369.098px maximum and363.937px worst-edge RMS. Grid-assisted mode
continued after these excessive errors with warnings. Rotation averaging used
only40 sequential sweeps; reported pose optimization was9ms.

All task/photos/exports under AppData/OneDrive remain read-only. Old layout and
job-state snapshots, original request and a level5 overview are retained under
`.local/seam-texture-validation-20261004`. The real9-source layout had2.234px
RMS and6.094px worst edge, so only adding the old12px gate is not a complete fix.

## Ownership and validation

Luna seam_geometry_fix owns Rust registration/cache version and regressions.
Luna viewer_status_fold owns viewer details control, tests/goldens and version.
Luna texture_validator owns independent adjacent texture metrics/crops.
The coordinator reviews source, controls SDK gates and performs integration and
release verification. No global all-photo matching is authorized or required.

Pure rotation refinement cannot guarantee alignment of foreground objects at
different depths or moving leaves; static architecture and actual seam crops
are the primary geometry acceptance evidence. New output formats do not alter
old rendered pixels. Existing saved checkpoints and exports remain preserved.

## First original-resolution384 refinement probe

Prototype DLL7c0e8b95 reduced the same67539 accepted correspondence ray RMS
from42.710px to4.982px, P95 from86.073px to7.340px, but failed the unchanged12px
worst-edge gate: edge71->95 was67.180px RMS.40 sweeps had not converged.
No layout or output was published by this failed validation. Summary:
`.local/seam-texture-validation-20261004/user-full-alignment-v1/failure-summary.json`.
This is improvement evidence, not delivered seam acceptance.

The independent checker identifies the same glass tower ROI at old level-zero
x49810/y13620/1500x2200. Native cropped rendering exactly equals the old pyramid
pixels; evidence `before-native-roi-consistency.json` and `building-native-before.png`.
The old output's large vertical-column jumps are visible in this crop.

Viewer default collapse and source-change reset are implemented; analyzer and
all81 Flutter tests pass with reviewed collapsed/expanded screenshot baselines.

## Independent source diagnosis

Fresh Luna source review reproduces the original SIFT inlier counts. Worst
edges71->95 and70->94 lie at the right upper image boundary: overexposed white
sky with local foreground needle branches, not measurable cloud movement.
Their match coverage is narrow.330->331 and322->323 are repeated, blurred,
multi-depth foliage;372->373 includes thin electrical wires and forest texture.
These local homographies need not support a single rigid camera rotation.
Building controls207->208 and231->232 cover almost the full image height
(2072/2097 source pixels) with rigid window rows/columns and high inlier ratios.
Contact sheets: `edge-diagnostic-thumbnails.jpg`, `edge-inlier-matches.jpg`.

The independent baseline measures299 of728 cardinal edges and11243 validated
holdout correspondences, RMS37.739/P5019.628/P9576.664 output pixels.
It separately reports17365 raw held-out ratio matches, including false matches,
and all rejected counts. Cache uses source SHA256/size and matcher parameters;
future comparison uses exactly the same point cohort. The7 checker unit tests
and Python compilation pass. Baseline remains before=after, not repair evidence.

## Second full384 probe and independent architectural reference

The second probe (DLL `f1df6d2b`) still fails: global matched-ray RMS3.334px,
P955.494px, worst edge50.639px.120 block-coordinate sweeps do not converge.
The cycle heuristic removes21 edges and exhausts its budget, without satisfying
the final gate. Full failure evidence is retained in
`user-full-alignment-v2/native-failure.json`; no production output is published.
The next implementation replaces slow coordinate relaxation with a joint
component solve rather than increasing removal budgets or weakening the gate.

An isolated coordinator SciPy reference uses six architectural originals
(183,184,207,208,231,232), seven cardinal edges and730 training correspondences.
It fixes one pose and jointly solves15 rotation degrees of freedom with Huber
pixel residuals;32 evaluations converge.282 independently held-out points
improve from29.757px RMS/P9565.717px to1.554px RMS/P952.617px in the original
output coordinate scale. A native render of the exact same angular crop visibly
joins the previously displaced vertical window columns. This is a local reference,
not full384 production acceptance. Evidence: `building-reference.py`,
`building-reference-metrics.json` and `building-reference-six-native.png`.

Fresh Luna review corrects the earlier BFS-only description of leave-one-out:
the existing solve also performs40 anchored robust weighted averaging rounds.
Visual connectivity and endpoint re-lookup are sound; alternate paths alone
still do not establish independent reliable cycle evidence.

Solver research was checked against the primary
[Ceres nonlinear least-squares solver documentation](https://ceres-solver.readthedocs.io/latest/nnls_solving.html),
which describes robust least squares, normal-equation iterative solvers and
preconditioning for sparse bundle structure. This informs the joint optimization
direction; it is not a Ceres dependency or evidence that our implementation passes.

## Joint bundle full384 probe (still not accepted)

Prototype `40dadb39` improves the exact independently verified299-edge/11243-point
cohort from37.739px RMS/P9576.664px to2.009px RMS/P953.195px after native center
reorientation. The native architectural crop joins the previously displaced
columns (`building-native-after-v3-centered.png`). These are actual original-photo
geometry and crop evidence, not synthetic results. The raw ratio-match cohort is
reported separately and remains dominated by rejected descriptor matches.

Registration still fails: retained training RMS3.798px, worst edge71->95
109.019px,30 joint iterations not converged. PCG's maximum true relative residual
is8.698, so accepting every truncated direction is insufficient. A reliable
linear-solve acceptance gate and Cholesky fallback are under test; production
cycle pruning remains disabled. The fourth original-photo probe explicitly
requests a validated correspondence snapshot for subsequent offline warm-start
diagnosis without repeating SIFT. Source photographs and existing outputs are
still unchanged, and no full384 production result is published.

All126 Rust tests passed for `52472792`, including the384-camera low-FOV grid,
both native JXL probes, long-loop convergence and component anchors. The current
viewer passes all81 Flutter tests plus actual Windows batch PNG/TIFF/JXL flows.
The JXL integration now verifies fold/expand, zoom and drag with real desktop
view IDs, and task removal preserving original/output bytes. Logs:
`windows-{batch,tiff}-joint-final.log`,
`windows-jxl-joint-fold-fixed-viewid.log`.

## Reliable joint solve and audited diagnostic replay

The fourth actual384 probe (`3a1eb012`) converges in21 joint iterations.
Every accepted PCG solve has a recomputed true relative residual below1e-3;
the measured maximum is9.808e-9, with628 maximum iterations and no failed
accepted directions. The retained graph still fails the unchanged12px
worst-edge gate:71->95 is109.019px. Solver convergence alone does not authorize
publishing this layout.

The exact independent299-edge/11243-point cohort, after native center
reorientation, measures2.008601px RMS/P953.195149px, versus the original
37.738738px RMS/P9576.663988px. All384 original source SHA256/size checks pass;
the baseline values are reproduced exactly. Evidence:
`validator-after-v4-centered/texture-alignment-report.json`.

The coordinator also renders a1200x1200 native crop around the old330->331
foliage seam, using identical angular bounds and unchanged original files.
The conspicuous horizontal boundary in the old crop is reduced in the new
diagnostic render (`foliage-native-before-v4-comparison.png`, old left/new
right). Blurred foreground texture remains blurred; this local check does not
establish every foreground seam or the exact location of the user's first
screenshot. Building evidence: `building-native-after-v4-centered.png`.

The diagnostic snapshot came from a producer built before explicit solver
metadata was added. An audited diagnostic migration validates the original
snapshot hash, every source hash, matching/grid/intrinsic parameters and the
actual producer DLL SHA256. It adds only the verified unchanged solver
parameters and provenance, asserting that all points and poses are preserved.
The raw snapshot remains intact. Original hash:
`d07e551f2c555370b66c5a28a2d873cf27c69036a75902857ba0da6f36a29672`;
upgraded hash:
`0154511217956e51b75debbd1c0ab23bf2326d9be5184916372ec6e8e183c61c`.
This is diagnostic replay, not a production layout/cache upgrade.

True joint leave-one-out for71->95 converges in12 iterations, with maximum
true linear residual9.999e-9. Retained RMS falls to2.837336px, but the next
worst edge290->314 remains22.587610px. The excluded36 correspondences disagree
by119.428287px. The replay explicitly reports `diagnosticOnly=true`,
`productionLayoutEmitted=false`, and does not pass the production gate.
Sequential generic weak-edge rejection is under development; no photo-specific
exclusion list or relaxed quality threshold is accepted.

The metadata-hardening suite passes128 Rust tests:99 library,6 FFI,3 matching,
8 planner,7 spherical and5 stitch, including both native JXL probes.
Log: `core-tests-v7-metadata-upgrade.log`.

## Sequential production-helper replay (not accepted)

Fresh independent review found that candidate before/after metrics initially
used different correspondence sets. This would reward deleting the candidate
itself. The corrected helper measures both poses on exactly the same retained
set, protects strong evidence and visual connectivity, and rejects a candidate
only after a converged joint trial improves retained RMS without worsening its
worst edge. All successful removals restart candidate evaluation. Cache version8
invalidates older placement results. Offline replay remains diagnostic-only.

The complete automatic replay uses the same helper as production, not a
photo-specific exclusion list. It evaluates11 candidates, accepts only71->95
and290->314, retains9 others, and does not exhaust the bounded budget.
Retained training RMS2.812166/P954.913307px, worst267->26817.394154px;
the12px gate still fails and no production layout is emitted. Debug/unoptimized
replay takes approximately5m33s; this is not a release performance measurement.
Evidence: `user-full-alignment-v4/auto-prune-joint-loo.{json,log}`.

The exact independent cohort after the two accepted removals measures
2.005139px RMS/P953.194196px. The maximum per-edge RMS increase is0.173px at
229->253 (14.186763 to14.359733px); aggregate improvement does not establish
every seam. Removing267->268 or268->292 independently worsens other retained
geometry, so further deletions are not justified by the current single-edge
test. Additional model/group diagnosis is in progress.

Read-only EXIF checks on originals0,207,267,290 confirm DWARFLAB/DWARF3,
3840x2160 and150mm focal length. This agrees with the150mm lens and2um pixel
pitch documented in the manufacturer's [DWARF3 information](https://www.dwarflab.com/ca/pages/birding-with-dwarf-3-smart-telescope);
75000px is the inferred focal scale, not an arbitrary replacement parameter.

## Bounded source-plane correction probes (still not accepted)

Luna added a bounded source-plane displacement field after joint SO3 alignment,
with a 64px displacement cap, 0.10 local strain cap, supported controls, fixed
component anchors and monotonic same-correspondence-set validation. The renderer
inverts this field when sampling original pixels. Missing support preserves
original geometry; it does not justify arbitrary grid deformation.

The first 3x3 probe improves the exact independent 299-edge / 11243-point cohort
from 37.738738px RMS / 76.663988px P95 to 1.469467 / 2.538109px. Native building
and foliage crops were inspected. Building rendering takes 4877ms versus 1520ms
without the local field; foliage takes 1852ms versus 850ms. These are small crop
measurements, not a full-canvas speed claim. Originals and old outputs remain
unchanged.

The second probe uses distinct per-control support, locks unsupported controls
exactly to zero, and accepts eight monotonic rounds. The same independent cohort
measures 1.436796px RMS / 2.462760px P95. Retained fitting RMS is 2.20905px, but
the worst edge remains 16.59535px. The unchanged 12px gate fails; no production
layout is accepted. The fitter reports iteration_limit rather than convergence.
Evidence: texture-warp-auto-prune-preview-v2.json and
validator-after-warp-v2/texture-alignment-report.json under the local validation
root. Further local capacity/conflict diagnosis is in progress.

The second probe passes 140 Rust tests: 111 library, 6 FFI, 3 matching, 8 planner,
7 spherical and 5 stitch. Both native JXL allocator/reader probes and independent
djxl decode run. Log: core-tests-warp-v2-final.log. Flutter analyzer and all 83
unit/widget/golden tests pass with the default-enabled local correction checkbox
and collapsed viewer information. These checks do not establish final 384-photo
production acceptance or full-resolution visual qualification.

Coordinator review on October 5 identifies a possible capacity bottleneck in
the local fit: the per-control-neighbor smoothing weight is 32, which may
outweigh the robust data weight of sparse overlaps even when the corresponding
controls are supported. Luna is comparing regularization strength and spatial
residuals before changing model resolution. Displacement, local strain,
connectivity, same-set validation and the 12px production gate remain fixed.
This is an investigation, not an accepted parameter recommendation.

Independent Python capacity checks reproduce the 3x3 baseline and its smoothing
sensitivity. On the same 67485 retained correspondence pairs, 5x5 controls with
smoothing0.25 measure1.692px RMS /3.208px P95 and worst12.473px, still above the
strict12px gate. Strong incident seams311->335,358->359,334->335 improve rather
than regress in this experiment. Maximum displacement50.92px and strain0.0961
remain within the same64px/0.10 limits. These are training-set capacity
experiments, not independent image acceptance or production output. The root
independent projection checker now passes14 tests for3x3/5x5/9x9 math.

The independent fixed-pose audit identifies repeated point-count weighting:
constraint.weight already incorporates inlier support, and applying it again to
every correspondence makes large edges dominate approximately quadratically.
Using constraint.weight/pointCount preserves the native confidence/residual
factor while removing this repeated support factor. The 5x5 normalized fit with
smoothing0.025 measures1.723px RMS/P953.250px;335->359 falls to9.306px and the
worst retained edge becomes129->130 at11.102px. Maximum displacement35.77px and
strain0.0528 stay within the original safety limits. Neighboring strong seams
remain approximately1.1-1.9px. This motivates the production candidate; the
coordinator must still check held-out image correspondences and native crops.

Important limitation: removing the entire335->359 edge from fitting leaves that
edge17.39px apart. Its local correction depends on its own measured
correspondences, so foreground depth inconsistency versus erroneous texture
matches is not established. A9x9 from-zero model lowers global RMS but worsens
this seam and reaches the strain cap; higher resolution alone is not accepted.
Reproducible scripts and individual normalized-weight JSON runs are summarized
in independent-warp-capacity-audit-summary.json. Input wrapper SHA256:
4297a7f56844e18c3a6e938075e0ecb053b5728f6b19f22e966082337fc8e725.

## First successful fresh-source production run (October 5)

The actual384 originals now pass normal production registration with candidate
DLL SHA2563108ea44c2635fb5bbdbfb66532e5799cbb6cdc33c9e54392bb30430ff1566d8,
without importing a diagnostic layout or bypassing the unchanged gate. Wall time
493.297s with6 matching workers. All384 tiles remain,428 visual edges are retained,
and the two generic leave-one-out rejections preserve visual connectivity.
Corrected training RMS1.458877px/P952.804369px;worst edge11.102350px.
The exact independent299-edge/11243-point cohort measures1.170056px RMS and
2.092276px P95, compared with old37.738738/76.663988px. Some individual seams
regress slightly relative to the earlier prototype; aggregate improvement is
not an every-seam guarantee. Source hashes are verified and the old result is
unchanged. Quality remains needs-visual-review because disconnected visual
components/sky placements are grid estimated and local warp depends on measured
texture. No full8.7GB output or all384 seams have been visually qualified.

All sampling geometry of the accepted production layout is exactly equal to the
native-rendered candidate crops, including all poses, intrinsics, offsets,
source paths and canvas bounds. Only diagnostic versus production provenance
labels differ. Evidence: user-full-production-20261005-v1/evidence.json,
validator-production-final/texture-alignment-report.json and
production-native-crop-geometry-consistency.json. Root inspected building and
foliage native crops. Joint SO3 converges; local warp reaches its bounded8-round
limit and accurately reports nonconvergence. Native crop timing includes other
concurrent validation work and is not an isolated performance benchmark.

The core passes144 tests and all three Windows PNG-batch/TIFF/JXL functional
flows against this exact DLL pass. TIFF's first final command used the wrong
fixture define and failed before exercising native output; the corrected run
passes (windows-tiff-final-3108-correct-fixture.log). The JXL flow covers collapsed
information, wheel zoom, drag and task deletion preserving files.

Fresh Luna review finds a coarse-to-fine fallback bug: the caller reads the last
level's diagnostics and can discard an accepted coarse field when a finer level
fails. The frozen first candidate is therefore not packaged. Luna is fixing
this caller-level behavior, adding regression tests and invalidating its cache
version before final requalification.

## Final Windows 1.0.7+8 qualification (October 5)

Luna fixed the caller fallback and added its regression. Final core commit:
368f867db86576968dac92185211d75a15aab06c, clean core worktree; cache12/bundle6.
DLL SHA256e8b50238daced33fd320ef6432f9e0b39ae5b3d6046c42e43a638527bc62443e.
The exact final DLL passes fresh-source384 registration in498.016s (6 workers),
retains384 photos, and measures training RMS1.458877/worst11.102350px under the
unchanged12px gate. Its exact independent cohort remains1.170056px RMS /
2.092276px P95. All source sampling fields and bounds equal the inspected native
crop layout. The final renderer's15 building PNG tiles are byte-identical to the
reviewed crop. Grid/weak-texture placements and local parallax retain the honest
needs-visual-review state. Full-canvas/all-seam visual qualification is pending.

145 Rust tests,83 Flutter tests,14 independent checker tests and all three final
Windows native suites pass. Native logs: windows-batch-final-e8b5.log,
windows-tiff-final-e8b5.log,windows-jxl-final-e8b5.log. Build:
windows-release-1.0.7-e8b5.log. The executable targets lib/main.dart, reports
1.0.7+8, and bundles the exact pinned final DLL. Current UI baselines cover
collapsed/expanded information and the enabled/disabled/paused local checkbox;
Ahem-font baselines prove geometry/state, not readable Chinese typography.

Package: .local/releases/lumia-stitch-1.0.7-20261005-core368f867/
Lumia-Stitch-1.0.7-Windows-x64.zip (23467695 bytes). SHA256:
67651bd403b889843410f91ce0f5882ccb7a729714d650fbf36247eeeb4f46d7.
The31-file package passes CRC and every-file hash checks, x64 PE checks,
PNG/TIFF/JXL native capability checks and lossless-JXL availability, with10
licenses and3 independently hash-verified official tools. Original photos,
old tasks/exports and previous releases are preserved. Existing bad outputs
require **新建副本重新合成**; re-exporting cached tiles does not repair alignment.
Local correction adds rendering work; the alignment-only498s timing is not a
full8.7GB export benchmark or a whole-process memory guarantee. Mobile packages
and physical camera validation remain separate. No core remote exists for a PR.
