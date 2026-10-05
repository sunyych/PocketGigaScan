# PocketGigaScan stitching verification

Run SDK commands serially. The current distribution target is Windows x64;
the modern Flutter Android runner is retained for future stitching work.
Windows tests do not qualify an Android package or a physical camera.

| Behavior | Reproducible coverage |
| --- | --- |
| Original import, EXIF and grid dimensions | Flutter importer/grid/request tests; Rust metadata/planner tests |
| Neighbor matching and horizontal/vertical overlap | Rust registration/grid-overlap tests; independent seam checker |
| Texture registration and forced-grid rendering | `native/core/tests/spherical_render.rs`: rendered seam error and displacement negative controls; source retention |
| Bounded parallel rendering and pyramids | Rust renderer/pyramid/resource tests; Flutter queue admission tests |
| PNG, TIFF/BigTIFF and JPEG XL | Rust streamed export tests, official independent `djxl` decode; Flutter export/controller regressions |
| Automatic export, retry, cancellation and last-good result | Flutter controller/lifecycle tests; opt-in Windows native integrations |
| Persisted task deletion without deleting photos | Repository tombstone/serial-write tests; native task deletion verification |
| Viewer wheel/drag, visible tiles and collapsed status | Viewer widget/gesture/file-binding tests and current screenshot baselines |
| English/Chinese system locale and storage compatibility | Localization and legacy-support-directory tests |
| Build ownership, dependency pins and archive integrity | PowerShell builder contracts, actual nested ZIP positive/negative fixtures |

From `Apps/Flutter/stitch_app`:

```powershell
flutter pub get --enforce-lockfile
flutter analyze
flutter test --reporter expanded
```

From the repository root, with the Visual Studio developer environment and
verified OpenCV/libjxl SDKs configured:

```powershell
$env:LUMIA_JXL_TEST_HELPERS='1'
$env:LUMIA_DJXL_PATH='C:/path/to/verified/djxl.exe'
cargo +1.88.0 test --release --locked --manifest-path native/core/Cargo.toml
Remove-Item Env:LUMIA_JXL_TEST_HELPERS
cargo +1.88.0 build --release --locked --manifest-path native/core/Cargo.toml
pwsh -File scripts/test-build-dwarf-stitch-windows.Tests.ps1
python -m unittest discover -s scripts/tests -p test_verify_spherical_seam_alignment.py
```

The complete Windows builder runs core tests, Flutter analysis/tests and the
normal application release build, probes all three output capabilities, then
checks every packaged ZIP member against its source SHA-256. See [build
instructions](../BUILD.md). Goldens are updated only after reviewing an intended
UI change, followed by a normal test run.

`integration_test/` native tests are opt-in: enable their `TEST_*_NATIVE` define
and provide the fixture directory. Disabled native tests are not executed
evidence. Filesystem widget tests use `tester.runAsync`; an indefinitely animating
spinner is not acceptance.

The default core suite has two ignored real-data tests. Historical real 384-photo
registration and original-resolution corner crop evidence remains linked from
[the roadmap](ROADMAP.md); it does not establish every seam in a full original
resolution export. New standalone build evidence is recorded separately.
