# PG-062 mobile DWARF import evidence

## Scope and implementation

Luna coders implemented disjoint protocol/download, localized UI/queue, and Android/iOS platform files. Coordinator reviewed transfers, path ownership, exact grid filenames, manifest recovery, source hashes, queue reload, lifecycle and native packaging. Camera originals are read only. App-owned downloaded originals are retained. The HTTP directory index must actually enumerate the full package; thumbnail metadata never substitutes for original photos.

Android ARM64 application version is 1.4.0+19 (`com.lumiaiq.pocketgigascan`), minimum API 29, target API 36. The default DWARF address is editable `192.168.88.1`; system Wi-Fi settings are available from the import page. Android permits camera HTTP traffic and the client restricts connections to local network hosts.

## Physical Android evidence

Wireless ADB installed and executed `integration_test/dwarf_device_test.dart` on the connected Moto g play 2024, Android 14/API 34, ARM64. Final run passed. The generated phone-local HTTP fixture interrupted a JPEG transfer, then re-created the downloader and resumed using Range and the persisted validator. All four JPEG bytes and hashes matched. Complete input became one durable queue item; repeating admission did not duplicate it, and repository reload recovered it. The native ABI was available and actual device CPU resource readings were returned.

The first phone run exposed a queue output path inconsistent with repository reload validation. The coordinator diagnosed the issue; Luna fixed the sibling output location and added reload coverage. The second phone run passed. USB transport instability was resolved by switching to wireless ADB; this was transport recovery, not application recovery.

This initial 1.4.0 fixture proves phone runtime behavior, not real camera firmware compatibility, original-directory accessibility or panorama seam quality. The subsequent real-STA qualification is recorded below; full camera-origin transfers and optical acceptance remain separate evidence.

## Source and build checks

The protocol suite covers package discovery, thumbnail mapping, actual folder fallback, interrupted transfers, cancellation, source identity changes, ignored Range, malformed Content-Range, backup recovery, unsafe names and duplicate writers. UI coverage includes English/Chinese, first-transfer pause and offline recovery. Admission checks reject incomplete/tampered sources and deduplicate across restart.

Core formatting and both Windows/Android build-script contracts pass. The current source Android native library was rebuilt with pinned inputs. The normal Windows builder's core suite passes 212 tests, with two optional real-photo tests ignored. Final Flutter analysis reports no issues and all 304 Flutter tests pass. The normal source-based Windows Release builder passes and packages the release with dependency licenses; this is a desktop regression/build qualification, not a phone runtime requirement.

Windows regression artifact: `.build/dwarf-mobile-1.4.0/PocketGigaScan-Windows-x64.zip`; SHA-256 `65ee21c03d75d0f1025ac6585b572bb3155697d04f0dd3c5b562b08798e8ad5d`.

Android release APK rebuilt from the final source, v2 signature verified, and installed over the existing package through wireless ADB without clearing application data. Package manager confirms version 1.4.0, build 19, min SDK 29 and target SDK 36; the package includes ARM64 only. The release app was launched and its DWARF connection screen was observed on the phone. This visual check establishes the rendered connection interface, not successful camera connectivity.

Artifact: `.local/deliverables/PocketGigaScan-Android-1.4.0-DWARF3.apk` (ignored, local delivery).
SHA-256: `6132ab7754ebe9462f8a9a94c13e677bc121e9447ed2bd316c0236f546b6e371`.

The coordinator reviewed intentional mobile screenshot changes: added DWARF navigation, phone import guidance and iOS runtime resource values. Desktop golden files are unchanged. Lifecycle checks pass all 11 cases, with success fixtures explicitly providing iOS runtime readings/pause records and a deterministic queue; explicit Android failure mocks remain intact.

## iOS boundary

The checked-in iOS scaffold, local-network permission strings/ATS, storage/export adapters, thermal/resource readings, durable background interruption handling and optional static native build script are present. Plist parsing and Apple shell syntax pass. Windows cannot compile Xcode/Swift or validate iOS runtime. See [macOS handoff](../DWARF-MOBILE-IOS-HANDOFF.md).

## 1.4.1 real STA follow-up

The actual camera reports numeric `deviceId: 2`, serial alias `sn` and nested `sdCardInfo.hasSdcard`. The former string cast failed before connection completed. The shared parser now accepts that response, preserves legacy fields, and rejects missing identity or explicitly absent SD cards. Only redacted fixtures are committed.

Controlled phone and desktop Dart HTTP comparisons establish that this firmware returns a populated album response for exact `Content-Type: application/json`, but an empty 200 for `application/json; charset=utf-8`. The client now uses exact JSON content type, UTF-8 encoded bytes and explicit Content-Length. Empty/invalid responses produce sanitized errors rather than echoing potentially sensitive response contents.

The final wireless-ADB phone test passed both actual STA identity/album/original enumeration and the independent interruption/resume fixture. At `192.168.1.15`, the actual SDK client found 7 panorama packages; the first package enumerated 217 JPEG originals. No passwords or raw device-info responses were stored or printed. This confirms connection, metadata and directory enumeration on the connected camera; no full real-source download, reconstruction or seam-quality qualification is claimed.

Release 1.4.1+20 supersedes the initial 1.4.0 package. Final analysis is clean and all 308 Flutter tests pass, including 16 protocol/download tests. The ARM64 Release build and v2 signature verification pass. Wireless ADB installed it with `install -r` and launched MainActivity; the phone package manager confirms versionName 1.4.1, versionCode 20, min SDK 29 and target SDK 36. Existing app data was retained. The native engine is unchanged from the qualified 1.4.0 source build.

Artifact: `.local/deliverables/PocketGigaScan-Android-1.4.1-DWARF3.apk`.
SHA-256: `d914a5c77e41f855b28f5f168761fd0656fb696fb4a4ed607e59d2cd6eb3068a`.
