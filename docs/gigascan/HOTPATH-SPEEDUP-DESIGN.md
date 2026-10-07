# Exact-pixel renderer and bounded recovery speedups

The user reports roughly thirty minutes for the full DWARF panorama and asks for
speed improvements. Keep the current geometry, source count, dimensions, eight
immediate neighbors, blending policy and export endpoints. The earlier reported pixel-lock issue was resolved. A subsequent fully unlocked
fast-registration task has a separate reprojection failure, tracked below.

The preserved 364-photo task has 538.6 seconds of registration, including 157.7s
low-contrast retries and 200.8s CLAHE retries. Pose optimization is only 16.9s;
the 10.1s leave-one-out timer is nested in it. A controlled full-layout replay
previously took 1020.7s to render, 122.9s for the pyramid and 33.8s for lossless
TIFF. Those runs have different endpoints and are not a new single combined
timing. They explain where to investigate the user's roughly thirty minutes.

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
