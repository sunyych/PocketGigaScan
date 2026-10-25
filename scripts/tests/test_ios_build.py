"""Repository contracts for the iOS CI build and artifact boundary."""

from __future__ import annotations

import re
import importlib.util
import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ios-build.yml"
ANDROID_WORKFLOW = ROOT / ".github/workflows/android-build.yml"
PACKAGER = ROOT / "scripts/package_ios_build.py"
README = ROOT / "scripts/README-ios-build.md"
SPEC = importlib.util.spec_from_file_location("package_ios_build", PACKAGER)
ios_packager = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ios_packager)


class IOSBuildContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        cls.android = ANDROID_WORKFLOW.read_text(encoding="utf-8")
        cls.packager = PACKAGER.read_text(encoding="utf-8")
        cls.readme = README.read_text(encoding="utf-8")

    def test_pinned_flutter_action_and_lockfile_match_android_ci(self) -> None:
        self.assertIn("runs-on: macos-15", self.workflow)
        self.assertRegex(self.workflow, r"timeout-minutes:\s*240\b")
        self.assertRegex(self.workflow, r"flutter-version:\s*'3\.44\.2'")
        flutter_action = re.search(r"uses:\s*(subosito/flutter-action@[^\s#]+)", self.workflow)
        android_action = re.search(r"uses:\s*(subosito/flutter-action@[^\s#]+)", self.android)
        self.assertIsNotNone(flutter_action)
        self.assertIsNotNone(android_action)
        self.assertEqual(flutter_action.group(1), android_action.group(1))
        self.assertIn("scripts/build-stitch-ios.sh", self.workflow)
        self.assertIn("--cache-dir .build/ios-core-cache", self.workflow)
        self.assertIn("--output-dir .build/ios-artifacts", self.workflow)

    def test_builds_device_release_and_simulator_debug_without_signing(self) -> None:
        self.assertIn("Build pinned native core and unsigned iOS app bundles", self.workflow)
        wrapper = ROOT.joinpath("scripts/build-stitch-ios.sh").read_text(encoding="utf-8")
        self.assertIn('"$flutter" build ios --release --no-codesign', wrapper)
        self.assertIn('"$flutter" build ios --debug --simulator --no-codesign', wrapper)
        self.assertIn("Run NativeJobApi smoke on an available iOS simulator", self.workflow)
        self.assertIn("integration_test/ios_native_smoke_test.dart", self.workflow)

    def test_real_build_and_archive_errors_stop_artifact_upload(self) -> None:
        self.assertGreaterEqual(self.workflow.count("set -euo pipefail"), 4)
        self.assertNotIn("continue-on-error: true", self.workflow)
        self.assertIn("if-no-files-found: error", self.workflow)
        self.assertIn("check=True", self.packager)
        self.assertIn('"native-evidence"', self.packager)
        self.assertIn('"--keepParent"', self.packager)
        self.assertIn("archive.stat().st_size == 0", self.packager)
        self.assertIn("hashlib.sha256()", self.packager)
        self.assertIn("sha256_file(archive)", self.packager)

    def test_ci_runs_native_builder_contract_and_caches_only_locked_dependencies(self) -> None:
        self.assertIn("python3 scripts/tests/test_ios_native_build.py", self.workflow)
        self.assertIn("actions/cache/restore@caa296126883cff596d87d8935842f9db880ef25", self.workflow)
        self.assertIn("actions/cache/save@caa296126883cff596d87d8935842f9db880ef25", self.workflow)
        self.assertIn("path: .build/ios-core-cache/dependencies", self.workflow)
        self.assertIn("hashFiles('scripts/ios-dependencies.lock.json')", self.workflow)
        self.assertIn("SDK-PARTIAL-{0}-{1}", self.workflow)
        self.assertIn("steps.build-ios.outcome", self.workflow)
        self.assertNotIn("path: .build/ios-core-cache\n", self.workflow)

    def test_artifact_contract_checks_compiled_icons_and_correct_targets(self) -> None:
        self.assertIn("com.lumiaiq.pocketgigascan", self.packager)
        self.assertIn('"iPhoneOS"', self.packager)
        self.assertIn('"iPhoneSimulator"', self.packager)
        self.assertIn('["xcrun", "lipo", "-archs"', self.packager)
        self.assertIn('"assetutil", "--info"', self.packager)
        self.assertIn('"app_icon_catalog": "AppIcon"', self.packager)
        self.assertIn("CFBundleShortVersionString", self.packager)
        self.assertIn("CFBundleVersion", self.packager)
        self.assertIn('["xcrun", "nm", "-gU"', self.packager)
        for symbol in ios_packager.REQUIRED_NATIVE_SYMBOLS:
            self.assertIn(symbol, self.packager)

    def test_artifacts_state_linked_abi_and_unsigned_distribution_boundary(self) -> None:
        contract = (self.packager + "\n" + self.readme).lower()
        self.assertIn("no-codesign", contract)
        self.assertIn("not a signed ipa", contract)
        self.assertIn("rust panorama core linked", contract)
        self.assertIn("linked-rust-ffi", contract)
        self.assertIn("required abi exports", contract)
        self.assertIn("archive sha-256 records", contract)
        self.assertNotIn("not linked", contract)
        self.assertIn("testflight", contract)
        self.assertIn("physical device", contract)


class IOSAppValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Runner.app"
        self.app.mkdir()
        (self.app / "Runner").write_bytes(b"fixture executable")
        (self.app / "Assets.car").write_bytes(b"fixture asset catalog")
        self.write_info()
        self.native_root = self.root / "ios" / "Native"
        self.native_manifest = self.native_root / "build-manifest.json"
        self.native_root.mkdir(parents=True)
        (self.native_root / "iphoneos").mkdir()
        (self.native_root / "iphonesimulator").mkdir()
        (self.native_root / "licenses").mkdir()
        self.device_archive = self.native_root / "iphoneos" / "liblumia_gigascan_core.a"
        self.simulator_archive = self.native_root / "iphonesimulator" / "liblumia_gigascan_core.a"
        self.device_archive.write_bytes(b"device archive fixture")
        self.simulator_archive.write_bytes(b"simulator archive fixture")
        (self.native_root / "licenses" / "NOTICE.txt").write_text("native notice", encoding="utf-8")
        self.write_native_manifest()

    def write_native_manifest(self, **changes: object) -> None:
        manifest = {
            "schemaVersion": 1,
            "sourceRevision": "abc123",
            "nativeCoreSourceRevision": "def456",
            "minimumIOS": "13.0",
            "variants": [
                {"kind": "device", "sdk": "iphoneos", "architecture": "arm64"},
                {"kind": "simulator", "sdk": "iphonesimulator", "architecture": "arm64"},
            ],
            "retainedSymbols": list(ios_packager.REQUIRED_NATIVE_SYMBOLS),
            "capabilities": {
                "png": True,
                "tiff": True,
                "jpeg": True,
                "jxl": True,
                "sceneAnalysis": False,
            },
            "deviceArchives": {
                self.device_archive.name: ios_packager.sha256_file(self.device_archive),
            },
            "simulatorArchives": {
                self.simulator_archive.name: ios_packager.sha256_file(self.simulator_archive),
            },
            "licenses": ["licenses/NOTICE.txt"],
        }
        manifest.update(changes)
        self.native_manifest.write_text(json.dumps(manifest), encoding="utf-8")

    def write_info(self, **changes: object) -> None:
        info = {
            "CFBundleIdentifier": "com.lumiaiq.pocketgigascan",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "4",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "CFBundleExecutable": "Runner",
            "MinimumOSVersion": "13.0",
        }
        info.update(changes)
        with (self.app / "Info.plist").open("wb") as info_file:
            plistlib.dump(info, info_file)

    def apple_tool_results(self, *, icon_name: str = "AppIcon") -> list[subprocess.CompletedProcess[str]]:
        return [
            subprocess.CompletedProcess(args=[], returncode=0, stdout="arm64\n", stderr=""),
            subprocess.CompletedProcess(
                args=[], returncode=0,
                stdout="0000000000001000 T _lumia_gigascan_abi_version\n"
                "0000000000001010 T _lumia_gigascan_job_json\n"
                "0000000000001020 T _lumia_gigascan_free\n"
                "0000000000001030 T _lumia_gigascan_is_available\n",
                stderr="",
            ),
            subprocess.CompletedProcess(
                args=[], returncode=0, stdout=json.dumps([{"Name": icon_name}]), stderr=""
            ),
        ]

    def inspect_device(self) -> dict[str, object]:
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=self.apple_tool_results()
        ):
            return ios_packager.inspect_app(
                self.app, "device", "Release", self.native_manifest
            )[0]

    def test_accepts_device_bundle_when_platform_icon_and_arm64_match(self) -> None:
        details = self.inspect_device()
        self.assertEqual(details["bundle_id"], "com.lumiaiq.pocketgigascan")
        self.assertEqual(details["platform"], "iOS device")
        self.assertEqual(details["app_icon_catalog"], "AppIcon")
        self.assertEqual(details["native_core"], "linked-rust-ffi")
        self.assertEqual(details["native_abi_symbols"], list(ios_packager.REQUIRED_NATIVE_SYMBOLS))
        self.assertIn("arm64", details["architectures"])

    def test_accepts_simulator_debug_bundle(self) -> None:
        self.write_info(CFBundleSupportedPlatforms=["iPhoneSimulator"])
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=self.apple_tool_results()
        ):
            details = ios_packager.inspect_app(
                self.app, "simulator", "Debug", self.native_manifest
            )[0]
        self.assertEqual(details["platform"], "iOS simulator")
        self.assertEqual(details["configuration"], "Debug")

    def test_rejects_wrong_bundle_identifier(self) -> None:
        self.write_info(CFBundleIdentifier="com.example.wrong")
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")):
            with self.assertRaisesRegex(SystemExit, "Unexpected iOS bundle identifier"):
                ios_packager.inspect_app(self.app, "device", "Release", self.native_manifest)

    def test_rejects_stale_app_version(self) -> None:
        self.write_info(CFBundleShortVersionString="0.9.0")
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")):
            with self.assertRaisesRegex(SystemExit, "marketing version"):
                ios_packager.inspect_app(self.app, "device", "Release", self.native_manifest)

    def test_rejects_wrong_platform_and_configuration_pair(self) -> None:
        self.write_info(CFBundleSupportedPlatforms=["iPhoneSimulator"])
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")):
            with patch.object(ios_packager, "run_checked", side_effect=self.apple_tool_results()):
                with self.assertRaisesRegex(SystemExit, "does not target iPhoneOS"):
                    ios_packager.inspect_app(self.app, "device", "Release", self.native_manifest)
        with self.assertRaisesRegex(SystemExit, "must be built as Release"):
            ios_packager.inspect_app(self.app, "device", "Debug", self.native_manifest)

    def test_rejects_executable_path_outside_app_bundle(self) -> None:
        self.write_info(CFBundleExecutable="../outside")
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")):
            with self.assertRaisesRegex(SystemExit, "executable is missing"):
                ios_packager.inspect_app(self.app, "device", "Release", self.native_manifest)

    def test_rejects_missing_arm64_and_missing_compiled_icon(self) -> None:
        no_arm = [
            subprocess.CompletedProcess(args=[], returncode=0, stdout="x86_64\n", stderr="")
        ]
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=no_arm
        ):
            with self.assertRaisesRegex(SystemExit, "no arm64 executable slice"):
                ios_packager.inspect_app(self.app, "device", "Release", self.native_manifest)

        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=self.apple_tool_results(icon_name="OldIcon")
        ):
            with self.assertRaisesRegex(SystemExit, "does not contain the AppIcon"):
                ios_packager.inspect_app(self.app, "device", "Release", self.native_manifest)

    def test_rejects_app_without_native_core_exports(self) -> None:
        incomplete_exports = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="0000000000001000 T _lumia_gigascan_job_json\n", stderr=""
        )
        results = self.apple_tool_results()
        results[1] = incomplete_exports
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=results
        ):
            with self.assertRaisesRegex(SystemExit, "does not export the linked Rust panorama core ABI"):
                ios_packager.inspect_app(self.app, "device", "Release", self.native_manifest)

    def test_rejects_native_archive_hash_mismatch(self) -> None:
        self.device_archive.write_bytes(b"changed archive")
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=self.apple_tool_results()
        ):
            with self.assertRaisesRegex(SystemExit, "archive SHA-256 mismatch"):
                ios_packager.inspect_app(self.app, "device", "Release", self.native_manifest)

    def test_rejects_missing_native_license_or_required_symbol(self) -> None:
        (self.native_root / "licenses" / "NOTICE.txt").unlink()
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=self.apple_tool_results()
        ):
            with self.assertRaisesRegex(SystemExit, "license/notice file is missing"):
                ios_packager.inspect_app(self.app, "device", "Release", self.native_manifest)

        (self.native_root / "licenses" / "NOTICE.txt").write_text("native notice", encoding="utf-8")
        self.write_native_manifest(retainedSymbols=["lumia_gigascan_job_json"])
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=self.apple_tool_results()
        ):
            with self.assertRaisesRegex(SystemExit, "missing one or more required FFI symbols"):
                ios_packager.inspect_app(self.app, "device", "Release", self.native_manifest)

    def test_apple_tool_failure_is_not_swallowed(self) -> None:
        error = subprocess.CalledProcessError(1, ["xcrun", "lipo"], stderr="lipo failed")
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=error
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                ios_packager.inspect_app(self.app, "device", "Release", self.native_manifest)

    def test_ditto_failure_and_missing_archive_fail_package(self) -> None:
        output = self.root / "output"
        results = self.apple_tool_results()
        archive_error = subprocess.CalledProcessError(1, ["ditto"], stderr="archive failed")
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager,
            "run_checked",
            side_effect=[*results, archive_error],
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                ios_packager.package(
                    self.app, "device", "Release", output, "abc123", "3.44.2", self.native_manifest
                )
        self.assertEqual(list(output.glob("*.zip")), [])

        results_without_archive = self.apple_tool_results()
        results_without_archive.extend([
            subprocess.CompletedProcess(args=["ditto"], returncode=0, stdout="", stderr=""),
            subprocess.CompletedProcess(args=["ditto"], returncode=0, stdout="", stderr=""),
        ])
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=results_without_archive
        ):
            with self.assertRaisesRegex(SystemExit, "non-empty package"):
                ios_packager.package(
                    self.app, "device", "Release", output, "abc123", "3.44.2", self.native_manifest
                )
        self.assertEqual(list(output.glob("*.zip")), [])


if __name__ == "__main__":
    unittest.main()
