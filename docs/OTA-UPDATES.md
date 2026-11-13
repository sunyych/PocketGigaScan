# In-app update publishing

The updater reads the `latest` GitHub prerelease and selects one exact asset name:

| Platform | Manifest | Package |
| --- | --- | --- |
| Windows x64 | `pocketgigascan-ota-windows-x64.json` | `PocketGigaScan-Windows-x64.zip` |
| Android ARM64 | `pocketgigascan-ota-android-arm64.json` | `PocketGigaScan-Android-arm64.apk` |
| macOS ARM64 | `pocketgigascan-ota-macos-arm64.json` | `PocketGigaScan-macOS-arm64.zip` |

Each manifest has `schemaVersion`, `platform`, `version`, `asset`, `sizeBytes`, and lowercase `sha256` fields. The generator obtains the numeric `MAJOR.MINOR.PATCH+BUILD` version from the tracked Flutter `pubspec.yaml`, checks that the supplied build manifest points at the same source commit, and hashes the exact package bytes. It refuses rollback and refuses changing package bytes without increasing the version/build number.

## Windows automated publishing

Only the existing canonical-repository push to the default branch can publish. The workflow still passes through the protected `windows-signing` environment and the SignPath completion verifier. The release job validates the signed build manifest and tracked app version, uploads package metadata, moves the `latest` tag, then uploads the OTA manifest last. Concurrent runs for the default ref are serialized. The publisher validates an existing Windows OTA manifest when present; it can initialize the Windows manifest only when the existing `latest` prerelease has no Windows OTA manifest asset.

Do not manually move `latest` backward or replace a package under the same app version. If publishing fails after package assets have been replaced but before the manifest upload, the prior manifest remains the updater pointer and its checksum will not match the replaced package; rerun the trusted default-branch workflow to complete publication. The updater must reject that checksum mismatch and leave the installed app untouched.

## Android and macOS release requirements

Those platforms are intentionally not published by CI today. The current Android workflow uses Flutter's debug signing for its release APK, which is not a stable app identity for upgrades. The current macOS artifact is ad-hoc signed and not notarized. Neither artifact should be offered as a trusted OTA update. iOS updates remain App Store/TestFlight only.

Before publishing Android, configure a protected release keystore, keep its signing identity stable across app releases, and verify the APK certificate against the certificate of the installed production app. Before publishing macOS, sign with the configured Developer ID identity, verify every nested executable and the final bundle signature, notarize and staple the distribution, and confirm the updater's install path preserves Gatekeeper validation. In both cases, publish only packages built from the canonical repository's protected default branch; run the platform's normal package and signer verification before invoking the manifest generator. Never place keystore material, passwords, or signing tokens in the repository or command line.

Once those checks exist, a maintainer can stage the exact manifest-named package and its platform build manifest, then run from a clean checkout of the package's source commit:

```powershell
python scripts/generate_ota_manifest.py `
  --platform android-arm64 `
  --package .\release\PocketGigaScan-Android-arm64.apk `
  --build-manifest .\release\build-manifest.json `
  --pubspec .\Apps\Flutter\stitch_app\pubspec.yaml `
  --expected-commit <40-character-source-commit> `
  --output .\release\pocketgigascan-ota-android-arm64.json
```

Use `macos-arm64` and its exact package/manifest names for macOS. Download the existing platform OTA manifest from the `latest` prerelease and pass it as `--current-manifest` on subsequent releases. Upload the package first and its OTA manifest last. The helper validates package naming, source commit, tracked version and bytes; it does not sign packages, verify Android certificates, verify macOS signatures/notarization, authenticate a maintainer, or publish a GitHub release. Those checks remain mandatory operator steps until protected platform signing workflows implement them.

## Installing an update

In the app, open **Settings → App updates**, choose **Check**, then **Download and verify update**. The app checks the GitHub asset metadata, file size, and SHA-256 before saving the package; it does not install or execute the download. On Windows, close PocketGigaScan, extract the verified ZIP over the existing portable app folder, then relaunch it. On macOS, close the app and replace the existing app bundle with the verified bundle from the ZIP. On Android, choose a save location in the system file picker, open the APK with Files, and continue only when Android confirms it updates the installed app with the same signing identity. The Android and macOS OTA manifest formats are ready, but no trusted packages are published until their stable production signing paths are configured and verified. iOS updates come from TestFlight or the App Store.
