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
        self.assertRegex(self.workflow, r"timeout-minutes:\s*90\b")
        self.assertRegex(self.workflow, r"flutter-version:\s*'3\.44\.2'")
        flutter_action = re.search(r"uses:\s*(subosito/flutter-action@[^\s#]+)", self.workflow)
        android_action = re.search(r"uses:\s*(subosito/flutter-action@[^\s#]+)", self.android)
        self.assertIsNotNone(flutter_action)
        self.assertIsNotNone(android_action)
        self.assertEqual(flutter_action.group(1), android_action.group(1))
        self.assertIn("flutter pub get --enforce-lockfile", self.workflow)

    def test_builds_device_release_and_simulator_debug_without_signing(self) -> None:
        self.assertRegex(self.workflow, r"flutter build ios --release --no-codesign")
        self.assertRegex(self.workflow, r"flutter build ios --debug --simulator --no-codesign")
        self.assertIn("build/ios/iphoneos/Runner.app", self.workflow)
        self.assertIn("build/ios/iphonesimulator/Runner.app", self.workflow)

    def test_real_build_and_archive_errors_stop_artifact_upload(self) -> None:
        self.assertGreaterEqual(self.workflow.count("set -euo pipefail"), 5)
        self.assertNotIn("continue-on-error: true", self.workflow)
        self.assertIn("if-no-files-found: error", self.workflow)
        self.assertIn("check=True", self.packager)
        self.assertIn('["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent"', self.packager)
        self.assertIn("archive.stat().st_size == 0", self.packager)
        self.assertIn("hashlib.sha256()", self.packager)
        self.assertIn("sha256_file(archive)", self.packager)

    def test_artifact_contract_checks_compiled_icons_and_correct_targets(self) -> None:
        self.assertIn("com.lumiaiq.pocketgigascan", self.packager)
        self.assertIn('"iPhoneOS"', self.packager)
        self.assertIn('"iPhoneSimulator"', self.packager)
        self.assertIn('["xcrun", "lipo", "-archs"', self.packager)
        self.assertIn('"assetutil", "--info"', self.packager)
        self.assertIn('"app_icon_catalog": "AppIcon"', self.packager)
        self.assertIn("CFBundleShortVersionString", self.packager)
        self.assertIn("CFBundleVersion", self.packager)

    def test_artifacts_state_the_unsigned_native_free_boundary(self) -> None:
        contract = (self.packager + "\n" + self.readme).lower()
        self.assertIn("no-codesign", contract)
        self.assertIn("not a signed ipa", contract)
        self.assertIn("native stitching", contract)
        self.assertIn("not linked", contract)
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
                args=[], returncode=0, stdout=json.dumps([{"Name": icon_name}]), stderr=""
            ),
        ]

    def inspect_device(self) -> dict[str, object]:
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=self.apple_tool_results()
        ):
            return ios_packager.inspect_app(self.app, "device", "Release")

    def test_accepts_device_bundle_when_platform_icon_and_arm64_match(self) -> None:
        details = self.inspect_device()
        self.assertEqual(details["bundle_id"], "com.lumiaiq.pocketgigascan")
        self.assertEqual(details["platform"], "iOS device")
        self.assertEqual(details["app_icon_catalog"], "AppIcon")
        self.assertIn("arm64", details["architectures"])

    def test_accepts_simulator_debug_bundle(self) -> None:
        self.write_info(CFBundleSupportedPlatforms=["iPhoneSimulator"])
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=self.apple_tool_results()
        ):
            details = ios_packager.inspect_app(self.app, "simulator", "Debug")
        self.assertEqual(details["platform"], "iOS simulator")
        self.assertEqual(details["configuration"], "Debug")

    def test_rejects_wrong_bundle_identifier(self) -> None:
        self.write_info(CFBundleIdentifier="com.example.wrong")
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")):
            with self.assertRaisesRegex(SystemExit, "Unexpected iOS bundle identifier"):
                ios_packager.inspect_app(self.app, "device", "Release")

    def test_rejects_stale_app_version(self) -> None:
        self.write_info(CFBundleShortVersionString="0.9.0")
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")):
            with self.assertRaisesRegex(SystemExit, "marketing version"):
                ios_packager.inspect_app(self.app, "device", "Release")

    def test_rejects_wrong_platform_and_configuration_pair(self) -> None:
        self.write_info(CFBundleSupportedPlatforms=["iPhoneSimulator"])
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")):
            with patch.object(ios_packager, "run_checked", side_effect=self.apple_tool_results()):
                with self.assertRaisesRegex(SystemExit, "does not target iPhoneOS"):
                    ios_packager.inspect_app(self.app, "device", "Release")
        with self.assertRaisesRegex(SystemExit, "must be built as Release"):
            ios_packager.inspect_app(self.app, "device", "Debug")

    def test_rejects_executable_path_outside_app_bundle(self) -> None:
        self.write_info(CFBundleExecutable="../outside")
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")):
            with self.assertRaisesRegex(SystemExit, "executable is missing"):
                ios_packager.inspect_app(self.app, "device", "Release")

    def test_rejects_missing_arm64_and_missing_compiled_icon(self) -> None:
        no_arm = [
            subprocess.CompletedProcess(args=[], returncode=0, stdout="x86_64\n", stderr="")
        ]
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=no_arm
        ):
            with self.assertRaisesRegex(SystemExit, "no arm64 executable slice"):
                ios_packager.inspect_app(self.app, "device", "Release")

        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=self.apple_tool_results(icon_name="OldIcon")
        ):
            with self.assertRaisesRegex(SystemExit, "does not contain the AppIcon"):
                ios_packager.inspect_app(self.app, "device", "Release")

    def test_apple_tool_failure_is_not_swallowed(self) -> None:
        error = subprocess.CalledProcessError(1, ["xcrun", "lipo"], stderr="lipo failed")
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=error
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                ios_packager.inspect_app(self.app, "device", "Release")

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
                ios_packager.package(self.app, "device", "Release", output, "abc123", "3.44.2")
        self.assertEqual(list(output.glob("*.zip")), [])

        results_without_archive = self.apple_tool_results()
        results_without_archive.append(
            subprocess.CompletedProcess(args=["ditto"], returncode=0, stdout="", stderr="")
        )
        with patch.object(ios_packager, "app_version", return_value=("1.2.3", "4")), patch.object(
            ios_packager, "run_checked", side_effect=results_without_archive
        ):
            with self.assertRaisesRegex(SystemExit, "non-empty package"):
                ios_packager.package(self.app, "device", "Release", output, "abc123", "3.44.2")
        self.assertEqual(list(output.glob("*.zip")), [])


if __name__ == "__main__":
    unittest.main()
