# Corner coverage and automatic export — Windows 1.0.8+9

PG-046 follows the user's Windows 1.0.7 result review. This document records diagnosis and bounded Windows release validation.

## Reproduced input and output

The latest local task is `1791210101563058-337d86ef`, with all384 originals retained in its input directory and a75903×29176 rendered canvas. Existing task files, originals, pyramid and exported TIFF are read-only during diagnosis. A16×24 grid and central measured overlap were used. The existing global neighbor residual gate passes, but it does not measure coverage in unmatched sky tiles.

Independent pyramid reconstruction and source projection confirm that the screenshot's horizontal white strip and vertical step are transparent gaps. A sample at approximately(207,190) in level6 has zero alpha and no source-bounds intersection after projecting all384 current poses. This is a coverage/relative-placement defect, rather than a damaged TIFF pixel channel or an omitted renderer candidate.

The largest accepted visual component contains238 tiles and starts at source138 (row5,col18). Many upper sky tiles lack accepted visual edges. Rejected weak-texture matches have large ray residuals; weakening the match gate is not justified by this evidence.

The white-gap centre projects outside both neighboring sources147 and148, by approximately158 pixels beyond the right edge and205 beyond the left edge respectively. Their relative yaw/pitch step is approximately(0.05595,-0.00969)rad, compared with nearby accepted horizontal steps near(0.0413,-0.0003)rad. A diagnostic common rotation of the four-source visual component144–147 preserves its internal relative rotations and reduces uncovered centre-ray samples in the fixed6×31 ROI from179 to24. This supports component-level bridge correction, but it is neither a production result nor proof of a completely repaired rendered seam. Pyramid alpha averages4096 level0 samples at level6; centre-ray hit counts and alpha-zero counts are distinct metrics.

## Separate opaque obstruction

Some dark blocks contain source pixels rather than transparency. At level6 approximately(215,228), source0171 (row7,col3) contributes a dark obstruction from original coordinates approximately(3288,1513); source0172 (row7,col4) covers the same ray with normal landscape pixels around(250,1519). Current ownership uses distance from source edges and can prefer the obstructed source. Other examined blocks come from source0176 and0160, where the normal neighboring source no longer covers the block centre under the current geometry. These require separate coverage and ownership checks; brightness alone must not classify normal dark windows or trees as invalid.

Diagnostic artifacts are retained locally under `.local/corner-auto-export-validation-20261005/renderer-audit/` and `.local/seam-texture-validation-20261004/latest-task-audit/`. They include reconstructed color/alpha previews and original-versus-output crops. The whole-image alpha ratio includes exterior borders and cannot by itself establish repair of the user's specific gap.

## Final source and automated verification

Luna geometry, renderer and UI coders implemented disjoint file sets; root independently reviewed geometry, state transitions, real pixels and release identity. The first candidate 674211DD was rejected because refinement did not converge and the gap remained. Its artifacts and the previous release are preserved.

Final core commit is `687e17f17f92bf3cad553d6904b7af95c5d1596c`, DLL SHA256 `ee58bc994e84345f78219b4a37725e1e65dc6b2c30ea7cc01ce6519820fd1a8c`. Alignment cache version14 forces recomputation; pixel bundle algorithm version7 is staged. The unchanged mobile core pin is separate.

- Full Rust suite:154 passed, with both ignored real-data regressions explicitly run and passed separately.
- Full Flutter suite:103 passed; analyzer reports no issues. All20 format functional cases cover exactly-once export, crash recovery, failures, cancellation, history locking and cold batch ownership. Deterministic screenshot fixtures cover visible PNG/TIFF/JXL selection and existing viewer/quality/grid states.
- Four native Windows suites pass against the exact final DLL: batch, TIFF, JXL and automatic single-task PNG/TIFF/JXL. The automatic suite starts each run through the page and never presses manual export; each task calls export once.
- Independent Python checker:14 tests passed; Windows runner contract checks passed.

