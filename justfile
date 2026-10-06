# PocketGigaScan Windows and Flutter/Android development recipes.
# `just` with no arguments lists the available recipes.

set shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-Command"]

default:
    @just --list

# Analyze and test the shared Flutter application, then verify Android builder contracts.
check: flutter-check android-builder-contract

flutter-check:
    Set-Location Apps/Flutter/stitch_app; flutter pub get; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }; flutter analyze; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }; flutter test

# Verify Android native-core builder behavior without invoking the native build.
android-builder-contract:
    pwsh -NoProfile -File scripts/test-build-stitch-android-core.Tests.ps1

# Build the existing Windows desktop application.
windows-build:
    pwsh -NoProfile -File scripts/build-dwarf-stitch-windows.ps1

# Build and stage the Android ARM64 native core and its generated license assets.
android-core:
    pwsh -NoProfile -File scripts/build-stitch-android-core.ps1

# Build the PocketGigaScan Android release APK for ARM64.
android-build:
    Set-Location Apps/Flutter/stitch_app; flutter build apk --release --target-platform android-arm64

# Run Flutter tests and Android JVM tests/lint after `android-core` has staged native inputs.
android-check:
    Set-Location Apps/Flutter/stitch_app; flutter test; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }; .\android\gradlew.bat -p android testDebugUnitTest lintDebug
