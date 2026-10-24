# Exact-pixel renderer and bounded recovery speedups

The preserved 364-photo DWARF task provides a performance reference. Keep the
current geometry, source count, dimensions, eight
immediate neighbors, blending policy and export endpoints. The earlier reported pixel-lock issue was resolved. A subsequent fully unlocked
fast-registration task has a separate reprojection failure, tracked below.

The preserved 364-photo task has 538.6 seconds of registration, including 157.7s
low-contrast retries and 200.8s CLAHE retries. Pose optimization is only 16.9s;
the 10.1s leave-one-out timer is nested in it. A controlled full-layout replay
previously took 1020.7s to render, 122.9s for the pyramid and 33.8s for lossless
TIFF. Those runs have different endpoints and are not a new single combined
timing. They identify rendering, registration retries and export as performance
areas to investigate.

## Renderer

The final blend channels are f32 ratios. Precompute the exact f32 bit-domain
boundaries of the existing output sRGB rounding function, use a coarse lookup
plus exact boundary correction, and retain the original f64 reference function.
Do not replace the source-byte sampler's color conversion: it interpolates in
encoded space before linear-light conversion. Threshold, randomized-ratio and
decoded full-output comparisons must show identical bytes.

Deghost currently projects a candidate pixel in both ownership passes and again
in blending. Cache exact f64 source coordinates within a checked per-worker
budget, including unsupported pixels. Recalculate the same feather/ownership
math from those coordinates. Prefer warped sources and retain baseline fallback
when the bounded cache cannot cover a candidate. Added scratch reservations must
not reduce the original worker count; subtract them from remaining cache capacity
and preserve the shared reservation contract. Aggregate instrumentation at tile
or phase boundaries, never with an atomic increment per pixel.

## Recovery feature extraction

Keep every failed eight-neighbor edge, extraction parameters, source identities,
match order and acceptance thresholds. Test bounded parallel recovery extraction
under the existing exclusive OpenCV batch guard, with one native thread per image
to avoid nested parallelism. The serial option retains the original path.
Preserve last-use endpoint caching and cancellation/guard cleanup. Compare real
serial and batched outputs before adoption; revert a regressing candidate.

Add extraction-versus-matching timings and actual unique extraction counts.
The historical CLAHE feature counter adds both endpoints for every edge attempt,
so its 3.18-million value is not the number of uniquely extracted features.

## Qualification

First use the same preserved full-grid 4621-by-2936 ROI for short controlled runs.
Then repeat the complete 364-photo 80855-by-25050 layout, four workers, 512MiB,
full viewer pyramid and lossless TIFF with no concurrent SDK builds. Compare
decoded tile coordinates, dimensions and RGBA bytes; PNG file hashes are not a
pixel comparison. Keep previous outputs and record OS-cache/timing limitations.
Run native format/tests, Flutter analysis/tests, build contracts and the normal
Windows source builder. Android source/APK qualification is separate from device
execution. Incoming bilingual harness edits need an independent actual-patch
review before a combined commit; their presence is not assumed.

## Research

