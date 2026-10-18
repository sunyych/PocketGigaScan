import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  final output =
      Platform.environment['INTEGRATION_SCREENSHOT_DIR'] ??
      p.join(
        Directory.current.path,
        '..',
        '..',
        '..',
        '.local',
        'android-stitch-validation-20261005',
        'screenshots',
      );
  await integrationDriver(
    onScreenshot:
        (String name, List<int> image, [Map<String, Object?>? args]) async {
          final directory = Directory(output);
          await directory.create(recursive: true);
          final safeName = name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
          await File(
            p.join(directory.path, '$safeName.png'),
          ).writeAsBytes(image);
          return true;
        },
  );
}
