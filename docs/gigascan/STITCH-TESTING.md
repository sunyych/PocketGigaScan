# PocketGigaScan stitching verification

Run SDK commands serially. The published distribution is Windows x64; the
Android implementation has its own packaging and connected-device evidence.
Windows tests do not qualify an Android package or a physical camera.

| Behavior | Reproducible coverage |
| --- | --- |
| Original import, EXIF and grid dimensions | Flutter importer/grid/request tests; Rust metadata/planner tests |
| Neighbor matching and horizontal/vertical overlap | Rust registration/grid-overlap tests; independent seam checker |
| Texture registration and forced-grid rendering | `native/core/tests/spherical_render.rs`: rendered seam error, displacement negative controls, weak-neighbor conflict rejection, and retained source tiles |
| Misaligned-grid registration and rendering | `native/core/tests/misaligned_grid_render.rs`: analytic independent RGB truth; sampled camera-boundary reprojection p95 ≤ 2 px and worst ≤ 4 px; rendered MAE < 22 overall and < 30 in boundary ROIs; injected pose-error negative controls |
| Bounded parallel rendering and pyramids | Rust renderer/pyramid/resource tests, including bounded quality-extension and cancellation; Flutter queue admission tests |
| PNG, TIFF/BigTIFF and JPEG XL | Rust streamed export tests; verified `djxl` decode checks lossy RGB error and exact alpha; Flutter export/controller regressions |
| Automatic export, retry, cancellation and last-good result | Flutter controller/lifecycle tests; opt-in Windows native integrations |
| Persisted task deletion without deleting photos | Repository tombstone/serial-write tests; native task deletion verification |
| Viewer wheel/drag, visible tiles and collapsed status | Viewer widget/gesture/file-binding tests and current screenshot baselines |
| English/Chinese system locale and storage compatibility | Localization and legacy-support-directory tests |
| Completed presentation, pre-render formats and collapsed logs | Windows/Android policy widget tests in both locales, copy/retry regressions and reviewed screenshots |
| Lossy JPEG XL color and exact alpha | Independent `djxl` decoding, alpha-weighted color error, textured lossy-pixel negative control |
| Application ID and native channels | Platform channel tests, runner identity contracts and actual APK badging |
| Build ownership, dependency pins and archive integrity | PowerShell builder contracts, actual nested ZIP positive/negative fixtures |
| Android large-grid confirmation and unrestricted import | Approval scope/controller/widget tests; >1024 import and >128-axis native tests |
| Android scoped files, background guard and resource budgets | Dart bridge/policy tests, Kotlin policies and connected-device integration |

Android native checks use `scripts/build-stitch-android-core.ps1 -BuildTests`.
The opt-in `integration_test/android_parity_test.dart` accepts
`TEST_ANDROID_PARITY_SOURCE_DIR`, an app-readable real DWARF 2×2 JPEG fixture
directory. It runs actual FFI processing/three-format exports and viewer checks.
The device fixture must be staged in app-private storage or imported through
SAF; a public Downloads path alone does not grant scoped-storage access.
The `test_driver/android_parity_test.dart` integration driver saves captured
screenshots to `INTEGRATION_SCREENSHOT_DIR` for coordinator review. From the
Flutter package, run it with `flutter drive --driver=test_driver/android_parity_test.dart
--target=integration_test/android_parity_test.dart -d DEVICE_SERIAL
--dart-define=TEST_ANDROID_PARITY_SOURCE_DIR=APP_PRIVATE_FIXTURE_DIRECTORY`.
Host policy mocks and synthetic giant-canvas tests are distinct from actual
Android exports, physical background behavior and multi-gigabyte file evidence.

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
python -m pip install numpy==2.2.6 opencv-python-headless==4.11.0.86 psutil==7.0.0
python -m unittest discover -s scripts/tests -p 'test_*.py'
```

The complete Windows builder runs the full Cargo test suite (which auto-discovers
the synthetic native integration-test targets), Flutter analysis/tests and the
normal application release build, probes all three output capabilities, then
checks every packaged ZIP member against its source SHA-256. CI also discovers
all `scripts/tests/test_*.py` tests, including seam and benchmark-runner checks.
It installs Python 3.12 plus pinned NumPy, headless OpenCV, and psutil first;
the seam checker imports OpenCV directly, so a missing dependency fails instead
of skipping its checks.
See [build instructions](../BUILD.md). Goldens are updated only after reviewing
an intended UI change, followed by a normal test run.

`integration_test/` fixture-dependent native tests are explicitly skipped unless
their matching `TEST_*_NATIVE` define is enabled. Once enabled, a missing or
invalid fixture fails the test. `native_smoke_test.dart` always checks the ABI;
it only adds real-source processing when `TEST_SOURCE_DIR` is supplied. The
Android parity test always requires its real 2×2 fixture. These opt-in/device
tests are not part of the Windows hosted workflow. The Windows builder requires
the pinned independent `djxl` executable and runs the Rust JPEG XL quality
test, which checks textured lossy RGB error and exact alpha. Filesystem widget
tests use `tester.runAsync`; an indefinitely animating spinner is not acceptance.
The standard hosted workflow does not run the fixture-dependent Windows FFI
integration tests, Android connected-device tests, physical DWARF capture, or
full-resolution visual seam review; those remain separate acceptance evidence.

The default core suite has two ignored real-data tests: preserved 384-photo
bridge-topology replay (`LUMIA_GRID_COMPONENT_LAYOUT_FIXTURE`) and real-source
obstruction ROI replay (`LUMIA_RENDERER_TASK_DIR`). Neither runs without its
external preserved task data. Historical registration and original-resolution
corner crop evidence remains linked from [the roadmap](ROADMAP.md); it does not
establish every seam in a full original-resolution export. Android FFI/device,
physical camera capture, and real-photo full-resolution visual acceptance remain
separate gates. The synthetic analytic-RGB and reprojection thresholds are
regression gates, not a substitute for reviewing real-photo seams and crops.
New standalone build evidence is recorded separately.
