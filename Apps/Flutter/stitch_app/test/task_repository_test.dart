import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/task_repository.dart';

void main() {
  late Directory temp;
  late TaskRepository repository;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('task-record-repo-');
    repository = TaskRepository(
      rootDirectory: Directory(p.join(temp.path, 'tasks')),
    );
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  StitchTask task(String id) => StitchTask(
    id: id,
    createdAt: DateTime.utc(2026, 10, 6),
    sourceDirectory: p.join(temp.path, 'sources'),
    outputDirectory: p.join(temp.path, 'output-$id'),
    photos: const [],
    grid: const GridOptions(),
    horizontalFovDegrees: 45,
    memoryBudgetMiB: 128,
    workers: 2,
    phase: StitchPhase.imported,
  );

  test('reads schema v1 and atomically upgrades it on the next save', () async {
    const id = '123456-abcd01';
    final dir = await repository.directoryFor(id);
    await dir.create(recursive: true);
    final v1 = task(id).toJson();
    await File(p.join(dir.path, 'task.json')).writeAsString(jsonEncode(v1));

    expect((await repository.loadById(id))?.id, id);
    await repository.save(task(id).copyWith(phase: StitchPhase.completed));
    final decoded =
        jsonDecode(await File(p.join(dir.path, 'task.json')).readAsString())
            as Map<String, Object?>;
    expect(decoded['schemaVersion'], 2);
    expect(decoded['phase'], 'completed');
    expect(decoded['record'], isA<Map>());
  });

  test(
    'malformed task source remains untouched when record update fails',
    () async {
      const id = '123457-abcd02';
      final dir = await repository.directoryFor(id);
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, 'task.json'));
      const malformed = '{ broken task evidence';
      await file.writeAsString(malformed);

      await expectLater(
        repository.writeRecord(id, const {}),
        throwsA(anything),
      );

      expect(await file.readAsString(), malformed);
    },
  );

  test(
    'removal deletes task master metadata but preserves source and export',
    () async {
      const id = '123458-abcd03';
      final source = File(p.join(temp.path, 'original.jpg'))
        ..writeAsBytesSync([1, 2, 3]);
      final output = File(p.join(temp.path, 'published.png'))
        ..writeAsBytesSync([4, 5, 6]);
      final taskDir = await repository.directoryFor(id);
      await repository.save(task(id));
      final scratch = File(p.join(taskDir.path, 'record.tmp-orphan'))
        ..writeAsStringSync('x');

      await repository.removeTaskRecord(id);

      expect(await source.readAsBytes(), [1, 2, 3]);
      expect(await output.readAsBytes(), [4, 5, 6]);
      expect(await File(p.join(taskDir.path, 'task.json')).exists(), isFalse);
      expect(await scratch.exists(), isFalse);
      expect(await File(p.join(taskDir.path, '.removed')).exists(), isTrue);
    },
  );
}
