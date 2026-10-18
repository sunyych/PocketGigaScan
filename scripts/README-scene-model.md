# Scene segmentation model

Windows and macOS offer optional people protection and water smoothing using the same fixed UPerNet ConvNeXt Tiny ONNX model. Phones do not initialize, link or package semantic inference. Both desktop packages include the model and ONNX Runtime for offline use; installed applications need no account, network, Python or model download.

## Fixed build input

[`scene-model-export.lock.json`](scene-model-export.lock.json) pins the source revision, graph/preprocessing contract, exact ONNX size/SHA-256 and a separate public model dependency ZIP. Product builders download this ZIP anonymously, check its archive size/hash before extraction, then check the ONNX and manifest again. Weights and exported graphs stay outside Git. The model dependency release does not replace the application's latest download.

The ZIP contains the canonical graph, SHA manifest, exact source model card and attribution notice. The pinned upstream model card declares MIT; that snapshot has no separate LICENSE file. The package preserves this distinction and does not invent a copyright holder or year. An upstream LICENSE is copied separately if provided by a future explicitly reviewed model revision.

## Reference conversion and qualification

```powershell
python -m pip install -r scripts/scene-model-export.requirements.txt
python scripts/export-scene-model.py --output-dir .local/scene-model-v1
```

The strict exporter downloads only the pinned revision and checks its fixed-shape adaptive pooling replacement against the original PyTorch graph. The validated reference environment is Windows x64, Python 3.10.13, the six pinned package versions, and the local Torch 2.5.1 CPU build. Repeated reference exports, including AVX2 and AVX512 dispatch experiments, produce the canonical ONNX hash.

Do not assume a different CPU/backend produces byte-identical folded weights. Hosted export tests found 24 fused Conv/BatchNorm initializers with floating-point tail differences while all graph nodes and other initializers matched. The exporter rejects those files and writes diagnosis instead of accepting a new model silently. Product builds therefore consume the frozen, already validated artifact rather than re-exporting on each host. Any model replacement requires a new reviewed asset and qualification; do not disable the hash check.

The ONNX input is RGB float32 `[1,3,512,512]`, normalized by ImageNet mean/std. The output channels are person class 12 and the maximum class probability across water classes 21, 26, 60 and 109. Keep float32; do not quantize this model.

Windows loads the absolute packaged `onnxruntime.dll` beside the native core. The official runtime DLLs reside in the SDK's `lib/` directory. Windows installs the graph under `data/models`; macOS places it under `Contents/Resources/models`, with the core and `libonnxruntime.dylib` together in `Contents/Frameworks`. The app verifies and copies the bundled graph to its own deletable usage cache on first use. Android/iOS hide these controls and send both scene flags as false, including old stored desktop task settings.
