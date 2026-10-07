import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' as selector;

/// Routes Windows dialogs through Flutter's endorsed Common Item Dialog
/// implementation. Mobile platforms keep using file_picker and their native
/// document providers.
class PlatformFileDialogs {
  PlatformFileDialogs({bool? isWindows})
    : _isWindows = isWindows ?? Platform.isWindows;

  final bool _isWindows;

  Future<List<PlatformFile>?> pickJpegs() async {
    if (!_isWindows) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg'],
        allowMultiple: true,
        withData: false,
        withReadStream: true,
      );
      return result?.files;
    }

    final selected = await _openWindowsJpegs();
    return selected.isEmpty ? null : selected;
  }

  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? confirmButtonText,
  }) {
    if (!_isWindows) {
      return FilePicker.platform.getDirectoryPath(dialogTitle: dialogTitle);
    }
    return _selectWindowsDirectory(confirmButtonText: confirmButtonText);
  }

  static Future<List<PlatformFile>> _openWindowsJpegs() async {
    final selected = await selector.openFiles(
      acceptedTypeGroups: const [
        selector.XTypeGroup(label: 'JPEG', extensions: ['jpg', 'jpeg']),
      ],
    );
    return [
      for (final file in selected)
        PlatformFile(
          name: file.name,
          path: file.path,
          size: await file.length(),
        ),
    ];
  }

  static Future<String?> _selectWindowsDirectory({String? confirmButtonText}) =>
      selector.getDirectoryPath(confirmButtonText: confirmButtonText);
}
