# Texture and grid reconstruction tests (PG-047)

The user requested explicit automated tests for both texture stitching and grid stitching after Windows1.0.8 delivery. This change targets core tests and testing documentation; it does not alter production algorithms, UI or the shipped binary.

Luna owns new core integration fixtures/tests; root owns independent assertion review, complete Rust verification and the evidence ledger. Existing nine-view spherical tests primarily verify poses and current flat grid tests primarily verify output size. New acceptance checks must inspect rendered pixels in horizontal and vertical overlaps, and must reject deliberately displaced geometry. Nominal placement must preserve all input cells while continuing to report estimated placement rather than claiming visual registration.

Synthetic regression checks complement the separately recorded real384 registration and original-resolution corner crops in [PG-046](CORNER-AUTO-EXPORT-2026-10-05.md). They do not replace full-canvas visual or physical device qualification.

## Accepted changes and checks

New core file: `tests/spherical_render.rs`, tests-only commit `bff2a6627d3afdc90a0b62cea4565124920d40a3` on `codex/stitch-performance`. No core production source changed. Windows1.0.8 still uses the recorded687e17f production source pin and its previously verified DLL; no new executable package is necessary.

The textured test generates a3×3 known spherical scene, registers via `spherical::align_json_detailed`, then actually renders with `spherical_renderer::render_layout_tiles`. Full-scene luminance MAE must be below12/255; separate horizontal and vertical seam MAE below15/255. Fixed small seam rectangles require every pixel alpha255. Deliberate0.075rad yaw/pitch changes each must worsen the corresponding pixel metric by more than8/255. Deghost output has a separate MAE gate. Analytic discontinuity filtering excludes expected resampling ambiguity; opacity checks separately prevent transparent pixels from silently passing the seam coverage assertion.

The nominal2×2 test reverses input order, checks four unique path/coordinate associations, zero visually placed tiles/four estimated tiles and null visual residuals, exact horizontal/vertical FOV×0.85 steps and correct row/column directions. Rendered source centers must be opaque; corresponding source color must appear near each center, and all four colors must remain represented. Constant-color fixtures intentionally have no registration texture: this proves nominal grid retention, not texture accuracy.

Root independently reviewed the final assertions and requested stronger alpha, axis, ordering and per-cell color checks before acceptance. Coordinator full verification: `cargo test --offline --release` passes156 tests,0 failures,2 real-data tests ignored by default. The new target passes both tests in2.71s within this full run. The two ignored tests remain separately qualified by PG-046 and were not rerun for this tests-only addition. `cargo fmt --all -- --check` and narrow Git whitespace checks pass.

Full log: core `.local/seam-texture-validation-20261005/core-tests-pg047.log`. The existing Windows runner executes the complete Cargo integration suite and includes this target automatically. OpenCV/MSVC linker emits the existing LNK4098 runtime-library warning; no link or execution failures occurred. `just` remains unavailable; no full repository/mobile/physical gate is claimed.
