# Renderer hot-path recovery evidence

Status: controlled renderer comparison, native/Flutter host checks, normal
Windows Release, packaged-engine automatic recovery and Android package
qualification completed. Physical-device and all-seam visual acceptance remain
separate gates.

## Controlled 364-photo render

The baseline and candidate replay the same persisted 364-photo layout, SHA-256
`89fa99502ec6640d21df7cbe7a97d8205ce33e80a9df4aa7a52fdbdfad05c855`, at
80855×25050 pixels. Both request four workers and a 512 MiB memory budget, use
512-pixel level-zero tiles, render the complete pyramid, and export the same
uncompressed lossless RGBA8 BigTIFF endpoint. The comparator decoded every
level-zero PNG and compared tile coordinates, dimensions, and RGBA8 pixels.
All 7742 tiles match exactly; their shared raw-pixel fingerprint is
`36eca815e70235efdda220f2557dad23c1a775290d4e991e9c452c38a0d97815`.

| Pipeline phase | Prior candidate | Hot-path candidate | Change |
| --- | ---: | ---: | ---: |
| Level-zero render | 1020.702 s | 789.614 s | −22.6% |
| Pyramid | 122.850 s | 110.604 s | −10.0% |
| Lossless BigTIFF | 33.768 s | 27.567 s | −18.4% |
| Pipeline total | 1177.385 s | 927.819 s | −21.2% |

The pipeline total is render + pyramid + export. Independent decoded-pixel
verification ran afterward and took 64.975 s for the prior candidate and
53.117 s for the hot-path candidate; verification is not included in the phase
total.

Both processes exited successfully. The host sampler measured wall time of
1242.547 s and 981.250 s, process CPU time of 3792.625 s and 2894.625 s, and
sampled peak RSS of 389201920 bytes and 422146048 bytes, respectively. RSS is a
250 ms process sample, not an OS memory guarantee. The host was a 16-logical-CPU
Intel Windows 10 machine; host load and available memory varied between runs.
This is one controlled pair, not a repeated-run distribution or a claim of a
fixed speedup on other hardware.

The candidate reserved seven source-geometry slots per tile and about 29.36
MiB per worker for the bounded geometry cache (117442176 bytes across four
workers). The renderer's conservative active estimate was 520615840 bytes. This
reservation reduced the resident source-cache limit from 233241792 to
115787872 bytes and sampled cache residency from 232243200 to 99532800 bytes.
Source decode count consequently increased from 2076 to 11603. The complete
render still finished faster with exact level-zero pixels. These figures show
the tradeoff on this workload; they do not establish that larger cache limits
or geometry caching always improve speed.

Run receipts and host samples are retained under
`.local/dwarf-hotpath-20261007/runs/candidate-full-controlled-20261007T085134-7879bd11/`
and the prior 512 MiB candidate under
`.local/dwarf-performance-20261006/runs/candidate-512-364-20261006T211826-cd9e3f61/`.
The comparison receipt is
`.local/dwarf-hotpath-20261007/full-controlled-comparison.json`.

## Separate ROI replay

A 60-tile, 4621×2936 ROI replay at the same four workers and 512 MiB budget
also produced exactly matching decoded level-zero pixels, fingerprint
`44181d613f3b3ac83dcaabb18f111a685461adfc75a39e0f287d5d3f33eaf4c3`. Its
render+pyramid+TIFF phases changed from 13.807 s to 10.642 s. This smaller
replay is diagnostic timing evidence only; it is not the complete 364-photo
render. Its receipt is
`.local/dwarf-hotpath-20261007/roi-comparison.json`.

## Separate geometry replay and qualification limits

The 364-source precise-geometry failure replay completed in 470.813 s versus
the earlier 538.750 s observation. Its layout report records corrected-source
plane symmetric reprojection RMS of 1.604836 px and maximum edge reprojection
RMS of 11.938732 px. All 364 tiles have `positionSource: gridEstimated`, and
the report's `qualityStatus` is `needs-visual-review`. Correspondence measurements
exist, but final positions remain estimated-grid placements. The comparison
reports equal rendering geometry, but unequal tile records because the new
request adds explicit soft-grid-prior provenance. This replay does not qualify
full-panorama seams or convert estimated placement into direct visual evidence.
Do not infer seam quality from aggregate correspondence metrics.

The geometry comparison is retained at
`.local/dwarf-hotpath-20261007/precise-geometry-comparison.json`; the replay
summary is at `.local/dwarf-hotpath-20261007/failure-replay-precise/summary.json`.
Complete seam and real-image visual acceptance remain separate gates.

## Packaged-engine automatic recovery

