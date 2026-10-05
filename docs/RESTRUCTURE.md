# Standalone PocketGigaScan restructuring

User-authorized on 2026-10-05: remove OpenPocketCine/mobile camera applications, keep the Windows DWARF grid stitcher, vendor the independent native engine, use English with system-driven Chinese translation, add an original icon and GitHub push builds/downloads. The product name remains PocketGigaScan; a future independent Android stitcher shares the portable Flutter/Rust layers.

The prior staged index and retired source files are preserved locally in `.local/dwarf-restructure-backup-20261005/` (not published). The user explicitly confirmed removal of Apps/Android, ios, Sources, Tests, handbook, site, tools and temporary caches. Git history is retained. Original photographs, AppData task records and exported panoramas are outside repository cleanup.

The native engine snapshot includes texture/grid regression commit bff2a6627d3afdc90a0b62cea4565124920d40a3. Source-based cloud builds are independent of the previous sibling repository. Historical legal notices remain; retired fonts, LUTs and Pocket/DJI protocol sources are not in the new distribution. Remaining retired local references are excluded from the published tree by explicit ignore rules; new retained documentation/script paths should update those rules.

Ownership: Luna localization coder owns Dart/i18n/tests; Luna build coder owns Windows runner/icon/build scripts/workflow; coordinator owns source vendoring, scope cleanup, documentation, serial verification and publishing. No camera control or physical capture qualification is introduced.
