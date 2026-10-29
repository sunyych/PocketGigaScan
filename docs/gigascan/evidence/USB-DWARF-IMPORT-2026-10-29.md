# USB DWARF import hardware check — 2026-10-29

## Device copy result

The opt-in harness scanned the mounted removable volume at `G:\Panoramas` and selected `DWARF_PANORAMA_2026-10-23-14-01-48-371`. It chose 312 full-resolution originals (3840 × 2160, 302,216,496 bytes total); the smaller copies in numbered folders `1`–`5` were not selected. The imported task reports a 12 × 26 grid and retains the 33,880-byte full-panorama preview as a separate local file.

SHA-256 matched for all 312 local copies. A second pass confirmed that all 312 G: originals and the source preview still existed and matched their pre-copy hashes. Repeated discovery, controller restart, and clearing only the isolated test queue history did not create duplicate work; the persisted import history prevented rediscovery after queue removal.

The hardware run kept USB source deletion disabled. `nativeStartCalls` was 0, so this verified discovery, copy, preview, and deduplication; it did not run panorama stitching. The seven safety tests passed, including both file-link and directory-link cases on Windows without a permission skip. These fixture tests do not mean automatic deletion was exercised against the real device.

The controller integration suite passed all ten local-fixture cases: copy-free/repeated discovery, row preservation when a panorama is appended, settings inheritance plus maximum-original/preview copying, pending-queue restart, imported-history deduplication after queue removal, same-volume G:→H: remount recovery, copy retry with stable item identity, cleanup failure preserving the imported task and original bytes, successful opted-in cleanup deleting only the verified maximum-resolution original after task/history persistence while preserving the numbered thumbnail/preview/HTML sidecars, and periodic-discovery error handling/disposal. The batch queue screenshot suite also passed all eight cases after refreshing the four USB-affected queue baselines.

Final validation passed 421 tests with 3 skipped, with the hardware environment gate enabled. The final Windows release build also passed; this records build completion only. The build was not installed, and signing or release acceptance was not verified.

## Reproduction

From `Apps/Flutter/stitch_app` in PowerShell:

```powershell
$env:USB_DWARF_HARDWARE = '1'
D:\Flutter\bin\flutter.bat test test/usb_dwarf_hardware_test.dart
Remove-Item Env:USB_DWARF_HARDWARE
D:\Flutter\bin\flutter.bat test test/usb_dwarf_safety_test.dart
```

Final full-suite invocation from the same package directory:

```powershell
$env:USB_DWARF_HARDWARE = '1'
D:\Flutter\bin\flutter.bat test --no-pub
Remove-Item Env:USB_DWARF_HARDWARE
```

The hardware test is skipped unless `USB_DWARF_HARDWARE=1`. `USB_DWARF_ROOT` and `USB_DWARF_NAME` can override the default device path and panorama folder. Test photos and local task inputs stay in the ignored `.local` evidence directory and are not included in Git.

Full JSON report: `.local/usb-dwarf-hardware-20261029/run-2026-10-29T18-14-25.184773Z-2d04bf82/usb-dwarf-hardware-report.json`.
