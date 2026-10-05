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

Local command logs are preserved in ignored
`.local/dwarf-restructure-backup-20261005/`. This source verification is separate
from the pending clean hosted build, release download and Windows native checks.
Historical real 384-photo and original-resolution corner evidence is unchanged;
no new whole-canvas seam or physical Android qualification is implied.