Logs are retained under `.local/corner-auto-export-validation-20261005/`, including `flutter-analyze-qualified.log`, `flutter-full-qualified.log`, native-v14 suite logs and final native/release logs. Rust evidence is `.local/seam-texture-validation-20261005/core-tests-final-v14.log` in the core repository. These checks do not claim the unavailable `just check`, mobile packaging or physical camera qualification.

## Fresh production geometry and native corner pixels

The v14 raw384-photo registration finished in502.047 seconds using six requested
workers and four-neighbor comparisons. Component refinement actually applied to
131 of132 components, converged in23 GN steps, and fixed the largest visual
component at source138. Maximum true PCG relative residual was9.300e-9 with zero
failed linear solves. Bridge RMS decreased from0.014083 to0.007017 radians.
Accepted within-component texture relationships remain rigid; the unchanged
12px worst-edge gate passes at11.102px. Estimated-position provenance remains
explicit because the sky reference lacks direct visual matches.

Independent comparison uses the baseline camera of source138 to remove any
common-frame ambiguity. Its alignment rotation is numerically identity. The
same6×31 level6 world footprint improves from7/186 to186/186 covered centre
rays; every step8 footprint subsample is covered. This sampled projection
measure is not a full-resolution alpha count.

The native renderer then produced baseline and candidate4096×2048 crops from
original pixels at the identical world bounds. The recorded strip intersection
contains749568 original-resolution pixels: baseline696123 transparent pixels,
candidate zero transparent and zero partially transparent pixels. The first32
rows of the level6 footprint lie above this crop and are explicitly excluded
from that pixel count. Root reviewed the actual cloud/mountain continuation;
the former rectangular gap and gross vertical mountain step are removed.
Artifacts: `.local/corner-auto-export-validation-20261005/native-final-corner/`
contains paired crops, alpha counts, fixed-frame layout, projection checks and
a native sampled full-frame preview. No inpainting or crop-to-hide repair is
used by production placement or rendering.

The independent unchanged299-edge/11243-point spatially separated holdout
cohort gives RMS1.170051px and P952.092266px, preserving the1.0.7 main-scene
alignment. All384 source hashes verify. Its299 successfully measured edges are
distinct from728 attempted adjacent pairs and from raw ratio pairs containing
false matches; the latter are retained separately and are not the quoted RMS.

The full-frame sampled preview still shows some opaque source obstructions.
Read-only Luna renderer review confirms no clean peer for many centre rays,
and low texture in some available sky/haze peers. The0171/0172 real regression
proves selective replacement at a supported overlap, not removal of its entire
block. The renderer retains unsupported pixels rather than inventing content.
Full-canvas original-resolution every-seam review and a new full384 whole-file
export are not claimed by these targeted crops and small native export tests.

Mobile builds and physical camera/device qualification are outside this Windows change and remain pending.

## Released Windows package

Normal `lib/main.dart` Release build passes; EXE file/product version is1.0.8+9. The latest source automatic PNG/TIFF/JXL integration passes (`native-auto-qualified.log`); release output is `release-qualified.log`.

Package: `.local/releases/lumia-stitch-1.0.8-20261005-core687e17f/Lumia-Stitch-1.0.8-Windows-x64.zip` (23507847 bytes,31 files,10 license files). SHA256: `5fbcf7c2874f30b6c358323711ede6601d2686eeede2f7456027e65d7821b533`. ZIP CRC and every archived file hash, x64 PE identity, final DLL/source pin, three official JXL tools and PNG/TIFF/JXL capabilities pass; `package-validation.json` records these checks. Prior1.0.7 archive remains intact.

Operator: extract the complete ZIP, run `lumia_stitch.exe`, select TIFF/PNG/JPEG XL on the main page and start. Newly completed single runs automatically export. For old completed geometry use a new task copy and recompute; exporting the old layout in another format cannot repair placement. Existing originals and outputs are preserved.
