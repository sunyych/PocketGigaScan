# PocketGigaScan DWARF Windows qualification — 2026-10-05

This record documents the Windows 1.1.0 source build qualified on 2026-10-05.
The then-current package contained the Flutter Windows shell and independent
Rust/OpenCV engine. The results below describe that historical source and test
set; current platform support and qualification are tracked in the current
build documentation and evidence records.

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
- Package hygiene: generated outputs, caches and original photos are excluded.
  Tracked PNGs are fixtures, screenshot baselines and application assets.

Command logs remain in ignored `.local/dwarf-restructure-backup-20261005/`.
See [testing commands](../STITCH-TESTING.md) and [build instructions](../../BUILD.md).

## Clean hosted source build

Source `db715474caead2ebb0b21220f6aef72db1057f70` passed the
Historical hosted Windows build 37379310434:
156 native tests, 121 application tests, production Release and packaging checks.
The artifact was independently checked for ZIP CRC/SHA-256,
source commit/embedded manifest, three-format capabilities, core and Microsoft
runtime hashes/versions, and all 45 Rust registry license inventories.

- This qualified branch artifact is 20,248,061 bytes.
- Its SHA-256 is `a93df0ed9eec3150abdc595c2df6beb41fed1309a4a0be38ee465143000c230e`.

The first main publication attempt exposed a queue-test cleanup race: temporary
storage could be removed before asynchronous queue writes ended. A repair adds
explicit scheduler/persistence draining and guards disposal
during pre-start awaits while preserving already-started native jobs. Gated-save
and gated-load tests exercise those boundaries; teardown no longer relies on a
fixed sleep. This repair requires its own application and hosted-build reruns.

The repeat check passed 15 queue-controller tests on three
consecutive runs, including both new gated lifecycle regressions. Logs:
`queue-drain-pass-3.log`, `queue-drain-pass-4.log`, `queue-drain-pass-5.log`
in the ignored qualification directory above.

The repaired application passes analysis without issues and all 123 application
tests, including strict screenshots. The normal Windows Release build also
passes; hosted publication must pass its full native/build/package gate.
Logs: `queue-drain-analyze.log`, `queue-drain-full-tests.log`,
`queue-drain-main-release.log`.

Successful main builds automatically publish the complete ZIP, checksum and source manifest
at the [latest download](https://github.com/sunyych/PocketGigaScan/releases/tag/latest).
Verify a current download using its adjacent checksum; later commit metadata
produces a different ZIP hash from the reference branch artifact above.

Future Android packaging and physical-device testing remain planned separately.
Historical 384-photo corner evidence is retained; this restructuring introduces
no new whole original-resolution panorama seam qualification.
