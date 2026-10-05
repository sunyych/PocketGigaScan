# PG-048 standalone PocketGigaScan

## Source and migration

The product remains PocketGigaScan, Windows first with independent Android
stitching planned. Retired OpenPocketCine camera/mobile code is removed from
the published tree. The modern Flutter Android runner and portable Rust engine
are retained. LICENSE and historical NOTICE are unchanged.

The user confirmed deletion of the retired directories/caches. The previous
index and retired source recovery archive remain in ignored `.local` storage.
Original photographs, exported panoramas and AppData records were not deleted.
Windows storage resolution preserves both tasks and queues in the legacy base
whenever either legacy directory exists.

## Local reproducible checks

- Rust 1.88.0 `cargo test --release --locked --manifest-path native/core/Cargo.toml`:
  156 passed, zero failed, two real-data tests ignored by default. Production
  release rebuilt with test-only JPEG XL helpers unset.
- `cargo +1.88.0 fmt --manifest-path native/core/Cargo.toml -- --check`: passed.
- Flutter 3.44.2 analysis: no issues; complete application suite: 117 passed.
  Includes English/Chinese system locale and runtime switching, actual English
  main/queue/viewer surfaces, legacy task storage, texture/grid-facing controls,
  export lifecycle, task deletion, gestures and screenshot regressions.
- Six updated screenshots differ only in the product-title rectangle; independent
  pixel comparison found no other changes. Normal tests pass after updating.
- PowerShell builder contracts: passed, including out-of-root/junction rejection,
  nested ZIP positives/negative controls, nested libjxl SDK layout and Rust license
  inventory/fallback/missing-license checks.
- Independent seam checker Python unit suite: 14 passed.
- Publication allowlist check: no build/cache/native binaries, originals or files
  over 5 MB in the staged source tree. Retained PNGs are synthetic core fixtures,
  screenshot baselines and application icons.

The full local builder passed again: 156 debug-profile core tests, 117 Flutter
tests, normal Windows Release, all three capabilities, 45 Rust registry license
packages, and ZIP member hashes. Source commit: `e48f4d81c08fa359ef541f6f243902301a83ba52`.
Local ZIP SHA-256: `7120f63a8570922d79ddc465eab697d89915414f6f399d864bf09b202afb280f`.
An enabled Windows native integration used four real source copies and
automatically exported PNG, TIFF and JPEG XL once each: passed. The normal
`lib/main.dart` Release entry was restored after the integration.

The first clean hosted run built OpenCV successfully, then found that the official
libjxl static SDK needs newer Microsoft STL symbols than VS 2022/MSVC 14.44
provides. Local VS 2026 succeeds. The workflow is being qualified on the explicit
VS 2026 hosted image with a compatible toolchain preflight.

Local command logs are preserved in ignored
`.local/dwarf-restructure-backup-20261005/`. This verification is separate
from the pending clean hosted build and release download.
Historical real 384-photo and original-resolution corner evidence is unchanged;
no new whole-canvas seam or physical Android qualification is implied.