OpenCV documents faster fixed-point remapping, but conversion changes floating
coordinates and its remap interpolation does not support INTER_LINEAR_EXACT.
This is an optional future backend experiment, not evidence for pixel-equivalent
replacement of this sampler: [OpenCV geometric transformations](https://docs.opencv.org/4.13.0/da/d54/group__imgproc__transform.html).
PNG compression and filtering affect CPU time and encoded size rather than
pixel quality: [libpng compression and filtering](https://www.libpng.org/pub/png/book/chapter09.html).
The previous render's aggregate PNG encoding CPU time was about thirty seconds,
so compression is a lower-priority target than projection and fusion here.

## Unlocked fast-registration failure

The current 364-photo task has no hard locks and uses 0.6 MP registration. Its
final RMS is 2.26 px, but edge 74–75 reaches 124.29 px against the unchanged
12 px edge gate. That sky/blurred-foreground pair has ten inliers, narrow support,
and high cycle inconsistency. These summaries cannot alone prove the edge false.
A previously successful all-unlocked 2.0 MP replay has byte-identical 364 sources
and identical scalar geometry/settings. Repeat the exact current task at 2.0 MP
in an isolated output directory; original failed task and exports remain intact.

If qualified, a coarse grid-assisted quality failure may trigger one explicit
2.0 MP recovery. Other failures and cancellation must not retry. Preserve all
photos, locks, immediate neighbors and quality gates. Record requested/actual
precision, attempts, failure trigger and combined elapsed time. A second failure
stays failed with diagnostics. Version alignment cache identity to prevent old
coarse layouts bypassing the new behavior. Localize its single timeline event.
Targeted rematching remains future work requiring separate evidence.

## 2026-10-24 exact renderer reuse work

The independent Rust core now reuses each source's `SourceQualityMap` between the global ownership prepass and tile rendering, caches the exact classification score for reuse during blending, and stores per-tile owner validity in a bitset. These changes target repeated quality-map construction and repeated pixel qualification work while preserving the existing deghost formula, source geometry, and renderer identity. They do not change registration or its quality gates.

The combined per-worker geometry/score cache reserves 24 bytes per candidate pixel: two f64 source coordinates (x/y) plus one f64 score. Under the existing 32 MiB per-worker cap, that budget can hold five source geometry/score slots for a 512×512 output tile (about 30 MiB); a sixth slot would exceed the cap. One worker processes one output tile at a time, and the worker cap remains unchanged. Sources without an admitted cache slot retain the original computation; unavailable score entries use the original calculation. A checked allocation failure returns an error rather than silently falling back. Owner-validity bits are tile-local and do not alter ownership values.

Pixel qualification compares decoded RGBA bytes at matching level-zero tile coordinates and dimensions. Benchmark the same layout, worker count, memory budget, and output endpoint with the standard benchmark harness, then compare decoded RGBA output rather than compressed-file hashes. This renderer replay evaluates render cost and pixel parity only; it does not fix or validate registration quality.

The focused native test log reports 32 passed and 2 ignored; the benchmark-script suite reports 6 passed, and the builder/mock-signing contracts passed. Full native and Flutter suites and package validation are still pending.

### Full-layout renderer replay

The completed reference/candidate pair used the same 312-source layout (SHA-256 `1614121131cc161d9571faa03ee58d1eb0750e255aa12d1d9c3acfa3cf2a5b76`), 81,024×22,140 output, four effective workers, 26,734 MiB budget, viewer pyramid, and lossless TIFF endpoint. All 6,996 level-zero tiles had identical decoded RGBA8 pixels, coordinates, and dimensions; both receipts report pixel SHA-256 `bccc7b55b08dbfe0fd44611dd137aa0172a68e3b868ba978d5fbcba8fca80597`.

| Receipt phase | Reference | Candidate | Change |
|---|---:|---:|---:|
| Render | 888.117 s | 684.400 s | −22.94% |
| Pyramid | 99.763 s | 105.064 s | +5.31% |
| Lossless TIFF | 27.525 s | 28.056 s | +1.93% |
| Total endpoint | 1,015.432 s | 817.565 s | −19.49% |

The host wrapper measured wall time 1,064.594 s then 873.093 s, process CPU 3,072.375 s then 2,508.250 s, and peak sampled RSS 10,529,230,848 B then 10,554,507,264 B. RSS samples were taken every 250 ms. Both runs decoded 312 source images. Geometry-cache slots per tile decreased from 7 to 5, while cached source-tile count changed from 28,105 to 27,128. The candidate receipt counted 2,574,142,074 adjusted-ownership score reuses and 1,684,807,200 owner-validity geometry projections reused.

The per-worker `ownershipPassMs`, `classificationPassMs`, and `blendPassMs` are cumulative across concurrent tile workers, not wall time and not additive phases. Reference→candidate values were 903,457.813→890,012.385 ms, 382,156.726→422,297.440 ms, and 1,256,219.886→543,806.294 ms respectively. This was one ordered pair with no other builds running concurrently; OS file cache was not cleared. These measurements establish this replay's result, not a universal speedup or a registration-quality fix. Full native/Flutter suites and package validation remain pending.
