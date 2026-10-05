# PocketGigaScan

An independent DWARF panorama stitcher, shipping on Windows first with Android stitching planned. Flutter shell in `Apps/Flutter/stitch_app`, vendored independent Rust/OpenCV engine in `native/core`. No OpenPocketCine/DJI camera source belongs in the current product. Future Android stitching reuses the portable Flutter/Rust layers; the retained Flutter Android runner is separate from retired Apps/Android.

## Development

- Use a coordinator and Luna coder subagents. Assign disjoint files, review independently, and record handoffs in `docs/gigascan/COLLABORATION.md`.
- Track owned work and evidence in `docs/gigascan/ROADMAP.md`; do not claim visual or hardware acceptance from synthetic tests.
- Keep neighbor-only comparisons, all input photos, estimated-grid provenance, separate preview/final export and resumable job ownership intact.
- Default language is English; Chinese system locales resolve to Chinese. Localize all operator-visible text and test both locales.
- Preserve old task storage compatibility. Original photographs and exported results are never deleted by task removal or repository cleanup.
- Run core tests/formatting, Flutter analysis/tests, build script contracts and a normal Windows Release build for relevant changes. Native functional checks and visual crops are separate evidence.
- Work on `codex/` branches with conventional commits. GitHub Windows pipeline builds all pushes and publishes latest download from the default branch only.
- Do not commit credentials, camera secrets, originals, personal captures, caches, `.local`, build output or temporary files. Keep LICENSE and historical NOTICE; include dependency licenses in release ZIPs.

## Build

See `README.md`, `docs/BUILD.md` and `docs/gigascan/STITCH-TESTING.md`. Use `scripts/build-dwarf-stitch-windows.ps1`; clean CI must build the vendored engine from source with verified native dependencies. Never substitute a machine-local DLL for a CI build.
