# PocketGigaScan roadmap

Historical camera-app tasks are retired from this product. Their prior records remain in Git history and the local recovery archive. Processing IDs remain stable below.

| ID | Goal | Dependencies | Status | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| PG-046 | Corner texture/coverage repair and automatic export | PG-044,PG-045 (historical) | Windows1.0.8 verified; every-seam/mobile physical pending | Luna coders; Codex review | [Evidence](evidence/CORNER-AUTO-EXPORT-2026-10-05.md) |
| PG-047 | Texture and nominal-grid reconstruction tests | PG-046 |156 core tests pass | Luna test coder; Codex review | [Evidence](evidence/TEXTURE-GRID-TESTS-2026-10-05.md) |
| PG-048 | Independent DWARF stitcher, English/Chinese, icon and GitHub Windows downloads | PG-046,PG-047 | Windows build qualified; main release pipeline enabled | Luna localization/build coders; Codex coordinator | [Scope](../RESTRUCTURE.md), [Build](../BUILD.md), [Hosted build/package evidence](evidence/DWARF-STANDALONE-2026-10-05.md) |
| PG-049 | Android desktop parity, unrestricted grids, huge viewer and connected-device qualification | PG-048 | implementation, host tests and ARM64 APK qualified; physical qualification pending | Luna native/platform/UI coders; Codex coordinator | [Design](ANDROID-STITCH-DESIGN.md), [Plan](ANDROID-STITCH-PLAN.md), [Evidence](evidence/ANDROID-STITCH-2026-10-05.md); future iOS adapters retain portable boundary |
| PG-050 | Lossy JPEG XL, completed-task presentation, localized states/logs and LumiaIQ application identity | PG-049 | Windows Release and Android ARM64 package verified; Android physical qualification pending | Luna native/UI/localization-platform coders; Codex coordinator | [Evidence and scoped plan](evidence/EXPORT-UI-IDENTITY-2026-10-06.md) |
| PG-051 | Blurred-photo overlap selection and unreliable neighbor constraints | PG-050 | implementation and Windows Release verified; supplied-photo acceptance pending originals | Luna registration/render/UI coders; Codex coordinator | [Plan](BLUR-REPAIR-PLAN.md), [Evidence](evidence/BLUR-REPAIR-2026-10-06.md) |
