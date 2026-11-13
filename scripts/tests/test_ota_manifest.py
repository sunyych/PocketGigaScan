import hashlib
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from scripts.generate_ota_manifest import generate, validate_existing


class OtaManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.package = self.root / "PocketGigaScan-Windows-x64.zip"
        self.package.write_bytes(b"verified package bytes")
        self.build = self.root / "build-manifest.json"
        self.build.write_text(json.dumps({
            "githubSha": "a" * 40,
            "authenticodeSigning": {
                "verifiedBy": "Windows Authenticode and SignTool",
                "productVersion": "1.5.7+36",
            },
        }))
        with zipfile.ZipFile(self.package, "w") as archive:
            archive.writestr("build-manifest.json", self.build.read_text())
            archive.writestr("payload.bin", b"verified package bytes")
        self.package.with_name(self.package.name + ".sha256").write_text(
            f"{hashlib.sha256(self.package.read_bytes()).hexdigest()}  {self.package.name}\n"
        )
        self.pubspec = self.root / "pubspec.yaml"
        self.pubspec.write_text("name: stitch_app\nversion: 1.5.7+36\n")

    def tearDown(self):
        self.temp.cleanup()

    def generate(self, **kwargs):
        return generate("windows-x64", self.package, self.build, self.pubspec,
                        "a" * 40, kwargs.get("current_manifest"))

    def test_generates_exact_schema_and_hash(self):
        result = self.generate()
        self.assertEqual(result, {
            "schemaVersion": 1,
            "platform": "windows-x64",
            "version": "1.5.7+36",
            "asset": self.package.name,
            "sizeBytes": self.package.stat().st_size,
            "sha256": hashlib.sha256(self.package.read_bytes()).hexdigest(),
        })

    def test_supports_android_and_macos_manifest_contracts(self):
        for platform, asset, source_field in (
            ("android-arm64", "PocketGigaScan-Android-arm64.apk", "coreSourceCommit"),
            ("macos-arm64", "PocketGigaScan-macOS-arm64.zip", "sourceRevision"),
        ):
            package = self.root / asset
            package.write_bytes(platform.encode())
            build = self.root / f"{platform}-build-manifest.json"
            build.write_text(json.dumps({source_field: "a" * 40}))
            result = generate(platform, package, build, self.pubspec, "a" * 40, None)
            self.assertEqual(result["platform"], platform)
            self.assertEqual(result["asset"], asset)
            self.assertEqual(result["sha256"], hashlib.sha256(platform.encode()).hexdigest())

    def test_rejects_bad_source_commit_version_and_unsigned_windows(self):
        for mutation in (
            lambda: self.build.write_text('{"githubSha":"broken"}'),
            lambda: self.build.write_text(json.dumps({"githubSha": "b" * 40})),
            lambda: self.pubspec.write_text("version: 1.5.7+0\n"),
        ):
            with self.subTest(mutation=mutation):
                mutation()
                with self.assertRaises(ValueError):
                    self.generate()

    def test_rejects_lower_version_and_same_version_byte_change(self):
        current = self.root / "current.json"
        current.write_text(json.dumps({
            "schemaVersion": 1, "platform": "windows-x64", "version": "1.5.8+37",
            "asset": self.package.name, "sizeBytes": 10, "sha256": "0" * 64,
        }))
        with self.assertRaisesRegex(ValueError, "rollback"):
            self.generate(current_manifest=current)
        self.pubspec.write_text("version: 1.5.7+36\n")
        current.write_text(json.dumps({
            "schemaVersion": 1, "platform": "windows-x64", "version": "1.5.7+36",
            "asset": self.package.name, "sizeBytes": 10,
            "sha256": hashlib.sha256(b"different").hexdigest(),
        }))
        with self.assertRaisesRegex(ValueError, "without incrementing"):
            self.generate(current_manifest=current)

    def test_requires_build_number_to_increase_even_when_marketing_version_increases(self):
        current = self.root / "current.json"
        current.write_text(json.dumps({
            "schemaVersion": 1, "platform": "windows-x64", "version": "1.5.7+36",
            "asset": self.package.name, "sizeBytes": 10, "sha256": "0" * 64,
        }))
        self.pubspec.write_text("version: 1.6.0+35\n")
        source = json.loads(self.build.read_text())
        source["authenticodeSigning"]["productVersion"] = "1.6.0+35"
        self.build.write_text(json.dumps(source))
        with zipfile.ZipFile(self.package, "w") as archive:
            archive.writestr("build-manifest.json", json.dumps(source))
        self.package.with_name(self.package.name + ".sha256").write_text(
            f"{hashlib.sha256(self.package.read_bytes()).hexdigest()}  {self.package.name}\n"
        )
        with self.assertRaisesRegex(ValueError, "build number"):
            self.generate(current_manifest=current)

    def test_rejects_tampered_checksums_and_bad_package_name(self):
        current = self.root / "current.json"
        current.write_text(json.dumps({
            "schemaVersion": 1, "platform": "windows-x64", "version": "1.5.6+35",
            "asset": self.package.name, "sizeBytes": 10, "sha256": "NOT-A-HASH",
        }))
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            validate_existing(current, "windows-x64")
        self.package.with_name(self.package.name + ".sha256").write_text("0" * 64 + "  " + self.package.name)
        with self.assertRaisesRegex(ValueError, "do not match"):
            self.generate()
        self.package.rename(self.root / "renamed.zip")
        with self.assertRaisesRegex(ValueError, "exactly"):
            self.generate()


if __name__ == "__main__":
    unittest.main()
