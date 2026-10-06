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
  Directory oldProductionRoot() =>
      Directory('${temporary.path}/Roaming/com.lumia/PocketGigaScan');

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

  test(
    'preserves tasks from the previous com.lumia PocketGigaScan root',
    () async {
      final priorTasks = Directory(
        '${oldProductionRoot().path}/LumiaStitch/tasks',
      )..createSync(recursive: true);
      final priorRecord = File('${priorTasks.path}/older-task/task.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"task":"prior-production-root"}');
      final currentTasks = Directory('${currentRoot().path}/LumiaStitch/tasks')
        ..createSync(recursive: true);
      final currentRecord = File('${currentTasks.path}/new-task/task.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"task":"new-root"}');

      final selected = await legacyCompatibleSupportDirectory(
        platformSupportRoot: currentRoot(),
        dataFolder: 'tasks',
        isWindows: true,
        environment: environment(),
      );

      expect(p.equals(selected.path, priorTasks.path), isTrue);
      expect(await priorRecord.readAsString(), '{"task":"prior-production-root"}');
      expect(await currentRecord.readAsString(), '{"task":"new-root"}');
    },
  );

  test('keeps the established legacy path priority when both legacy roots exist', () async {
    final establishedTasks = Directory('${oldRoot().path}/LumiaStitch/tasks')
      ..createSync(recursive: true);
    final priorTasks = Directory(
      '${oldProductionRoot().path}/LumiaStitch/tasks',
    )..createSync(recursive: true);
    File('${establishedTasks.path}/existing.json').writeAsStringSync('established');
    File('${priorTasks.path}/previous.json').writeAsStringSync('previous');

    final selected = await legacyCompatibleSupportDirectory(
      platformSupportRoot: currentRoot(),
      dataFolder: 'tasks',
      isWindows: true,
      environment: environment(),
    );

    expect(p.equals(selected.path, establishedTasks.path), isTrue);
    expect(await File('${establishedTasks.path}/existing.json').readAsString(), 'established');
    expect(await File('${priorTasks.path}/previous.json').readAsString(), 'previous');
  });

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
