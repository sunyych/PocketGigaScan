#!/usr/bin/env python3
"""Export the pinned OpenMMLab UPerNet model to the app's fixed CPU ONNX contract."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import importlib.metadata
import copy
import os
import platform

import torch
import torch.nn.functional as F
from huggingface_hub import snapshot_download
from transformers import UperNetForSemanticSegmentation


ROOT = Path(__file__).resolve().parent
LOCK = json.loads((ROOT / "scene-model-export.lock.json").read_text(encoding="utf-8"))
PINNED_PACKAGES = {"torch": "2.5.1", "transformers": "4.55.4", "onnx": "1.22.0", "huggingface-hub": "0.34.4", "safetensors": "0.4.5", "numpy": "2.2.6"}


class SelectedProbabilities(torch.nn.Module):
    def __init__(self, model: UperNetForSemanticSegmentation) -> None:
        super().__init__()
        self.model = model

    def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
        logits = self.model(pixel_values=pixel_values).logits
        logits = F.interpolate(logits, size=(512, 512), mode="bilinear", align_corners=False)
        probabilities = logits.softmax(dim=1)
        person = probabilities[:, 12:13]
        water = probabilities[:, [21, 26, 60, 109]].amax(dim=1, keepdim=True)
        return torch.cat((person, water), dim=1)


class StaticAdaptiveAveragePool2d(torch.nn.Module):
    """Fixed-shape equivalent of PyTorch adaptive average pooling."""
    def __init__(self, output_size: int | tuple[int, int]) -> None:
        super().__init__()
        self.output_size = (output_size, output_size) if isinstance(output_size, int) else tuple(output_size)

    def forward(self, tensor: torch.Tensor) -> torch.Tensor:
        height, width = int(tensor.shape[-2]), int(tensor.shape[-1])
        out_h, out_w = self.output_size
        rows = []
        for oy in range(out_h):
            y0, y1 = math.floor(oy * height / out_h), math.ceil((oy + 1) * height / out_h)
            columns = []
            for ox in range(out_w):
                x0, x1 = math.floor(ox * width / out_w), math.ceil((ox + 1) * width / out_w)
                columns.append(tensor[..., y0:y1, x0:x1].mean(dim=(-2, -1), keepdim=True))
            rows.append(torch.cat(columns, dim=-1))
        return torch.cat(rows, dim=-2)


def replace_adaptive_pooling(model: torch.nn.Module) -> int:
    replaced = 0
    for parent in model.modules():
        for name, child in list(parent.named_children()):
            if isinstance(child, torch.nn.AdaptiveAvgPool2d):
                replacement = StaticAdaptiveAveragePool2d(child.output_size)
                setattr(parent, name, replacement)
                # Hugging Face UperNetPyramidPoolingBlock keeps its modules in
                # a normal Python list and separately registers them with
                # add_module(). Its forward iterates that list, so setattr()
                # alone leaves the old AdaptiveAvgPool2d in the active graph.
                for attribute, value in vars(parent).items():
                    if isinstance(value, list):
                        for index, item in enumerate(value):
                            if item is child:
                                value[index] = replacement
                replaced += 1
    return replaced


def assert_no_adaptive_pooling(model: torch.nn.Module) -> None:
    for module in model.modules():
        if isinstance(module, torch.nn.AdaptiveAvgPool2d):
            raise RuntimeError("AdaptiveAvgPool2d remains registered after the static replacement")
    for parent in model.modules():
        for attribute, value in vars(parent).items():
            if isinstance(value, list) and any(isinstance(item, torch.nn.AdaptiveAvgPool2d) for item in value):
                raise RuntimeError(f"AdaptiveAvgPool2d remains in active Python module list {type(parent).__name__}.{attribute}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--cache-dir", type=Path, help="Hugging Face cache location")
    parser.add_argument("--skip-dependency-check", action="store_true", help="Allow a preinstalled toolchain with different versions")
    args = parser.parse_args()
    if not args.skip_dependency_check:
        for package, expected in PINNED_PACKAGES.items():
            try:
                actual = importlib.metadata.version(package)
            except importlib.metadata.PackageNotFoundError as error:
                raise RuntimeError(f"Missing pinned export dependency {package}=={expected}") from error
            if actual != expected:
                raise RuntimeError(f"Export dependency mismatch: expected {package}=={expected}, found {actual}")
    print(json.dumps({
        "exportHost": platform.platform(),
        "machine": platform.machine(),
        "torchVersion": torch.__version__,
        "torchCpuCapability": torch.backends.cpu.get_cpu_capability(),
        "atenCpuCapabilityOverride": os.environ.get("ATEN_CPU_CAPABILITY"),
        "torchIntraopThreads": torch.get_num_threads(),
        "torchInterOpThreads": torch.get_num_interop_threads(),
    }, sort_keys=True))
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    snapshot = snapshot_download(
        repo_id=LOCK["modelId"], revision=LOCK["revision"],
        allow_patterns=["config.json", "model.safetensors", "preprocessor_config.json", "README.md", "LICENSE"],
        cache_dir=str(args.cache_dir.resolve()) if args.cache_dir else None,
    )
    model = UperNetForSemanticSegmentation.from_pretrained(snapshot, use_safetensors=True).cpu().eval()
    source_readme = Path(snapshot) / "README.md"
    if not source_readme.is_file():
        raise RuntimeError("The pinned model snapshot is missing its upstream README model card")
    front_matter = source_readme.read_text(encoding="utf-8").split("---", 2)
    if len(front_matter) < 3:
        raise RuntimeError("The pinned upstream model README has no YAML metadata block")
    readme_license = next((
        line.split(":", 1)[1].strip().lower()
        for line in front_matter[1].splitlines()
        if line.strip().lower().startswith("license:")
    ), None)
    if readme_license != LOCK["license"].lower():
        raise RuntimeError(
            f"Pinned model card declares license {readme_license!r}, expected {LOCK['license']!r}"
        )
    if model.config.num_labels != 150:
        raise RuntimeError(f"Expected 150 ADE20K labels, got {model.config.num_labels}")
    example = torch.linspace(-2, 2, 3 * 512 * 512, dtype=torch.float32).reshape(1, 3, 512, 512)
    reference = copy.deepcopy(model).eval()
    replaced = replace_adaptive_pooling(model)
    if replaced == 0:
        raise RuntimeError("Expected UPerNet adaptive pooling modules were not found")
    assert_no_adaptive_pooling(model)
    with torch.inference_mode():
        expected = reference(pixel_values=example).logits
        actual = model(pixel_values=example).logits
    torch.testing.assert_close(actual, expected, rtol=1e-5, atol=1e-6, msg="static adaptive pooling changed UPerNet outputs")
    model = model.eval()
    onnx_path = output_dir / "scene-model-v1.onnx"
    torch.onnx.export(
        SelectedProbabilities(model), example, str(onnx_path),
        input_names=["pixel_values"], output_names=["scene_probabilities"],
        opset_version=LOCK["opset"], do_constant_folding=True,
        dynamo=False, external_data=False,
    )
    manifest = {
        "schemaVersion": 1, "modelId": f"{LOCK['modelId']}@{LOCK['revision']}",
        "license": LOCK["license"], "onnxFile": onnx_path.name,
        "sourceReadmeFile": "scene-model-README.md",
        "licenseNoticeFile": "scene-model-NOTICE.txt",
        "sizeBytes": onnx_path.stat().st_size, "sha256": sha256(onnx_path),
        "input": LOCK["input"], "output": LOCK["output"],
        "preprocessing": LOCK["preprocessing"], "opset": LOCK["opset"],
        "adaptivePoolsReplaced": replaced,
    }
    (output_dir / "scene-model-v1.manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    source_license = Path(snapshot) / "LICENSE"
    if source_license.is_file():
        (output_dir / "scene-model-LICENSE.txt").write_bytes(source_license.read_bytes())
    (output_dir / "scene-model-README.md").write_bytes(source_readme.read_bytes())
    source_url = f"https://huggingface.co/{LOCK['modelId']}/blob/{LOCK['revision']}/README.md"
    notice = (
        "Scene-model source and license notice\n\n"
        f"Model: {LOCK['modelId']}\n"
        f"Pinned revision: {LOCK['revision']}\n"
        f"License: {LOCK['license']} (as declared in the pinned upstream README model-card metadata)\n"
    )
    if source_license.is_file():
        notice += "The upstream LICENSE file is included separately as scene-model-LICENSE.txt.\n"
    else:
        notice += (
            "The pinned model snapshot contains no LICENSE file. This package includes the complete upstream README model card and does not invent a copyright holder or year.\n"
        )
    notice += f"Source: {source_url}\n"
    (output_dir / "scene-model-NOTICE.txt").write_text(notice, encoding="utf-8")
    if manifest["sizeBytes"] != LOCK["expectedSizeBytes"] or manifest["sha256"] != LOCK["expectedSha256"]:
        import onnx

        exported = onnx.load(str(onnx_path), load_external_data=False)
        initializers = []
        for tensor in exported.graph.initializer:
            serialized = tensor.SerializeToString(deterministic=True)
            initializers.append({
                "name": tensor.name,
                "dataType": tensor.data_type,
                "dimensions": list(tensor.dims),
                "serializedBytes": len(serialized),
                "serializedSha256": hashlib.sha256(serialized).hexdigest(),
            })
        (output_dir / "scene-model-v1.initializer-digests.json").write_text(
            json.dumps({
                "validatedExpectedSha256": LOCK["expectedSha256"],
                "exportedSha256": manifest["sha256"],
                "exportedSizeBytes": manifest["sizeBytes"],
                "cpu": {
                    "machine": platform.machine(),
                    "torchCpuCapability": torch.backends.cpu.get_cpu_capability(),
                    "atenCpuCapabilityOverride": os.environ.get("ATEN_CPU_CAPABILITY"),
                    "torchIntraopThreads": torch.get_num_threads(),
                    "torchInterOpThreads": torch.get_num_interop_threads(),
                },
                "initializers": initializers,
            }, indent=2) + "\n", encoding="utf-8"
        )
        raise RuntimeError(
            "Exported model differs from the validated pinned artifact: "
            f"size={manifest['sizeBytes']} sha256={manifest['sha256']}; "
            f"CPU capability={torch.backends.cpu.get_cpu_capability()}, "
            f"ATEN_CPU_CAPABILITY={os.environ.get('ATEN_CPU_CAPABILITY')!r}; "
            f"initializer digests written to {output_dir / 'scene-model-v1.initializer-digests.json'}"
        )
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
