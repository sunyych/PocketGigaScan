# Windows person protection and water smoothing

**Goal:** Add independent, opt-in Windows person protection and water smoothing to final panorama renders.

**Approved design:** Local automatic recognition; completeness over speed; smooth water over sharp individual waves; Windows only in this iteration. On 2026-10-15 the user changed delivery to a bundled model: no developer/user authentication or network setup required. Prepare a verified local working copy on first use, with cancellation/retry/removal/restoration from the installed bundle. English and Chinese UI. Defaults are off. Original photos, old tasks and outputs stay intact.

## Implementation and ownership

- [x] Luna native coder: reproducible UPerNet ConvNeXt Tiny ONNX export, pinned CPU ONNX Runtime, Windows dependency packaging, source-coordinate confidence masks, separate validated mask cache, cancellable job phase and semantic request identity. Owns scene_analysis, native bridge, job, build plumbing and export script.
- [x] Luna renderer coder: immutable, sparse global person groups and stable source ranking; source-mask windows with budget accounting; person-union protection copies selected source background too; water-only linear-light feather override. Owns scene_render, spherical_renderer and seam_ownership.
- [x] Luna Flutter coder: both flags through settings/tasks/queues/retry/requests/reports, Windows EN/ZH controls, verified bundled-model preparation/cache/delete/retry flow, execution gating and focused regressions. Owns Flutter source and tests.
- [ ] Codex coordinator: agree interfaces, independently review all three changes, run model export/inference and final tests/build, record evidence and residual limitations. Preserve unrelated dirty shared-tree work; no broad reset or cleanup.

## Interface contract

Requests add `protectPeople` and `smoothWater` (missing means false), plus execution-only `sceneModelPath`, `sceneModelSha256` and `sceneCacheDir` for enabled runs. Persisted tasks never carry machine-specific model paths. Disabled requests preserve existing execution and resume semantics.

The job overlays options after geometry-cache loading and adds `semanticAnalysis` to the saved render layout. Its schema is `{schemaVersion:1, algorithmVersion:1, modelId, modelSha256, sources:[{path,width,height,maskPath,maskSha256}]}`. Masks are original-resolution LumaA8 PNG: L=person confidence, A=water confidence; A is data, not transparency. Renderer samples at the same corrected source coordinates as RGB.

The model is `openmmlab/upernet-convnext-tiny` revision `876ffc56b819a829448f7e81e9f8606deef6fb65`. Native input is fixed 512-square normalized RGB; export includes confidence/class semantics for person 12 and water 21/26/60/109. Use overlapping native-scale crops, bounded scratch and checkpoints. Both options reuse one analysis. Model and mask content hashes, preprocessing and semantic-render versions identify cached results. Runtime: ONNX Runtime 1.31.0 official Windows x64 ZIP, SHA256 `3958d8a44984160692c1b4ffd0de3cb48f8c39f9d34bb31e433db06e30b82195`.

The Windows builder exports the pinned model (or validates an exported override) and stages `scene-model-v1.onnx` under the installed `data/models`. Generate exact size/hash from actual export before enabling use. Weights stay ignored and outside Git. Missing bundled model, invalid cache or inference errors fail explicitly; low-confidence/unrecognized areas retain ordinary blending. Person protection wins over water smoothing. No geometry/registration-policy changes.

## Acceptance

- [x] Bundled preparation cancellation/retry/hash rejection, verified offline reuse/deletion; old records/defaults; queue/copy/retry propagation; both locales and locked controls.
- [ ] Four option combinations with feather/deghost/local warp; both-off byte parity; people at input/crop/tile edges, adjacent people, crowd coverage fallback; water boundaries and people-over-water; source-order/worker/resume determinism.
- [ ] Source-native formatting/tests, Flutter analysis/tests, both existing builder contracts and normal Windows Release source build with runtime/licenses.
- [ ] Real-image inference and same-coordinate final tiles/export crops; record bounded evidence separately from complete-panorama user acceptance.

## Execution boundary

Starts on existing `codex/deghost-continuity` shared checkout with unrelated uncommitted Flutter/task/registration work. Record this boundary rather than claiming the feature owns those edits. No Android feature/build acceptance or signed public app release is included. The revised bundled delivery needs no model upload or GitHub authentication.
