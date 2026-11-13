# Functional coverage

This matrix maps user-visible behavior to its strongest current automated evidence. A listed test is evidence for the scenarios it asserts, not a claim that every branch is covered. The unit/widget suite does not establish native-device compatibility or release acceptance.

Run from this directory:

```powershell
flutter test --coverage --concurrency=1
python tool/report_flutter_coverage.py coverage/lcov.info
```

The report counts only executable lines recorded in Flutter's LCOV file (`DA` records with a positive hit count). It does not invent lines or infer coverage from test names. `--minimum PERCENT` can be used for a locally chosen threshold; CI reports the measured result without claiming complete coverage.

| App domain / user flow | Automated evidence | Remaining acceptance boundary |
| --- | --- | --- |
| Import photos and folders | `import_workflow_test.dart`, `photo_importer_test.dart`, `batch_folder_importer_test.dart` | OS file chooser and removable-media permissions need platform checks |
| Batch queue lifecycle and restart | `batch_queue_controller_test.dart`, `batch_queue_recovery_model_test.dart`, `batch_queue_repository_test.dart`, `batch_queue_task_navigation_test.dart` | Long-running native work and process-kill recovery need device/runtime acceptance |
| Task records, cleanup, and deletion safety | `task_repository_test.dart`, `task_repository_tombstone_test.dart`, `task_deletion_selection_test.dart`, `task_deletion_widget_test.dart` | Filesystem permission behavior differs across user devices |
| Panorama result gallery and export | `result_library_service_test.dart`, `batch_result_gallery_test.dart`, `export_format_functional_test.dart`, `exported_image_viewer_test.dart`, `output_source_locator_test.dart` | Validate actual native output and destination media on supported OSes |
| Settings, memory and performance | `settings_test.dart`, `settings_export_functional_test.dart`, `memory_budget_policy_test.dart`, `memory_budget_settings_test.dart`, `performance_options_test.dart`, `scene_options_persistence_test.dart` | Performance limits need representative camera sets and hardware |
| Grid and registration diagnostics | `grid_options_test.dart`, `overlap_result_test.dart`, `registration_issues_test.dart`, `scene_options_persistence_test.dart`, `scene_model_service_test.dart`, `scene_model_dialog_recovery_test.dart` | Registration quality requires real captures and native engine output |
| DWARF USB discovery and downloads | `usb_dwarf_*_test.dart`, `dwarf_*_test.dart`, `device_network_service_test.dart` | Physical camera, USB host behavior, Wi-Fi and firmware compatibility require hardware |
| Mobile runtime, storage and power | `mobile_runtime_service_test.dart`, `mobile_storage_service_test.dart`, `power_service_test.dart`, `lifecycle_widget_test.dart` | Actual Android/iOS permissions, wakelock and background lifecycle need signed device builds |
| Over-the-air update safety | `ota_update_service_test.dart` | Signed release installation and upgrade behavior still require platform/package acceptance |
| Localization, accessibility and layout | `localization_test.dart`, `localized_text_alignment_test.dart`, `large_text_visual_test.dart`, screenshot/golden tests | Goldens cover controlled renderers; verify native fonts, screen readers and physical displays |
| Platform plugin integration | `platform_file_dialogs_test.dart`, import tests | Native plugin channels need per-platform integration/device checks |
| Release packaging and signing | Workflow/build scripts, outside Flutter line coverage | Signed artifacts, installation, upgrades, and store/OS acceptance remain separate gates |

## Coverage boundaries

- Flutter tests exercise Dart behavior with fakes and temporary files. Fake native job APIs do not verify stitching accuracy, throughput, crash behavior, or FFI ABI correctness.
- Hardware-dependent acceptance includes physical DWARF discovery/download, USB and network reliability, representative image stitching, export integrity, mobile permission prompts, wakelock/background behavior, and sustained memory/thermal behavior.
- Platform signing and packaged-install/update flows are not represented by `flutter test --coverage`.
- Review this matrix when tests or user-visible flows change; coverage percentage alone does not indicate whether critical failure and recovery behavior is tested.
