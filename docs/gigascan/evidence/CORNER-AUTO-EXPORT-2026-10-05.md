# Corner coverage and automatic export — Windows 1.0.8+9

## Historical geometry diagnosis

A 384-photo, 16×24 layout showed transparent coverage gaps and opaque source obstructions despite passing the global neighbor-residual gate. The earlier full-layout result reported 430 accepted of 728 cardinal edges, six visual components, 42.710 px ray RMS, 86.073 px P95 and 363.937 px worst-edge RMS. Grid-assisted placement continued with warnings; the result was not considered qualified.

A diagnostic common rotation of a four-source component reduced uncovered centre-ray samples in a fixed 6×31 region from 179 to 24 while preserving internal relative rotations. This was a diagnostic only. A later full registration applied component refinement to 131 of 132 components, converged in 23 Gauss-Newton steps, and reduced bridge RMS from 0.014083 to 0.007017 radians. The unchanged 12 px worst-edge gate passed at 11.102 px. Estimated-placement provenance remains explicit because the sky region lacks direct visual matches.

An identical-world-bounds 4096×2048 renderer crop had 696,123 transparent baseline pixels and zero transparent or partially transparent candidate pixels across the measured 749,568-pixel strip intersection. This cropped renderer result does not establish complete-canvas quality. Other dark regions contain source pixels rather than transparency and require separate coverage and ownership checks; brightness alone is not a valid obstruction test.

## Automated checks and limits

At the recorded source revision, the Rust suite passed 154 tests, including two separately run real-data regressions; Flutter analysis was clean and 103 tests passed. Windows native suites covered batch, TIFF, JPEG XL and automatic PNG/TIFF/JPEG XL export. The independent Python checker and Windows builder contracts passed. These checks do not establish all-seam visual quality, mobile packaging or physical camera qualification.
