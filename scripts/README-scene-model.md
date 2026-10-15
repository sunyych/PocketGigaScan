# Scene segmentation model

The Windows optional people-protection and water-smoothing controls use a locally cached ONNX export of OpenMMLab's MIT-licensed `upernet-convnext-tiny`. The export identity, input contract, selected ADE20K classes, preprocessing, and Python package pins live in [`scene-model-export.lock.json`](scene-model-export.lock.json). The exporter downloads only the pinned revision and writes the model plus a SHA-256 manifest. Original weights and exported ONNX stay out of Git; the Windows package builder includes the generated ONNX so the installed application works offline.

Run the exporter with the project's pinned Python environment:

```powershell
python scripts/export-scene-model.py --output-dir .local/scene-model-v1
```

The ONNX input is RGB float32 `[1,3,512,512]`, normalized by ImageNet mean/std. The two output channels are person class 12 and the maximum class probability across water classes 21, 26, 60, and 109. Keep float32; do not quantize this model. The exporter verifies the pinned size and SHA-256 from the lock and writes a manifest beside the ONNX file. The fixed-shape adaptive pooling replacement checks its output against the original PyTorch graph before export.

The Windows build downloads the pinned official ONNX Runtime 1.31.0 SDK into its dependency cache, compiles against those headers, dynamically loads the absolute packaged `onnxruntime.dll` beside the native core, and includes both runtime DLLs and upstream notices in the ZIP. The runtime DLLs are in the SDK's `lib/` directory. The builder stages the ONNX model under `native/core/target/release/scene-model-v1.onnx`; Flutter installs it under `data/models/scene-model-v1.onnx`, and the app copies that bundled file to its local model cache. Android and other non-Windows builds do not link or package ONNX Runtime; requesting either scene option there returns an explicit unsupported-platform error.
