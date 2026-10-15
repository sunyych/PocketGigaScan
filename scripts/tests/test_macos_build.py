"""Offline contract checks for the pinned macOS build pipeline."""
from __future__ import annotations

import json
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
VERIFIER_SPEC = importlib.util.spec_from_file_location("verify_macos_package", ROOT / "scripts/verify-macos-package.py")
VERIFIER = importlib.util.module_from_spec(VERIFIER_SPEC)
assert VERIFIER_SPEC.loader is not None
VERIFIER_SPEC.loader.exec_module(VERIFIER)


class MacBuildContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.lock = json.loads((ROOT / "scripts/macos-dependencies.lock.json").read_text(encoding="utf-8"))
        cls.builder = (ROOT / "scripts/build-stitch-macos.sh").read_text(encoding="utf-8")
        cls.native = (ROOT / "Apps/Flutter/stitch_app/tool/native/apple/build_macos_native.sh").read_text(encoding="utf-8")
        cls.embed = (ROOT / "Apps/Flutter/stitch_app/tool/native/apple/embed_macos_runtime.sh").read_text(encoding="utf-8")
        cls.verifier = (ROOT / "scripts/verify-macos-package.py").read_text(encoding="utf-8")
        cls.workflow = (ROOT / ".github/workflows/macos-build.yml").read_text(encoding="utf-8")

    def test_architecture_and_macos_floor_match_verified_ort_binary(self) -> None:
        self.assertEqual(self.lock["architecture"], "arm64")
        self.assertEqual(self.lock["minimumMacOS"], "14.0")
        self.assertEqual(self.lock["onnxruntime"]["minimumMacOS"], "14.0")
        self.assertEqual(self.lock["onnxruntime"]["version"], "1.31.0")
        self.assertEqual(self.lock["onnxruntime"]["sha256"], "1031b36dd3bdaa8d976a6130d9cf2a05e9be320b93ae804f8427b91dc3432afc")

    def test_model_is_the_existing_canonical_export(self) -> None:
        model = self.lock["sceneModel"]
        manifest = json.loads((ROOT / model["manifest"]).read_text(encoding="utf-8"))
        self.assertEqual(model["sha256"], manifest["expectedSha256"])
        self.assertEqual(model["sizeBytes"], manifest["expectedSizeBytes"])
        self.assertIn("export-scene-model.py", self.workflow)
        self.assertIn("scene-model-cache", self.workflow)
        self.assertIn("scripts/scene-model-export.requirements.txt", self.workflow)
        self.assertIn("Verify the cached or freshly exported model", self.workflow)
        self.assertIn("verify-macos-package.py --model", self.workflow)
        self.assertIn("scene-model-LICENSE.txt", self.builder)

    def test_release_build_embeds_native_runtime_and_scene_model(self) -> None:
        self.assertIn("export LUMIA_NATIVE_APPLE_ENABLED=YES", self.builder)
        self.assertIn('"$flutter" build macos --release', self.builder)
        self.assertNotIn("--no-codesign", self.builder)
        self.assertIn('"$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Frameworks"', self.embed)
        self.assertIn("libonnxruntime.dylib", self.embed)
        self.assertIn("Contents/Resources/models/scene-model-v1.onnx", self.verifier)
        self.assertIn("lumia_gigascan_job_json", self.verifier)
        self.assertIn('"command": "capabilities"', self.verifier)
        self.assertIn('"command": "configureResources"', self.verifier)
        self.assertLess(self.verifier.index('"command": "configureResources"'), self.verifier.index('"command": "start"'))
        self.assertIn('"totalMemoryBudgetMiB": 2048', self.verifier)
        self.assertIn('"jxl"', self.verifier)
        self.assertNotIn("lumia_scene_open", self.verifier)

    def test_clean_source_native_build_avoids_host_codec_libraries(self) -> None:
        for flag in ("-DBUILD_JPEG=ON", "-DBUILD_PNG=ON", "-DBUILD_ZLIB=ON"):
            self.assertIn(flag, self.native)
        self.assertIn("cp -L", self.native)
        self.assertIn('"$runtime_dir"/*.dylib', self.embed)
        self.assertIn("otool", self.embed)

    def test_distribution_is_public_runner_artifact_without_signing_credentials(self) -> None:
        for trigger in ("push:", "pull_request:", "workflow_dispatch:"):
            self.assertIn(trigger, self.workflow)
        self.assertIn("runs-on: macos-15", self.workflow)
        self.assertIn("actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", self.workflow)
        self.assertIn("ad-hoc", (ROOT / "Apps/Flutter/stitch_app/APPLE-BUILD.md").read_text(encoding="utf-8"))
        self.assertNotIn("secrets.", self.workflow)

    def test_model_verifier_rejects_wrong_pinned_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            model = Path(temporary) / "scene-model-v1.onnx"
            manifest = Path(temporary) / "scene-model-v1.manifest.json"
            model.write_bytes(b"not the pinned ONNX model")
            manifest.write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Pinned scene model size/SHA mismatch"):
                VERIFIER.verify_model(model, manifest)

    def test_macho_floor_parser_rejects_newer_dependencies(self) -> None:
        binary = Path("libonnxruntime.dylib")
        output = """Load command 1
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 14.0.0
      sdk 26.2
   ntools 1
"""
        with patch.object(VERIFIER, "run", return_value=output):
            VERIFIER.verify_macho_minimum(binary, "14.0")
        with patch.object(VERIFIER, "run", return_value=output.replace("minos 14.0.0", "minos 15.0")):
            with self.assertRaisesRegex(ValueError, "requires macOS 15.0"):
                VERIFIER.verify_macho_minimum(binary, "14.0")


if __name__ == "__main__":
    unittest.main()
