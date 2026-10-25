"""Portable contract tests for the native-linked iOS build scripts."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tempfile
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
        self.assertIn(
            'cargo "+$rust_version" rustc --locked --release --target "$target" --lib --crate-type staticlib',
            NATIVE,
        )
        self.assertNotIn('--lib -- \\\n      --crate-type staticlib', NATIVE)
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

    def test_libjxl_ios_cache_patches_object_only_xcode_archive_target(self) -> None:
        self.assertIn('original = "add_library(jxl ${JPEGXL_INTERNAL_OBJECTS})"', NATIVE)
        self.assertIn(
            'patched = \'add_library(jxl ${JPEGXL_INTERNAL_OBJECTS} "${CMAKE_CURRENT_LIST_DIR}/jxl_ios_archive_anchor.cc")\'',
            NATIVE,
        )
        self.assertIn("patch_ios_libjxl_archive_anchor", NATIVE)
        self.assertRegex(
            NATIVE,
            r'cmake --build "\$jxl_build" --config Release --parallel "\$build_jobs"\s+cmake --install "\$jxl_build" --config Release',
        )
        self.assertIn('"sourcePatches": [{"name": "ios-xcode-object-only-jxl-archive-anchor"', NATIVE)
        self.assertIn('digest(patched_cmake)', NATIVE)
        self.assertIn('digest(archive_anchor)', NATIVE)
        self.assertIn('cmake --install "$jxl_build" --config Release', NATIVE)
        self.assertNotIn('cmake --build "$jxl_build" --config Release --target install', NATIVE)

    def test_libjxl_ios_archive_anchor_patch_is_idempotent_and_fails_closed(self) -> None:
        match = re.search(
            r'(?ms)^patch_ios_libjxl_archive_anchor\(\) \{\n  python3 - "\$sources/libjxl/lib/jxl\.cmake" <<\'PY\'\n(.*?)\nPY\n\}',
            NATIVE,
        )
        self.assertIsNotNone(match)
        patch_program = match.group(1)
        original = "add_library(jxl ${JPEGXL_INTERNAL_OBJECTS})\n"
        with tempfile.TemporaryDirectory() as temporary:
            cmake_file = Path(temporary) / "jxl.cmake"
            anchor = cmake_file.with_name("jxl_ios_archive_anchor.cc")

            def apply_patch() -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    [sys.executable, "-c", patch_program, str(cmake_file)],
                    capture_output=True,
                    text=True,
                    check=False,
                )

            cmake_file.write_text(original, encoding="utf-8")
            first = apply_patch()
            self.assertEqual(first.returncode, 0, first.stderr)
            patched = cmake_file.read_text(encoding="utf-8")
            self.assertIn('"${CMAKE_CURRENT_LIST_DIR}/jxl_ios_archive_anchor.cc"', patched)
            self.assertTrue(anchor.is_file())
            self.assertEqual(apply_patch().returncode, 0)

            cmake_file.write_text("unexpected upstream change\n", encoding="utf-8")
            anchor.unlink()
            rejected_context = apply_patch()
            self.assertNotEqual(rejected_context.returncode, 0)
            self.assertIn("expected archive-anchor patch context", rejected_context.stderr)

            cmake_file.write_text(patched, encoding="utf-8")
            anchor.write_text("wrong anchor\n", encoding="utf-8")
            rejected_anchor = apply_patch()
            self.assertNotEqual(rejected_anchor.returncode, 0)
            self.assertIn("Unexpected or incomplete", rejected_anchor.stderr)

    def test_opencv_archive_resolution_uses_only_two_known_install_paths(self) -> None:
        self.assertIn('export OPENCV_LINK_PATHS="$opencv_sdk/lib:$opencv_sdk/lib/opencv4/3rdparty"', NATIVE)
        self.assertIn('verify_archive "$archive_path" "$arch" "$platform_id"', NATIVE)
        self.assertIn('cp "$archive_path" "$output_dir/"', NATIVE)
        self.assertIn('opencv_archive_path "$opencv_sdk" "$name" >/dev/null || exit 66', NATIVE)
        self.assertNotIn('find "$opencv_sdk"', NATIVE)

    @unittest.skipIf(sys.platform == "win32", "Bash fixture execution is validated on macOS CI")
    def test_opencv_archive_resolver_fixture_covers_root_third_party_and_missing(self) -> None:
        bash = shutil.which("bash")
        if not bash:
            self.skipTest("Bash is required to execute the archive resolver fixture")
        match = re.search(r"(?ms)^opencv_archive_path\(\) \{\n.*?^\}", NATIVE)
        self.assertIsNotNone(match)
        with tempfile.TemporaryDirectory() as temporary:
            sdk = Path(temporary)
            (sdk / "lib").mkdir()
            (sdk / "lib" / "opencv4" / "3rdparty").mkdir(parents=True)
            root_archive = sdk / "lib" / "libopencv_core.a"
            third_party_archive = sdk / "lib" / "opencv4" / "3rdparty" / "liblibjpeg-turbo.a"
            root_archive.write_bytes(b"fixture")
            third_party_archive.write_bytes(b"fixture")

            def resolve(name: str) -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    [bash, "-c", match.group(0) + '\nopencv_archive_path "$1" "$2"',
                     "opencv-archive-fixture", str(sdk), name],
                    capture_output=True,
                    text=True,
                    check=False,
                )

            self.assertEqual(resolve("opencv_core").stdout.strip(), str(root_archive))
            self.assertEqual(resolve("libjpeg-turbo").stdout.strip(), str(third_party_archive))
            missing = resolve("missing")
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("missing static archive", missing.stderr)

    @unittest.skipIf(sys.platform == "win32", "Bash fixture execution is validated on macOS CI")
    def test_dependency_builder_preserves_callers_rust_target(self) -> None:
        bash = shutil.which("bash")
        if not bash:
            self.skipTest("Bash is required to execute the build dependency fixture")
        assert_function = re.search(r"(?ms)^assert_cache_target\(\) \{\n.*?^\}", NATIVE)
        dependency_function = re.search(
            r"(?ms)^build_dependencies_for_target\(\) \{\n.*?^\}", NATIVE
        )
        self.assertIsNotNone(assert_function)
        self.assertIsNotNone(dependency_function)
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary) / "cache"
            cache.mkdir()
            sdk_path = Path(temporary) / "ios-sdk"
            sdk_path.mkdir()
            script = "\n".join((
                assert_function.group(0),
                dependency_function.group(0),
                f'cache="{cache}"',
                f'builds="{cache}/dependencies/build"',
                f'sdks="{cache}/dependencies/sdk"',
                f'sources="{cache}/dependencies/sources"',
                f'opencv_source="{cache}/dependencies/sources/opencv"',
                'minimum_ios="13.0"',
                'build_jobs=2',
                'opencv_modules=()',
                'opencv_libraries=()',
                'jxl_libraries=()',
                'xcrun() { if [[ "$*" == *--show-sdk-path* ]]; then printf "%s\\n" "$fixture_sdk"; else printf "18.0\\n"; fi; }',
                'cmake() { return 0; }',
                'lock_value() { printf "0.12.0\\n"; }',
                f'fixture_sdk="{sdk_path}"',
                'target="aarch64-apple-ios"',
                'build_dependencies_for_target device arm64 iphoneos iphoneos',
                'printf "rust_target=%s\\n" "$target"',
            ))
            result = subprocess.run(
                [bash, "-c", script], capture_output=True, text=True, check=False
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("rust_target=aarch64-apple-ios", result.stdout)

    def test_native_manifest_maps_library_names_to_exact_archive_filenames(self) -> None:
        self.assertIn('output_archive="$platform_dir/lib${name}.a"', NATIVE)
        self.assertIn('archive_names.append("lib" + library + ".a")', NATIVE)
        match = re.search(
            r'(?ms)^python3 - "\$lock" "\$manifest_tmp".*?<<\'PY\'\n(.*?)\nPY\n',
            NATIVE,
        )
        self.assertIsNotNone(match)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path = root / "lock.json"
            lock_path.write_text(json.dumps(LOCK), encoding="utf-8")
            device, simulator = root / "device", root / "simulator"
            licenses = root / "licenses"
            for directory in (device, simulator, licenses):
                directory.mkdir()
            archive_names = ["liblumia_gigascan_core.a"] + [
                "lib" + name + ".a"
                for name in LOCK["opencvLibraries"] + LOCK["jpegXlLibraries"]
            ]
            for directory in (device, simulator):
                for name in archive_names:
                    (directory / name).write_bytes(("fixture:" + name).encode())
            licenses.joinpath("test-license.txt").write_text("fixture", encoding="utf-8")
            patched_cmake = root / "jxl.cmake"
            archive_anchor = root / "jxl_ios_archive_anchor.cc"
            patched_cmake.write_text("patched fixture", encoding="utf-8")
            archive_anchor.write_text("anchor fixture", encoding="utf-8")
            output = root / "build-manifest.json"
            result = subprocess.run(
                [
                    sys.executable, "-c", match.group(1), str(lock_path), str(output),
                    "a" * 40, "13.0", "false", "Xcode fixture", str(device),
                    str(simulator), str(patched_cmake), str(archive_anchor),
                    "device|arm64|iphoneos|aarch64-apple-ios|iphoneos|IOS|18.0|cache-staging/iphoneos",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads(output.read_text(encoding="utf-8"))
            for name in ("liblibjpeg-turbo.a", "liblibpng.a", "libzlib.a"):
                self.assertIn(name, manifest["deviceArchives"])
                self.assertIn(name, manifest["simulatorArchives"])

    def test_linker_config_simulator_arches_match_included_archive_slices(self) -> None:
        self.assertIn("ARCHS[sdk=iphonesimulator*] = $simulator_archs", NATIVE)
        self.assertIn('if [[ "$include_intel" == true ]]; then simulator_archs="arm64 x86_64"; fi', NATIVE)
        bash = shutil.which("bash")
        if sys.platform == "win32" or not bash:
            self.skipTest("Bash linker-config fixture is executed on macOS CI")
        match = re.search(r"(?ms)^write_linker_config\(\) \{\n.*?^\}", NATIVE)
        serialize = re.search(r"(?ms)^serialize_link_libraries\(\) \{\n.*?^\}", NATIVE)
        self.assertIsNotNone(match)
        self.assertIsNotNone(serialize)
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "app"
            flutter = app / "ios" / "Flutter"
            flutter.mkdir(parents=True)
            script_prefix = "\n".join((
                f'app="{app}"',
                'opencv_libraries=(opencv_core libjpeg-turbo)',
                'jxl_libraries=(jxl jxl_cms)',
            ))
            for include_intel, expected_arches, archive_slices in (
                ("false", "arm64", ["arm64"]),
                ("true", "arm64 x86_64", ["arm64", "x86_64"]),
            ):
                script = "\n".join((
                    script_prefix,
                    f'include_intel="{include_intel}"',
                    serialize.group(0),
                    match.group(0),
                    'write_linker_config',
                ))
                result = subprocess.run(
                    [bash, "-c", script], capture_output=True, text=True, check=False
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                config = (flutter / "NativeCore.generated.xcconfig").read_text(encoding="utf-8")
                found = re.search(r"^ARCHS\[sdk=iphonesimulator\*\] = (.+)$", config, re.MULTILINE)
                self.assertIsNotNone(found)
                self.assertEqual(found.group(1), expected_arches)
                self.assertEqual(found.group(1).split(), archive_slices)

    def test_builder_exports_all_dynamic_library_process_symbols(self) -> None:
        symbols = (
            "lumia_gigascan_abi_version",
            "lumia_gigascan_job_json",
            "lumia_gigascan_free",
            "lumia_gigascan_is_available",
        )
        self.assertIn('for symbol in ' + " ".join(symbols), NATIVE)
        project = (ROOT / "Apps/Flutter/stitch_app/ios/Runner.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        debug_target = re.search(
            r"(?ms)^\s*97C147061CF9000F007C117D /\* Debug \*/ = \{\n.*?^\s*buildSettings = \{\n(.*?)^\s*\};\n\s*name = Debug;",
            project,
        )
        release_target = re.search(
            r"(?ms)^\s*97C147071CF9000F007C117D /\* Release \*/ = \{\n.*?^\s*buildSettings = \{\n(.*?)^\s*\};\n\s*name = Release;",
            project,
        )
        self.assertIsNotNone(debug_target)
        self.assertIsNotNone(release_target)
        self.assertIn("ENABLE_DEBUG_DYLIB = NO;", debug_target.group(1))
        self.assertNotIn("ENABLE_DEBUG_DYLIB", release_target.group(1))
        self.assertIn('symbol_flags+=" -Wl,-u,_${symbol}"', NATIVE)
        self.assertIn("-Wl,-force_load", NATIVE)
        self.assertIn("-Wl,-export_dynamic", NATIVE)
        self.assertIn("NativeCore.generated.xcconfig", NATIVE)
        self.assertIn("build-manifest.json", NATIVE)
        self.assertIn("licenses/", NATIVE)
        workflow = (ROOT / ".github/workflows/ios-build.yml").read_text(encoding="utf-8")
        self.assertIn("Diagnose failed iOS app links", workflow)
        self.assertIn("xcodebuild -project ios/Runner.xcodeproj -target Runner", workflow)
        self.assertIn("nm -gU", workflow)

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
