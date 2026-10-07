# DWARF performance, placement and traceability qualification

Status: implementation and isolated measurements complete; final package
qualification is recorded below. No performance multiplier is claimed.

## Controlled comparison

Replay the preserved 364-photo, 14-by-26 layout at 80855 by 25050 pixels with
four workers. Keep the original layout bytes, source photos, blend model,
512-pixel viewer tiles, full pyramid and uncompressed lossless RGBA8 TIFF endpoint
identical. The baseline is source commit `332c13f`; only a narrow TIFF-export
benchmark wrapper and the same benchmark example are added to the ignored source
archive. Renderer implementation and 512MiB baseline limits remain unchanged.

Compare old and new renderers at 512MiB first, then change only the new renderer's
memory budget to 16GiB. Preserve all run outputs. Decode every level-zero tile
and hash its coordinates, dimensions and raw RGBA bytes for exact pixel equality;
compressed PNG file hashes are not a pixel comparison. Record pipeline phase
times separately from subsequent fingerprint verification, and sample process
RSS/CPU with `scripts/benchmark-dwarf-render.py`. Do not run SDK builds during
the measured runs. A single run per configuration is observational evidence;
filesystem caching and other host activity are not eliminated.

The machine reports 134040772KiB total physical memory, about 127.8GiB, and
67657500KiB available at the initial reading, about 64.5GiB. CPU is an Intel
i7-11700 with eight physical cores and sixteen logical CPUs. Available memory
changes during use; recommendations and manual limits use a fresh reading.

Baseline run `baseline-364-20261006T203042-002248ba` completed all 7742
level-zero tiles, the complete pyramid and lossless TIFF. Its source-built
benchmark executable SHA-256 is
`fc52a48a091c1e11f9e8d11bd162a98ca85d86b12c2bb2f13cc5929845603793`.
The immutable layout SHA-256 is
`89fa99502ec6640d21df7cbe7a97d8205ce33e80a9df4aa7a52fdbdfad05c855`.

| Baseline phase or resource | Observation |
| --- | ---: |
| Render | 1068.649 s |
| Pyramid | 114.754 s |
| Lossless TIFF | 32.666 s |
| Pipeline total, before verification | 1216.111 s |
| Subsequent exact-pixel verification | 62.676 s |
| Source decodes / cache hits | 3762 / 28550 |
| Sampled peak process RSS | 465649664 bytes |
| Process CPU time | 3869.84375 s |

The decoded level-zero RGBA fingerprint is
`36eca815e70235efdda220f2557dad23c1a775290d4e991e9c452c38a0d97815`.
Normal process exit raced the last process sample; the sampler retained its
last cumulative CPU reading and records this race instead of inventing a final
sample. Host wall time includes the separate pixel verification.

The frozen candidate at the same 512MiB reservation completed in run
`candidate-512-364-20261006T211826-cd9e3f61`:

| Phase or resource | Old 512MiB | New 512MiB |
| --- | ---: | ---: |
| Render (s) | 1068.649 | 1020.702 |
| Pyramid (s) | 114.754 | 122.850 |
| Lossless TIFF (s) | 32.666 | 33.768 |
| Pipeline total before verification (s) | 1216.111 | 1177.385 |
| Subsequent pixel verification (s) | 62.676 | 64.975 |
| Source decodes | 3762 | 2076 |
| Sampled peak process RSS (bytes) | 465649664 | 389201920 |
| Process CPU time (s) | 3869.84375 | 3792.625 |

All 7742 decoded level-zero tiles have the identical fingerprint above. Render
time decreased by about 4.5%; complete pipeline time decreased by about 3.2%.
This measurement does not support a threefold speed claim. Source decoding is
reduced substantially, but per-pixel projection/fusion remains dominant.

The same frozen executable, SHA-256
`ce3f46eeb94e75dd9786ad56fd6f3967a6ec049a5e80899c3adc92164356c6c1`,
then completes run `candidate-16g-364-20261006T215750-42c78d23` with only the
reservation changed to 16384MiB. All 7742 tile fingerprints remain identical.

| Phase or resource | New 512MiB | Same executable, 16GiB |
| --- | ---: | ---: |
| Render (s) | 1020.702 | 1059.871 |
| Pyramid (s) | 122.850 | 125.414 |
| Lossless TIFF (s) | 33.768 | 57.689 |
| Pipeline total before verification (s) | 1177.385 | 1243.028 |
| Subsequent pixel verification (s) | 64.975 | 67.904 |
| Source decodes | 2076 | 364 |
| Sampled peak process RSS (bytes) | 389201920 | 12144242688 |
| Process CPU time (s) | 3792.625 | 3841.703125 |

