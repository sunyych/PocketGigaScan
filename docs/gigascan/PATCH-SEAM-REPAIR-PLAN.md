# PG-063: continuous seam ownership repair

The user confirmed that polygonal patches exist in both exported JXL and TIFF,
and approved implementing the previously discussed seam repair on 2026-10-07.

## Goal and approved design

Extend the existing portable deghost renderer with spatially continuous source
selection and a bounded soft transition. Preserve all input photos, unique
coverage, neighboring-only registration, original task storage and exports,
estimated-grid provenance, preview/final separation and resumable ownership.
Keep source sharpness and obstruction evidence conservative. Do not solve motion
or geometric disagreement by averaging it into a wider blurred band.

Use one immutable coarse panorama-coordinate ownership map shared by workers.
Derive its lattice resolution from a strict memory allowance; count construction
scratch, source decoding and retained map memory. Spatial regularization must
use valid source coverage and deterministic source identity ties. Tile-local
labeling and arbitrary connected-component propagation are insufficient to
guarantee identical boundaries at 512-pixel tiles. Favor coherent sources in
content-disagreement areas, clean weak isolated labels and soften only safe
boundaries. Retain old deghost/feather output as comparison evidence, and change
renderer identity so incompatible cached render tiles cannot be mixed.

## Owners and validation steps

- [ ] Luna native coder: renderer integration, bounded ownership module and
  native regressions. First capture failing isolated-wedge/moving-content
  examples; compare old deghost, feather and the new algorithm on the same
  sources and saved geometry. Cover static detail, unique coverage, obstructed
  sources, input order, cancellation, memory limits and tile-boundary equality.
- [ ] Luna platform auditor: identify the user's persistent red software prompt
  and inspect the last working version once its exact text/platform is known.
  Preserve independently dirty Flutter files; do not guess or suppress genuine
  diagnostic failures. Coordinator has requested the missing prompt text.
- [ ] Coordinator: independently review map construction costs and numerical
  behavior, locate existing originals/layouts and run bounded real-scene ROI
  comparisons if matching captures are accessible. Run native formatting/tests,
  Flutter analysis/tests, build script contracts and normal Windows Release;
  rebuild Android native core and APK for shared renderer changes.
- [ ] Coordinator: record before/after crop evidence, retained artifact paths,
  checksums, qualification limits and handoffs in collaboration/roadmap records.
  Update the existing MR with scoped commits and observe Android/Windows CI.

## Acceptance boundaries

Synthetic suppression of patch islands is not proof that the attached train/car
panorama is repaired. Report separately whether original photos, saved geometry,
real-scene crops, complete exports and Android execution were actually checked.
Do not delete old results or reuse cached tiles from another renderer identity.
The red prompt remains an independent item until identified and corrected or
explained using the actual message and version evidence.
