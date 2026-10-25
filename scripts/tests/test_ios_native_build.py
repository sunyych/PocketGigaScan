"""Portable contract tests for the native-linked iOS build scripts."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCK = json.loads((ROOT / "scripts/ios-dependencies.lock.json").read_text(encoding="utf-8"))
MAC_LOCK = json.loads((ROOT / "scripts/macos-dependencies.lock.json").read_text(encoding="utf-8"))
NATIVE = (ROOT / "Apps/Flutter/stitch_app/tool/native/apple/build_ios_native.sh").read_text(encoding="utf-8")
WRAPPER = (ROOT / "scripts/build-stitch-ios.sh").read_text(encoding="utf-8")


class IosNativeBuildContractTests(unittest.TestCase):
    def test_dependency_versions_and_hashes_reuse_verified_apple_pins(self) -> None:
        self.assertEqual(LOCK["opencv"]["version"], MAC_LOCK["opencv"]["version"])
        self.assertEqual(LOCK["opencv"]["url"], MAC_LOCK["opencv"]["url"])
        self.assertEqual(LOCK["opencv"]["sha256"], MAC_LOCK["opencv"]["sha256"])
        self.assertEqual(LOCK["libjxl"]["version"], MAC_LOCK["libjxl"]["version"])
        mac_sources = {item["name"]: item for item in MAC_LOCK["libjxl"]["sources"]}
        for source in LOCK["libjxl"]["sources"]:
            self.assertEqual(source["url"], mac_sources[source["name"]]["url"])
            self.assertEqual(source["sha256"], mac_sources[source["name"]]["sha256"])
        self.assertEqual(LOCK["minimumIOS"], "13.0")
        self.assertEqual(LOCK["rust"]["version"], "1.88.0")
        self.assertEqual(LOCK["flutter"], {
            "version": MAC_LOCK["flutter"]["version"],
            "revision": MAC_LOCK["flutter"]["revision"],
        })
        self.assertFalse(any(key.lower().startswith("onnx") for key in LOCK))

    def test_link_library_names_serialize_as_basename_lists(self) -> None:
        linked = LOCK["opencvLibraries"] + LOCK["opencvSystemLibraries"]
        jxl = LOCK["jpegXlLibraries"]
        for name in linked + jxl:
            self.assertRegex(name, r"^[A-Za-z0-9_+.-]+$")
            self.assertNotIn("[", name)
        self.assertEqual(";".join(linked[-1:]), "z")
        self.assertNotIn("lock_value opencvSystemLibraries", NATIVE)
        function = re.search(
            r"(?ms)^serialize_link_libraries\(\) \{\n(.*?)^\}", NATIVE
        )
        self.assertIsNotNone(function)
        bash = shutil.which("bash")
        if sys.platform == "win32" or not bash:
            self.skipTest("Bash execution is available in the macOS native-build CI")
        command = f"serialize_link_libraries() {{\n{function.group(1)}\n}}\nserialize_link_libraries \"$@\""
        result = subprocess.run(
            [bash, "-c", command, "ios-link-library-contract", *linked],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.stdout, ";".join(linked))

    def test_builder_separates_device_and_simulator_platform_archives(self) -> None:
        self.assertIn("build_variant device arm64 iphoneos aarch64-apple-ios iphoneos IOS", NATIVE)
        self.assertIn("build_variant simulator arm64 iphonesimulator aarch64-apple-ios-sim iphonesimulator-arm64 IOSSIMULATOR", NATIVE)
        self.assertIn("build_variant simulator x86_64 iphonesimulator x86_64-apple-ios iphonesimulator-x86_64 IOSSIMULATOR", NATIVE)
        self.assertIn("--include-intel-simulator", NATIVE)
        self.assertIn("-G Xcode", NATIVE)
        self.assertIn("-DCMAKE_SYSTEM_NAME=iOS", NATIVE)
        self.assertIn("-DCMAKE_OSX_SYSROOT=\"$sdk_path\"", NATIVE)
        self.assertIn("-DCMAKE_OSX_ARCHITECTURES=\"$arch\"", NATIVE)
        self.assertIn("-DCMAKE_OSX_DEPLOYMENT_TARGET=\"$minimum_ios\"", NATIVE)
        self.assertIn("-DWITH_LAPACK=OFF", NATIVE)
        self.assertIn("rustc --locked --release --target \"$target\" --lib", NATIVE)
        self.assertIn("--crate-type staticlib", NATIVE)
        self.assertIn("LC_BUILD_VERSION", NATIVE)
        self.assertIn("LC_VERSION_MIN_IPHONEOS", NATIVE)
        self.assertIn("expected '$expected_platform'", NATIVE)
        self.assertIn('lipo "$archive" -verify_arch "$expected_arch"', NATIVE)
        self.assertNotIn("ade", LOCK["opencvLibraries"])

    def test_libjxl_xcode_tools_are_plain_unsigned_cross_compiled_executables(self) -> None:
        configuration = re.search(
            r'(?ms)^  cmake -S "\$sources/libjxl".*?^  cmake --build "\$jxl_build"',
            NATIVE,
        )
        self.assertIsNotNone(configuration)
        self.assertIn("-DCMAKE_MACOSX_BUNDLE=OFF", configuration.group(0))
        self.assertIn(
            "-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO",
            configuration.group(0),
        )

    def test_builder_exports_all_dynamic_library_process_symbols(self) -> None:
        symbols = (
            "lumia_gigascan_abi_version",
            "lumia_gigascan_job_json",
            "lumia_gigascan_free",
            "lumia_gigascan_is_available",
        )
        self.assertIn('for symbol in ' + " ".join(symbols), NATIVE)
        self.assertIn('symbol_flags+=" -Wl,-u,_${symbol}"', NATIVE)
        self.assertIn("-Wl,-force_load", NATIVE)
        self.assertIn("-Wl,-export_dynamic", NATIVE)
        self.assertIn("NativeCore.generated.xcconfig", NATIVE)
        self.assertIn("build-manifest.json", NATIVE)
        self.assertIn("licenses/", NATIVE)

    def test_builder_limits_recursive_deletes_to_owned_cache(self) -> None:
        self.assertIn(".pocketgigascan-ios-native-cache", NATIVE)
        self.assertIn("Refusing to use a non-empty cache directory", NATIVE)
        self.assertIn('case "$target" in "$cache"/*)', NATIVE)
        self.assertIn("[[ ! -L \"$cursor\" ]]", NATIVE)
        self.assertEqual(NATIVE.count('rm -rf -- "$1"'), 1)
        self.assertIn("remove_cache_tree", NATIVE)

    def test_build_identity_survives_source_archives_without_git_metadata(self) -> None:
        self.assertIn("LUMIA_SOURCE_REVISION", NATIVE)
        self.assertIn('"$repo/SOURCE-REVISION"', NATIVE)
        self.assertIn("rev-parse HEAD", NATIVE)
        self.assertIn("LUMIA_SOURCE_REVISION", WRAPPER)
        self.assertIn("SOURCE-REVISION", WRAPPER)
        self.assertIn("40-character SHA", NATIVE)

    def test_embedded_python_helpers_parse(self) -> None:
        blocks = re.findall(r"<<'PY'\n(.*?)\nPY", NATIVE, re.DOTALL)
        self.assertGreaterEqual(len(blocks), 5)
        for index, block in enumerate(blocks, start=1):
            compile(block, f"build_ios_native.sh:python-block-{index}", "exec")

    def test_wrapper_resolves_locked_dependencies_builds_both_slices_and_packages(self) -> None:
        self.assertIn("--cache-dir DIR", WRAPPER)
        self.assertIn("--output-dir DIR", WRAPPER)
        self.assertIn("--include-intel-simulator", WRAPPER)
        self.assertIn("pub get --enforce-lockfile", WRAPPER)
        self.assertIn('build ios --release --no-codesign', WRAPPER)
        self.assertIn('build ios --debug --simulator --no-codesign', WRAPPER)
        self.assertIn("--kind device --configuration Release", WRAPPER)
        self.assertIn("--kind simulator --configuration Debug", WRAPPER)
        self.assertIn("--source-revision", WRAPPER)
        self.assertIn("--flutter-version", WRAPPER)
        self.assertIn("NativeCore.generated.xcconfig", WRAPPER)

    @unittest.skipIf(sys.platform in {"darwin", "win32"} or shutil.which("bash") is None, "requires a non-Darwin host with executable bash")
    def test_wrapper_fails_fast_off_macos(self) -> None:
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/build-stitch-ios.sh")],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 69)
        self.assertIn("must be built on macOS with Xcode", result.stderr)


if __name__ == "__main__":
    unittest.main()