Larger memory eliminates repeated source decodes but does not improve the total
pipeline in this run: it is about 5.6% slower than the new 512MiB run and 2.2%
slower than the old baseline. One run cannot establish a general memory/speed
relationship. The isolated child measurements include normal host load and
filesystem-cache variation. Do not recommend 16GiB solely for a speed multiplier.
The three preserved exports complete at 80855x25050 as uncompressed RGBA8
BigTIFF, each 8101804932 bytes; benchmark output is separate from preview and
quality-registration evidence.

Independent bounded TIFF parsing validates all 8350 strip ranges, the
8101671000-byte raw pixel payload and offsets beyond 4GiB in the 16GiB export.
First, middle and last occupied tile-center samples exactly match the lossless
viewer pyramid. Validation does not load the entire panorama into memory.

## Independent review

New registrations compare each immediate cardinal and diagonal neighbor once.
Central cardinal samples still estimate horizontal and vertical grid overlap.
Shared alignment-cache version 18 invalidates entries from version 17. Existing
saved layouts resume with their saved geometry to preserve output/checkpoint
ownership; a new stitch uses the fixed-eight contract. Legacy option spellings
remain readable, and new UI requests use eight neighbors.

Source decoding runs outside the resident-cache lock. Per-source flights share
success/failure; separate decode-slot and active-worker estimates include
worker-held images evicted from the resident LRU. The app-wide setting controls
aggregate managed reservations and cache capacity, with on-demand allocation.
It is not an OS-enforced RSS ceiling: decoder/library/allocator overhead is
measured independently. Lowering settings cannot revoke an active reservation.
Desktop concurrency stays at its existing configured count; Android retains
its measured, conservative resource policy.

Byte-level LUT conversion is deferred because the existing shader-compatible
sampler converts to linear light after floating-point encoded-space bilinear
interpolation. A direct byte LUT would change that order. Registration retries
already reuse feature frames and deduplicate bounded retry endpoints; narrower
ROIs require calibrated captured-data evidence before they can safely replace
full-frame matching. Quality limits and estimated-placement provenance remain.

## Placement-lock investigation

The supplied `09_13.jpg` hashes identically to input 0247 of the preserved
364-photo task. That task and its registration request explicitly contain
`forceGrid: true` for row 9, column 13. The saved layout reports grid-estimated
placement without direct visual evidence. Existing storage does not establish
who enabled the marker; it must remain a legacy lock of unknown origin.

Fresh, separate nine-photo registrations retain rows 8–10 and columns 12–14.
The locked version completes with eight visual tiles and one hard-locked center;
the unlocked diagnostic copy completes with all nine tiles visually registered.
Their global RMS values are respectively 1.56882570 and 1.63451780 pixels.
This is evidence that aggregate RMS alone cannot qualify the previously excluded
center. Both complete nine-photo TIFF/pyramid renders are preserved locally.
These local registrations do not qualify the full 364-photo panorama.

The UI/API distinguish a grid prior from an explicit hard grid lock. Old true
markers retain `legacyUnknown` provenance; new user locks record `operator`.
Only hard locks suppress incident visual constraints. The global optimizer,
bounded texture correction and 12-pixel quality limit remain intact.

A fresh full 364-photo registration with the center unlocked in a diagnostic
copy completed in 538.750 seconds. Its global RMS was 1.60483648 pixels and
worst accepted edge RMS was 11.93873170 pixels, within the unchanged 12-pixel
limit. All eight incident center edges were accepted, with RMS values from
1.4156 to 2.2944 pixels. The weak sky reference remains disconnected from the
visual graph: all 364 placements still require grid bridging. The center now
has direct visual evidence but is not visually connected to that reference.
This distinction is retained in storage and presentation.

The independent checker's spatially held-out cardinal correspondences measure
the center's four edges as follows. The split belongs to the checker: it does
not prove that the production optimizer never used these source features.
Support counts differ by edge; these measurements are diagnostic evidence,
complemented by synthetic tests with independently generated ground truth.

| Center edge | Held-out pairs | Before RMS (px) | After RMS (px) |
| --- | ---: | ---: | ---: |
| Top | 48 | 18.3013 | 1.3345 |
| Left | 9 | 19.2484 | 1.1874 |
| Right | 28 | 21.3116 | 1.0946 |
| Bottom | 43 | 21.1089 | 1.5062 |

Across 334 measured edges and 10696 held-out pairs, the median changed from
0.9956 to 0.9875 pixels and P95 from 2.5181 to 2.3892 pixels. Aggregate RMS
remains about 164 pixels because repetitive-texture held-out pairs can have
large ambiguous displacements; it is not substituted for the native gate.

A 4621-by-2936 diagnostic ROI retains the full optimized 364-camera layout and
uses the same world-angle bounds as the original center region. Four edge
midpoints and four corners have paired lossless, unscaled 512-pixel crops,
with layout and source hashes. Independent visual inspection shows markedly
better alignment of the right-side building window frames. This qualifies that
local comparison, not a completed new full-panorama export or all other seams.
Personal photographs, crops and diagnostic records remain ignored locally.