An isolated read-only replay uses all 364 original sources from the failed task,
the same unlocked placement constraints and scalar settings, requested 0.6 MP,
and the new packaged Windows DLL. Alignment caching is disabled. The first
attempt reproduces the reported failure exactly: global RMS 2.260790797 px,
worst edge 74–75 at 124.287975626 px, with complete correspondence evidence.
It takes 211982 ms and triggers the structured reprojection-quality recovery.

Exactly one 2.0 MP attempt completes in 369028 ms. Final RMS is 1.604836483 px
and maximum edge RMS 11.938731699 px against the unchanged 12 px gate. All 364
sources remain, none are hard locked or forced-grid tiles, and every rendering
layout field is exactly equal to the separate successful 2.0 MP replay.
`precisionRecovery.status` is `recovered`, requested precision is 0.6 MP and
actual precision is 2.0 MP. Total native alignment time including both attempts
is 581024 ms (host wall 581.094 s).

These timings have different OS/source-cache states from the earlier standalone
2.0 MP replay and are not a new controlled speed comparison. Starting directly
at 2.0 MP avoids the failed coarse pass for this dataset. The recovery does not
raise gates or establish all-seam visual acceptance; estimated-grid provenance
and `needs-visual-review` remain explicit. Request, complete response and
geometry/attempt assertions are retained under the ignored
`.local/dwarf-hotpath-20261007/failure-replay-automatic/` and
`automatic-recovery-comparison.json` paths; the original failed task is untouched.

## Source and Windows qualification

The reviewed product source is `f2c7c8271c29361388634f285a3343a822861023`.
Root reviewed the disjoint Luna patches, fixed the checked geometry-budget
boundary through its owning coder, and independently reviewed recovery gates,
request preservation, cancellation, cache identity and verified task adoption.
Recovery is eligible only for enabled grid-assisted 0.6 MP registration that
fails the structured reprojection-quality gate. One 2.0 MP attempt retains every
source, placement constraint, immediate neighbor and existing quality threshold.
A second failure remains failed. Requested/actual precision and both attempts
are recorded; EN/ZH share the explicit recovery timeline event.

The normal Windows source builder passed 212 native tests; two external-original
fixtures remain intentionally ignored. Flutter analysis reports no issues and
all 271 host tests pass. Both build-script contracts and all 32 Python checks
pass. Fixture-dependent FFI and physical-device cases are separate qualification.

The Windows executable reports `1.3.3+17`. The ZIP builder verifies every archive
member against its packaged source, including LICENSE, historical NOTICE,
dependency licenses, VC runtime inventory and native capabilities. The package
manifest records the product source above and DLL SHA-256
`dee93f266a208b3798fecc531632d02d70e9cb242d64c42edb431b9395bb0bb4`.
The Windows x64 ZIP is 20775817 bytes, SHA-256
`7acb557f257639b9ac9631fc53abf1cb250c1a5c67ee8a4a70edaf749bb1a4ee`.

Local build logs, packages and private source evidence stay ignored. The incoming
DeepSeek bilingual patch has not appeared in this shared checkout and is not
claimed as reviewed or included.

## Android and hosted checks

The Android core is built from the same reviewed source for ARM64/API29, with
the ARM native test executable compiled but not run on a device. The Release APK
reports package `com.lumiaiq.pocketgigascan`, version `1.3.3`/17, minimum API29
and target API36. Independent inspection verifies all native exports/dependencies,
ARM64 ELF LOAD alignment and APK ZIP alignment at 16KiB, its development-key
signature, and all 135 dependency license files against their manifest hashes.
The APK is 39301855 bytes, SHA-256
`62100c9ab0d86a72e32f50d54a3a467e6c70b88f7f2f06dd733942e6a9b4d875`.

Seven Kotlin `testDebugUnitTest` cases pass; Release lint has zero errors and
nine existing warnings. The local helper initially requested a nonexistent
`testReleaseUnitTest`; discovery confirmed the debug unit-test task, which was
run successfully with `lintRelease`. This helper error does not change product
source or invalidate the separately completed Release APK build. ADB again
reports no connected device; native ARM execution, SAF/background behavior and
phone rendering remain unqualified.

Both clean-source Windows push/PR jobs pass for product commit `f2c7c82`:
[push build](https://github.com/sunyych/PocketGigaScan/actions/runs/37651621254)
and [PR build](https://github.com/sunyych/PocketGigaScan/actions/runs/37651633547).
The final evidence-only commit has separate automatic CI; no later product code
is substituted for the qualified source. Packages are retained under ignored
`.local/deliverables/` paths. No merge or default-branch release publication is
performed by this handoff.
