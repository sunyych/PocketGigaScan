import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/services/power_service.dart';

void main() {
  test('supported Windows and Android runners share the production identity', () async {
    const appId = 'com.lumiaiq.pocketgigascan';
    final android = await _readAppFile('android/app/build.gradle.kts');
    final windows = await _readAppFile('windows/runner/main.cpp');
    final androidActivity = await _readAppFile(
      'android/app/src/main/kotlin/com/lumiaiq/pocketgigascan/MainActivity.kt',
    );

    expect(android, contains('namespace = "$appId"'));
    expect(android, contains('applicationId = "$appId"'));
    expect(windows, contains('SetCurrentProcessExplicitAppUserModelID(L"$appId")'));
    for (final channel in const ['power', 'storage', 'runtime']) {
      expect(
        androidActivity,
        contains('"$appId/$channel"'),
        reason: 'Android channel $channel must use the product identity.',
      );
    }
  });

  test('power channel uses the production application identity', () {
    expect(
      PlatformPowerGate.channelName,
      'com.lumiaiq.pocketgigascan/power',
    );
  });
}

Future<String> _readAppFile(String relativePath) async {
  for (final path in [
    relativePath,
    'stitch_app/$relativePath',
    'Apps/Flutter/stitch_app/$relativePath',
  ]) {
    final file = File(path);
    if (await file.exists()) return file.readAsString();
  }
  throw FileSystemException('PocketGigaScan app source was not found', relativePath);
}
