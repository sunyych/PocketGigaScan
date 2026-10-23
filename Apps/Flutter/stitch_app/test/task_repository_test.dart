import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
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

  test(
    'save and reload preserve a non-default registration threshold',
    () async {
      final saved = task(
        '123459-abcd04',
      ).copyWith(maxEdgeReprojectionRmsPixels: 13);

      await repository.save(saved);

      expect(
        (await repository.loadById(saved.id))?.maxEdgeReprojectionRmsPixels,
        13,
      );
      expect(
        (await repository.loadAll()).single.maxEdgeReprojectionRmsPixels,
        13,
      );
    },
  );

  test(
    'duplicate new run preserves registration repair offer and inputs',
    () async {
      final photoFile = File(p.join(temp.path, 'shared-source.jpg'));
      final photoBytes = [1, 2, 3, 4];
      await photoFile.writeAsBytes(photoBytes);
      final photo = ImportedPhoto(
        originalName: 'shared-source.jpg',
        storedPath: photoFile.path,
        sha256: sha256.convert(photoBytes).toString(),
        width: 10,
        height: 8,
        originalOrder: 0,
      );
      final grid = const GridOptions(
        mode: GridMode.sequence,
        rows: 1,
        columns: 1,
      );
      final original = task('123459-abcd05').copyWith(
        photos: [photo],
        grid: grid,
        phase: StitchPhase.failed,
        registrationRepairOffered: true,
        autoGridOverlap: false,
        maxEdgeReprojectionRmsPixels: 18,
      );
      await repository.save(original);

      final loadedOriginal = await repository.loadById(original.id);
      expect(loadedOriginal?.registrationRepairOffered, isTrue);
      final duplicate = await repository.duplicateForNewRun(loadedOriginal!);
      final loadedDuplicate = await repository.loadById(duplicate.id);

      expect(duplicate.id, isNot(original.id));
      expect(duplicate.outputDirectory, isNot(original.outputDirectory));
      expect(duplicate.sourceDirectory, original.sourceDirectory);
      expect(duplicate.photos, hasLength(1));
      expect(duplicate.photos.single, same(loadedOriginal.photos.single));
      expect(duplicate.photos.single.storedPath, photo.storedPath);
      expect(duplicate.photos.single.sha256, photo.sha256);
      expect(duplicate.grid.toJson(), grid.toJson());
      expect(duplicate.phase, StitchPhase.imported);
      expect(duplicate.registrationRepairOffered, isTrue);
      expect(duplicate.autoGridOverlap, isFalse);
      expect(duplicate.maxEdgeReprojectionRmsPixels, 18);
      expect(loadedDuplicate?.registrationRepairOffered, isTrue);
      expect(loadedDuplicate?.grid.toJson(), grid.toJson());
      expect(
        (await repository.loadById(original.id))?.phase,
        StitchPhase.failed,
      );
      expect(
        (await repository.loadById(original.id))?.grid.toJson(),
        grid.toJson(),
      );
    },
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
