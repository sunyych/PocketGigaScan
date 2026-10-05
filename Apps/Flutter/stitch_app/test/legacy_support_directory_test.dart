import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/services/legacy_support_directory.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('pocket-gigascan-path-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  Directory currentRoot() => Directory('${temporary.path}/current-support');
  Directory oldRoot() =>
      Directory('${temporary.path}/Roaming/com.lumia/Lumia Stitch');

  Map<String, String> environment() => {'APPDATA': '${temporary.path}/Roaming'};

  test('uses and preserves an existing legacy task folder', () async {
    final legacyTasks = Directory('${oldRoot().path}/LumiaStitch/tasks')
      ..createSync(recursive: true);
    final record = File('${legacyTasks.path}/existing-task/task.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"task":"kept"}');

    final selected = await legacyCompatibleSupportDirectory(
      platformSupportRoot: currentRoot(),
      dataFolder: 'tasks',
      isWindows: true,
      environment: environment(),
    );

    expect(p.equals(selected.path, legacyTasks.path), isTrue);
    expect(await record.readAsString(), '{"task":"kept"}');
    expect(await currentRoot().exists(), isFalse);
  });

  test(
    'uses the current support folder when no legacy folder exists',
    () async {
      final currentTasks = Directory('${currentRoot().path}/LumiaStitch/tasks')
        ..createSync(recursive: true);

      final selected = await legacyCompatibleSupportDirectory(
        platformSupportRoot: currentRoot(),
        dataFolder: 'tasks',
        isWindows: true,
        environment: environment(),
      );

      expect(p.equals(selected.path, currentTasks.path), isTrue);
      expect(await oldRoot().exists(), isFalse);
    },
  );

  test(
    'prefers legacy records when both roots exist and preserves both',
    () async {
      final legacyTasks = Directory('${oldRoot().path}/LumiaStitch/tasks')
        ..createSync(recursive: true);
      final currentTasks = Directory('${currentRoot().path}/LumiaStitch/tasks')
        ..createSync(recursive: true);
      final oldRecord = File('${legacyTasks.path}/old.json')
        ..writeAsStringSync('old');
      final currentRecord = File('${currentTasks.path}/new.json')
        ..writeAsStringSync('new');

      final selected = await legacyCompatibleSupportDirectory(
        platformSupportRoot: currentRoot(),
        dataFolder: 'tasks',
        isWindows: true,
        environment: environment(),
      );

      expect(p.equals(selected.path, legacyTasks.path), isTrue);
      expect(await oldRecord.readAsString(), 'old');
      expect(await currentRecord.readAsString(), 'new');
    },
  );

  test(
    'keeps batches beside legacy tasks when only the tasks folder exists',
    () async {
      Directory(
        '${oldRoot().path}/LumiaStitch/tasks',
      ).createSync(recursive: true);

      final selected = await legacyCompatibleSupportDirectory(
        platformSupportRoot: currentRoot(),
        dataFolder: 'batches',
        isWindows: true,
        environment: environment(),
      );

      expect(
        p.equals(selected.path, '${oldRoot().path}/LumiaStitch/batches'),
        isTrue,
      );
      expect(await currentRoot().exists(), isFalse);
    },
  );

  test('ignores the legacy Windows folder on other platforms', () async {
    final legacyTasks = Directory('${oldRoot().path}/LumiaStitch/tasks')
      ..createSync(recursive: true);

    final selected = await legacyCompatibleSupportDirectory(
      platformSupportRoot: currentRoot(),
      dataFolder: 'tasks',
      isWindows: false,
      environment: environment(),
    );

    expect(
      p.equals(selected.path, '${currentRoot().path}/LumiaStitch/tasks'),
      isTrue,
    );
    expect(await legacyTasks.exists(), isTrue);
  });
}
