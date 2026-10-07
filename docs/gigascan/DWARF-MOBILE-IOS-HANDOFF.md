# DWARF mobile iOS handoff

The phone-only DWARF import flow is shared Dart code. Open the mobile queue's DWARF action, connect the phone to the camera Wi-Fi, use `192.168.88.1` (or the camera's LAN address), select panorama packages, download originals, and explicitly add completed downloads to the queue. Grid confirmation and final export remain separate from transfer. Firmware must expose the actual panorama directories; unavailable directory enumeration is reported instead of inventing source files.

Downloads persist partial files, validators, byte counts and completed SHA-256 hashes under application support. Returning from background offers recovery. HTTP Range resumes require a matching validator; unsupported Range restarts the affected partial file, while changed source identity is rejected. Completed original files remain available offline.

The retained iOS runner includes local-network permission strings, ATS local-network configuration, application-owned folder intake, security-scoped export, memory/thermal reporting and persisted processing interruption notifications. iOS does not promise indefinite background download or stitching. Xcode compilation and physical iOS validation are still required on macOS.

Use [Apple build instructions](../../Apps/Flutter/stitch_app/APPLE-BUILD.md) and `tool/native/apple/build_apple_native.sh ios` from the Flutter app directory. The build uses this checkout's `native/core`, Rust 1.88.0 and locked dependencies, plus architecture-matched static OpenCV and codec libraries. Generated native staging is ignored. Without the native archive, the shell builds but processing reports unavailable.

macOS acceptance: build device/simulator targets, grant local-network access, verify real DWARF identity and all selected original files, interrupt/relaunch a transfer, check persisted queue deduplication, verify native core ABI loading, then qualify a real photo set and exported files. Preserve camera originals and application data throughout migration.
