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

Independent spatially held-out cardinal correspondences measure the center's
four edges as follows. These correspondences are separate from the optimizer's
training pairs; support counts differ by edge.

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

## Validation pending

- Native formatting/tests and high-memory renderer/export/admission tests.
- Flutter analysis, settings/policy/integration tests, EN/ZH and idle progress.
- Build script contracts; normal Windows Release and source-built Android APK.
- Exact real-layout pixel comparison, completed TIFF and resource/timing receipts.
- New fixed-eight real registration and visual seam review, reported separately.