## Host checks and packages

Product source is commit `a66a9d9f5b19ffe549935290a894c7512c61b192`.
Subsequent additions strengthen tests, CI and evidence without changing product
code. Native formatting passes. The normal Windows builder executes 202 native
tests with two external-data tests explicitly ignored. The additional
`misaligned_grid_render` target executes two tests, for 204 executed native
tests in total. The new target is also discovered by unfiltered Cargo tests.
Flutter analysis is clean and all 270 host tests pass. The targeted 63-test run
is a subset, not an additional test count. All 32 Python tests and both Windows
and Android builder-contract scripts pass. No Python tests are skipped.

The Windows Release is built normally from the vendored engine source, with
verified dependencies. Every ZIP member matches the packaged source SHA-256;
the executable reports version `1.3.2+16`. The packaged native DLL SHA-256 is
`c048a1f907fef31bcdccdb3845ef3733d9ec55247a03262cd67cb725ca3481a6`.
The Android engine is independently source-built for ARM64/API29. Final APK
inspection verifies package `com.lumiaiq.pocketgigascan`, version `1.3.2`/16,
minimum API29, target API36, ARM64 exports/dependencies, 16KiB LOAD and ZIP
alignment, its development-key signature, and all 135 dependency license files.

| Deliverable | Bytes | SHA-256 |
| --- | ---: | --- |
| Windows x64 ZIP, 1.3.2+16 | 20744423 | `83310ce0ed1cbceb48cebfbdc17086e7250456c4f3f7adcb4b50f471237d5e75` |
| Android ARM64 APK, 1.3.2+16 | 39241711 | `207e2f6f0e362ac471a93b43d497c475df57a654adefee5b6e82d1330cf85083` |

Packages and detailed execution receipts remain under ignored `.local` paths.
ADB reports no connected device. Host tests and APK inspection do not establish
Android execution, SAF/background recovery under device pressure, camera
capture, or every real panorama seam. Fixture-dependent Windows FFI integration
tests were not executed; their disabled configuration now reports explicit skips
instead of a successful empty test body. Enabled tests still fail for missing
fixtures. Windows CI installs pinned Python dependencies and runs the checker
and benchmark tests, alongside the existing full native/Flutter source build.

## Supplemental test audit

| Area | Coverage and boundary |
| --- | --- |
| Input misalignment to final pixels | New analytic RGB 2x2/3x3/4x4 captures introduce real camera yaw/pitch/roll errors, including a contiguous three-capture patch. Real registration and feather/deghost, warp-off/on rendering preserve all input identities and exact local eight-neighbor pairs. Unwarped source-boundary reprojection has fixed p95 <=2px / worst <=4px gates in synthetic source pixels; an 8px negative control fails the same gate. RGB truth and bounded coverage checks accompany geometry. These wide-FOV synthetic fixtures are not a real-DWARF seam qualification. |
| Narrow FOV and incompatible geometry | Existing narrow-FOV positive registration remains; the new physically disjoint narrow-FOV case must fail registration. A single spherical model is not required to repair unsupported parallax. |
| Real 09_13 | Separate locked/unlocked 3x3 registrations and full-364-layout ROI/crops are recorded above. Original locks are preserved; explicit unlocking in a new task is needed to measure incident neighbors. A new full-panorama export and all-seam review are not claimed. |
| Seam checker acceptance | Immediate diagonals are optional and unique. Explicit finite aggregate/per-edge error limits, positive support and every available required-cell incident edge are checked. Unknown/empty evidence fails. A small bad edge cannot hide behind a good global mean when per-edge gates are requested. Worst and all measured target-incident crops accompany representative samples. Source/layout/checker-version changes invalidate caches. Checker-owned holdout is not a proof of unseen production training points. |
| Retry, resource and pixel determinism | Existing bounded retry/cancellation, single-flight decode, parallel/serial rendering, pyramid, pending-limit and concurrent-admission tests remain. Controlled full-resolution 512MiB/16GiB receipts and exact tile/TIFF checks are separate from CI timing assertions. Cold/warm repetitions are not claimed. |
| Task records and viewer | Existing migration, atomic/tombstone deletion, actual native snapshot shape, hash/identity binding, output-coordinate projection, mouse/touch and EN/ZH tests pass. No end-to-end physical-device trace inspection is claimed. |
| Export/color semantics | TIFF/PNG lossless tests and independent official `djxl` lossy-RGB/exact-alpha checks remain. Stale JXL lossless capability assertions are fixed. Exposure/color correction is absent and recorded as null/notApplied; no correction parameters are fabricated. |

See [STITCH-TESTING](../STITCH-TESTING.md) for executed host checks versus the
explicit external-original, FFI and connected-device acceptance gates.
