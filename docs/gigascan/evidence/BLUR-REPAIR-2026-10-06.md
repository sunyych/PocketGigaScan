# PG-051: blurred-photo repair

User-approved scope is recorded in [the plan](../BLUR-REPAIR-PLAN.md).
Branch: `codex/blur-aware-stitch`. Application version: `1.2.2+13`.

## Implementation

Neighbor refinement now measures 4x4 correspondence coverage on both sources
and checks elementary 2x2 grid loops. A conflict above 12 source-pixel-equivalent
rotation error reduces only a distinctly weaker edge. Nearly tied edges retain
their weights and expose ambiguity. The relative final constraint confidence
is also applied to pixel normal equations, line-search cost and leave-one-out
refinement, and persisted/restored in diagnostic snapshots. The original
component solver, bounded local warp, grid-estimated provenance and all-source
ownership remain intact. This extends the existing joint optimizer rather than
adding a separate frozen-backbone solver.

Deghost rendering compares local high-frequency sharpness at projected overlap
positions, normalized by broader scene contrast and separate from existing
dark-obstruction detection. A source yields only when stronger structured peer
evidence exists. Source quality fields are interpolated globally; renderer
memory reservations include the extra field and per-pixel peer scores. This
uses the existing continuous ownership blend, not a new graph-cut seam engine.
It does not reconstruct detail absent from every original.

Alignment cache version is 15 and pixel snapshot version is 8. Render identity
markers prevent mixing old and new deghost tiles in paused tasks. Historical
completed exports remain readable/exportable; incompatible partial deghost
tasks request a task copy and restitch without deleting their files. Legacy
feather caches can resume. English/Chinese quality controls explain the behavior
and diagnostics summarize accepted edges with reduced confidence or ambiguity.

## Reproduce and use

In the task's Output and quality panel, enable neighboring-photo refinement
and deghost blending. For a completed task, create a copy to obtain editable
pre-render settings, then restitch. Old originals and exports are retained.
Disable deghost blending for a feather comparison. Final rendering continues
to use all inputs at the selected full export resolution.

Use `scripts/build-dwarf-stitch-windows.ps1` with the pinned dependency SDKs.
It runs native checks, Flutter analysis/tests, normal `lib/main.dart` Windows
Release and complete ZIP/license/integrity checks. Also run Windows builder
contracts and independent seam-checker tests as described in STITCH-TESTING.

## Qualification status

Flutter static analysis is clean and 177 tests pass, including both locales.
Windows builder contracts and 14 independent seam-checker tests pass.
All 137 native unit tests pass (two historical real-data tests ignored), and
the three rendered-sphere integration tests pass. On the same 37,720-pixel
synthetic textured overlap, legacy deghost MAE is 23.26/255 and the new method
is 19.21/255 (about 17 percent lower). Coverage, reversed source order and
both sides of a 512-pixel tile boundary are separately checked. Sigma 1.0
blur is tested for monotonic sharpness, not guaranteed suppression; sigma
1.5 mixed-scale detail crosses the conservative 0.70 peer-relative cutoff.
The single-scale checker test explicitly permits insufficient evidence.
Final pinned-toolchain Windows package qualification is in progress.

The attached image is an already stitched panorama. Its corresponding original
photos and task report have not been supplied. Synthetic registration/render
tests cannot establish repair of that photograph set or physical Android
qualification. Flat/repetitive or noisy scenes may lack reliable sharpness or
matching evidence; ambiguous loops remain disclosed for visual review.
