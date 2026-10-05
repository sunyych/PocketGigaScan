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

## Future Android

The Flutter Android runner and portable native processing API are retained for a future independent Android stitcher. Current Windows pipeline does not build, publish or qualify Android packages. Retired OpenPocketCine Android/DJI shells are not part of this source tree.
