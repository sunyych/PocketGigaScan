"""Offline contract checks for the pinned macOS build pipeline."""
from __future__ import annotations

import json
import importlib.util
import re
import tempfile
import unittest
import xml.etree.ElementTree as ET
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
        export_lock = json.loads((ROOT / "scripts/scene-model-export.lock.json").read_text(encoding="utf-8"))
        asset = export_lock["releaseAsset"]
        self.assertEqual(asset["fileName"], "PocketGigaScan-scene-model-v1.zip")
        self.assertEqual(asset["sizeBytes"], 219959932)
        self.assertEqual(asset["sha256"], "cb9769f81929590711a2a0b84373946c1b429c96ff4eac6bfc4ebe22eb250c41")
        self.assertIn("Download and verify the fixed public model asset", self.workflow)
        self.assertIn("Get-FileHash -Algorithm SHA256", self.workflow)
        self.assertIn("Expand-Archive", self.workflow)
        self.assertNotIn("export-scene-model.py", self.workflow)
        self.assertIn("verify-macos-package.py --model", self.workflow)
        self.assertIn("scene-model-README.md", self.workflow)
        self.assertIn("scene-model-NOTICE.txt", self.workflow)
        self.assertIn("initializer-digests", (ROOT / "scripts/export-scene-model.py").read_text(encoding="utf-8"))
        self.assertIn("scene-model-README.md", self.builder)
        self.assertIn("scene-model-NOTICE.txt", self.builder)

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
        self.assertIn("marker=c/include/brotli/decode.h", self.native)
        self.assertIn("marker=skcms.cc", self.native)
        self.assertIn('marker="$destination/c/include/brotli/decode.h"', self.native)
        self.assertIn('marker="$destination/skcms.cc"', self.native)
        self.assertIn("modules/core/include/opencv2/core/version.hpp", self.native)
        self.assertNotIn("extract_source \"$opencv_archive\" \"$opencv_source\" include/opencv2/core/version.hpp", self.native)
        self.assertIn('local archive="$1" destination="$2" marker="$3" strip_components="${4:-1}"', self.native)
        self.assertIn('tar -xzf "$archive" --strip-components="$strip_components"', self.native)
        self.assertIn('extract_source "$ort_archive" "$ort_root" include/onnxruntime_cxx_api.h 2', self.native)
        self.assertIn("for artifact in include/onnxruntime_c_api.h lib/libonnxruntime.dylib LICENSE ThirdPartyNotices.txt", self.native)
        self.assertIn('rustup component add rustfmt --toolchain "$rust_version"', self.native)
        self.assertIn('export MACOSX_DEPLOYMENT_TARGET="$minimum"', self.native)
        self.assertIn('export CARGO_TARGET_DIR="$repo/.build/macos/cargo-target"', self.native)
        self.assertIn('core_dylib="$CARGO_TARGET_DIR/$target/release/liblumia_gigascan_core.dylib"', self.native)
        self.assertNotIn("c/CMakeLists.txt", self.native)
        self.assertNotIn("src/skcms.cc", self.native)
        self.assertIn("-iname 'PATENTS*'", self.builder)
        self.assertIn("-iname 'README*'", self.builder)
        self.assertIn('OpenCV-$codec-$(basename "$source")', self.builder)

    def test_distribution_is_public_runner_artifact_without_signing_credentials(self) -> None:
        for trigger in ("push:", "pull_request:", "workflow_dispatch:"):
            self.assertIn(trigger, self.workflow)
        self.assertIn("runs-on: macos-15", self.workflow)
        self.assertIn("rustup component add rustfmt --toolchain 1.88.0", self.workflow)
        self.assertIn("actions/cache/restore@caa296126883cff596d87d8935842f9db880ef25", self.workflow)
        self.assertIn("actions/cache/save@caa296126883cff596d87d8935842f9db880ef25", self.workflow)
        self.assertIn("if: always() && steps.macos-native-cache.outputs.cache-hit != 'true'", self.workflow)
        self.assertIn("hashFiles('scripts/macos-dependencies.lock.json')", self.workflow)
        self.assertIn("-READY", self.workflow)
        self.assertIn("-PARTIAL-", self.workflow)
        self.assertIn("steps.build-client.outcome == 'success'", self.workflow)
        self.assertIn("github.run_attempt", self.workflow)
        self.assertNotIn("hashFiles('scripts/macos-dependencies.lock.json', 'Apps/Flutter/stitch_app/tool/native/apple/build_macos_native.sh')", self.workflow)
        self.assertIn("actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", self.workflow)
        self.assertIn("Upload Flutter golden failure images", self.workflow)
        self.assertIn("failure()", self.workflow)
        self.assertIn("test/failures/**/*.png", self.workflow)
        self.assertIn("retention-days: 7", self.workflow)
        self.assertIn("Collect non-qualifying macOS golden snapshots for diagnosis", self.workflow)
        self.assertIn("continue-on-error: true", self.workflow)
        self.assertIn("--update-goldens", self.workflow)
        self.assertIn("macos-golden-diagnostic-snapshots-${{ github.sha }}", self.workflow)
        self.assertIn("test/goldens/*.png", self.workflow)
        for golden_test in (
            "test/batch_queue_screenshot_test.dart",
            "test/force_grid_options_screenshot_test.dart",
            "test/exported_image_viewer_test.dart",
            "test/grid_screenshot_test.dart",
            "test/scene_ui_localization_test.dart",
            "test/tiff_quality_screenshot_test.dart",
        ):
            self.assertIn(golden_test, self.workflow)
        self.assertLess(
            self.workflow.index("Upload Flutter golden failure images"),
            self.workflow.index("Collect non-qualifying macOS golden snapshots for diagnosis"),
        )
        self.assertLess(self.builder.index('"$flutter" test --no-pub'), self.builder.index('build_macos_native.sh'))
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

    def test_macos_runner_localizes_permission_and_native_menus(self) -> None:
        runner = ROOT / "Apps/Flutter/stitch_app/macos/Runner"
        project = (ROOT / "Apps/Flutter/stitch_app/macos/Runner.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        english_permission = (runner / "en.lproj/InfoPlist.strings").read_text(encoding="utf-8")
        chinese_permission = (runner / "zh-Hans.lproj/InfoPlist.strings").read_text(encoding="utf-8")
        chinese_menu_path = runner / "zh-Hans.lproj/MainMenu.strings"
        chinese_menu = chinese_menu_path.read_text(encoding="utf-8")
        xib = ET.parse(runner / "Base.lproj/MainMenu.xib").getroot()
        menu_keys = {
            f"{element.get('id')}.title"
            for element in xib.iter()
            if element.tag in ("menuItem", "menu", "window")
            and element.get("title")
            and element.get("systemMenu") != "main"
        }
        localized_keys = set(re.findall(r'^"([^"]+)"\s*=', chinese_menu, re.MULTILINE))

        self.assertIn('"zh-Hans"', project)
        self.assertIn("InfoPlist.strings in Resources", project)
        self.assertIn("InfoPlist.strings", project)
        self.assertIn('"NSLocalNetworkUsageDescription"', english_permission)
        self.assertIn('"NSLocalNetworkUsageDescription"', chinese_permission)
        self.assertEqual(localized_keys, menu_keys)
        self.assertIn('"APP_NAME"', chinese_menu)
        self.assertIn("MainMenu.xib in Resources", project)

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
