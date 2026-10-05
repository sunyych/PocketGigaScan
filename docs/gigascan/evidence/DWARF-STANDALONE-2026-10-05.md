# PocketGigaScan DWARF Windows qualification — 2026-10-05

PocketGigaScan 1.1.0 is an independent DWARF stitcher. The confirmed retired
camera-app directories and caches were removed after making the local recovery
archive. The published source contains the Flutter Windows shell, future Android
runner and independent Rust/OpenCV engine snapshot. Historical LICENSE/NOTICE,
original photos, existing exports and compatible task storage are preserved.

## Reproducible validation

- Final local builder: 156 core tests passed, zero failed, two optional real-data
  tests ignored by default. The production DLL is rebuilt with test helpers unset.
- Flutter analysis: no issues. All 121 application tests pass, covering system
  English/Chinese, main/queue/viewer states, texture/grid controls, export lifecycle,
  task removal, gestures and strict screenshot regression comparison.
- Task path regressions cover saving/loading beneath an aliased canonical root,
  escaping links and malformed IDs. The missing-output screenshot uses a fixed
  relative fixture path; only its filename/error-area baseline changed.
- Enabled Windows integration on the final source automatically exported PNG,
  TIFF and JPEG XL using copied real-photo fixtures: passed. Normal application
  Release was restored afterward.
- Builder contracts pass: owned output paths/reparse rejection, complete ZIP
  member/hash checks, nested libjxl layout, Rust license inventory and app-local
  x64 runtime copying with missing-DLL/wrong-architecture negative controls.
- Actual VS18 runtime copying, including architecture/version/hash inventory:
  passed. Final local complete ZIP checksum:
  `ed19312341c81d1dc2e47a4233ee6060e39b29d032fea2c8093037efc9311ec9`.
- Independent Python seam-checker unit suite: 14 passed. Native formatting passed.
- Publication hygiene: no retired source roots, caches, built native binaries or
  original photos are tracked. Retained PNGs are synthetic fixtures, screenshot
  baselines and icons.

Command logs remain in ignored `.local/dwarf-restructure-backup-20261005/`.
See [testing commands](../STITCH-TESTING.md) and [build instructions](../../BUILD.md).

## Clean hosted source build

Source `db715474caead2ebb0b21220f6aef72db1057f70` passed the
[clean hosted Windows build](https://github.com/sunyych/PocketGigaScan/actions/runs/37379310434):
156 native tests, 121 application tests, production Release and packaging checks.
Coordinator downloaded its artifact and independently checked ZIP CRC/SHA-256,
source commit/embedded manifest, three-format capabilities, core and Microsoft
runtime hashes/versions, and all 45 Rust registry license inventories.

- This qualified branch artifact is 20,248,061 bytes.
- Its SHA-256 is `a93df0ed9eec3150abdc595c2df6beb41fed1309a4a0be38ee465143000c230e`.

Only documentation changed after this qualified product/workflow source. Successful
main builds automatically publish the complete ZIP, checksum and source manifest
at the [latest download](https://github.com/sunyych/PocketGigaScan/releases/tag/latest).
Verify a current download using its adjacent checksum; later commit metadata
produces a different ZIP hash from the reference branch artifact above.

Future Android packaging and physical-device testing remain planned separately.
Historical 384-photo corner evidence is retained; this restructuring introduces
no new whole original-resolution panorama seam qualification.
