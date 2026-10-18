# PG-045 — texture registration and collapsed viewer details

## Historical registration evidence

The full 16×24, 384-image layout exposed geometry failures that were not visible in the earlier 9-source and reduced-resolution checks. Its prior output reported 430 accepted of 728 cardinal edges, six visual components, 42.710 px ray RMS, 86.073 px P95 and 363.937 px worst-edge RMS. Grid-assisted placement continued with warnings, so this output was not considered visually qualified.

Rotation-only refinement reduced matched-ray RMS from 42.710 px to 4.982 px but left a 67.180 px worst-edge RMS, above the unchanged 12 px gate. A local robust joint rotation reference on six architectural images reduced held-out error from 29.757 px RMS / 65.717 px P95 to 1.554 px RMS / 2.617 px P95. This was a local reference only. A later full-layout probe still failed with 3.334 px global RMS, 5.494 px P95 and 50.639 px worst-edge RMS after 120 block-coordinate sweeps. These results show that easier subsets do not qualify the complete layout.

The renderer retains the existing quality gates. Follow-up work explored bounded source-plane displacement after joint rotation alignment, more stable texture support, and coarse-to-fine fallback behavior. The fallback correction has a regression test; no weakened quality gate or full-panorama acceptance is claimed by these historical experiments.

## Viewer and validation boundary

The viewer defaults its details panel to collapsed and resets that state when the selected task changes. Flutter analysis and the then-current 81 application tests passed with screenshot baselines.

Static architecture and same-coordinate seam crops remain necessary to assess geometry. Synthetic tests establish code behavior but do not establish all-seam visual quality or physical-device behavior. Existing saved checkpoints and exports were preserved during the recorded validation.
