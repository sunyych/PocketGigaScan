# PocketGigaScan roadmap

Historical camera-app tasks are retired from this product. Their prior records remain in Git history and the local recovery archive. Processing IDs remain stable below.

| ID | Goal | Dependencies | Status | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| PG-046 | Corner texture/coverage repair and automatic export | PG-044,PG-045 (historical) | Windows1.0.8 verified; every-seam/mobile physical pending | Luna coders; Codex review | [Evidence](evidence/CORNER-AUTO-EXPORT-2026-10-05.md) |
| PG-047 | Texture and nominal-grid reconstruction tests | PG-046 |156 core tests pass | Luna test coder; Codex review | [Evidence](evidence/TEXTURE-GRID-TESTS-2026-10-05.md) |
| PG-048 | Independent DWARF stitcher, English/Chinese, icon and GitHub Windows downloads | PG-046,PG-047 | in progress | Luna localization/build coders; Codex coordinator | [Scope](../RESTRUCTURE.md), [Build](../BUILD.md) |
| PG-049 | Independent Android stitching distribution | PG-048 | planned; no current Android package qualification | unassigned | portable Flutter/Rust boundary; future Android packaging/device tests required |
