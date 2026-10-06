# Build and download

Windows build entry: `scripts/build-dwarf-stitch-windows.ps1`. The source engine is `native/core`; no external sibling checkout or machine-local DLL is required. The builder prepares pinned OpenCV and verified official libjxl dependencies, runs native/application checks, builds normal `lib/main.dart` Release, and packages the EXE with its required DLLs, data and licenses.

GitHub workflow: `.github/workflows/windows-build.yml`. Each push builds a ZIP/checksum artifact. Default-branch pushes update the stable `latest` prerelease and assets; pull requests and other branches cannot overwrite that release. Source, workflow and build logs identify the exact commit. Do not distribute the EXE by itself.

The ZIP includes the selected Visual Studio toolchain's x64 Release C++ runtime DLLs beside the EXE. The builder checks their PE architecture and required files, and records versions and SHA-256 inventory. This uses Microsoft's [app-local deployment](https://learn.microsoft.com/en-us/cpp/windows/choosing-a-deployment-method?view=msvc-170); runtime updates are delivered by rebuilding the application package. Failed Flutter screenshot tests upload their diagnostic PNGs for seven days.

## Local setup

Install Flutter 3.44.2 (Dart 3.12.2), Rust 1.88.0 with MSVC target, Visual Studio 2026 C++ desktop tools (MSVC 14.50 or newer), CMake with the Visual Studio 18 generator, Python and Git. Run the PowerShell builder from the repository. The verified libjxl static SDK needs the newer Microsoft STL; VS 2022's 14.44 libraries cannot link it. CI uses the explicit `windows-2025-vs2026` hosted image. Native dependencies may be reused through explicit path options; clean CI downloads/builds them independently.

```powershell
pwsh -File scripts/build-dwarf-stitch-windows.ps1
# Optional verified local dependency reuse:
pwsh -File scripts/build-dwarf-stitch-windows.ps1 `
  -OpenCvDir C:/SDKs/opencv-4.13.0/install `
  -JxlSdk C:/SDKs/libjxl-0.12.0 `
  -DjxlExecutable C:/SDKs/libjxl-0.12.0/tools/djxl.exe `
  -FlutterPath C:/SDKs/flutter/bin/flutter.bat
```

The builder verifies dependency versions/checksums. Its `-PlanOnly` option
prints the pinned versions and output paths without building.

## Android

The Android application shares Flutter and the vendored native processing engine.
Install Android SDK platform 36, NDK 28.2.13676358, JDK 21, CMake/Ninja, Flutter
3.44.2 and Rust 1.88.0 with `aarch64-linux-android`. Native minimum API is 29
(Android 10). The current default APK selects ARM64; x86_64 is an explicit
optional build target. Retired camera/DJI shells are not used.

```powershell
rustup target add aarch64-linux-android
pwsh -File scripts/test-build-stitch-android-core.Tests.ps1
pwsh -File scripts/build-stitch-android-core.ps1 -AndroidSdkRoot D:/Android/Sdk
cd Apps/Flutter/stitch_app
flutter pub get --enforce-lockfile
flutter analyze
flutter test --reporter expanded
flutter build apk --release --target-platform android-arm64
```

Set `JAVA_HOME` to the installed JDK and `ANDROID_HOME` to the SDK before
building. The builder downloads the SHA-256-pinned official OpenCV Android SDK
and libjxl source archives, builds JPEG XL and the source engine, rejects unresolved native dependencies,
checks both core/runtime ELF architecture and 16 KiB LOAD alignment, and stages
required notices and hashed provenance. Gradle refuses missing ABI libraries or
incomplete license assets. Output is
`Apps/Flutter/stitch_app/build/app/outputs/flutter-apk/app-release.apk`.
The local release currently uses a development signing key; it is not a Play
Store release or a guarantee of compatibility with an APK signed elsewhere.

`-BuildTests` additionally builds a native ARM64 test executable outside APK
assets. `-JxlOnly` builds dependencies only. `just check`, `just android-core`,
`just android-build` and `just android-check` provide current product recipes
when `just` is installed. The Windows publishing workflow does not publish or
physically qualify Android packages.

See [Android design](gigascan/ANDROID-STITCH-DESIGN.md) and
[current qualification](gigascan/evidence/ANDROID-STITCH-2026-10-05.md).
