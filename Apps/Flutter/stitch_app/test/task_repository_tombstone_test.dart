import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/task_repository.dart';

void main() {
  late Directory temporary;
  late Directory root;
  late TaskRepository repository;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('task-tombstone-test-');
    root = Directory('${temporary.path}${Platform.pathSeparator}tasks');
    repository = TaskRepository(rootDirectory: root);
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'metadata tombstone blocks late saves and preserves all task files',
    () async {
      const id = '123456-abcd01';
      final source = Directory(
        '${temporary.path}${Platform.pathSeparator}source',
      )..createSync();
      final original = File(
        '${source.path}${Platform.pathSeparator}original.jpg',
      )..writeAsBytesSync([1, 2, 3, 4]);
      final taskDirectory = await repository.directoryFor(id);
      final output = Directory(
        '${taskDirectory.path}${Platform.pathSeparator}output',
      )..createSync(recursive: true);
      final rendered = File('${output.path}${Platform.pathSeparator}render.png')
        ..writeAsBytesSync([5, 6, 7]);
      final task = StitchTask(
        id: id,
        createdAt: DateTime.utc(2026, 10, 4),
        sourceDirectory: source.path,
        outputDirectory: output.path,
        photos: const [],
        grid: const GridOptions(),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 128,
        workers: 1,
        phase: StitchPhase.imported,
      );

      await repository.save(task);
      await repository.removeTaskRecord(id);
      await repository.save(task.copyWith(phase: StitchPhase.completed));
      await TaskRepository(rootDirectory: root).save(task);

      expect(await repository.loadById(id), isNull);
      expect(await repository.loadAll(), isEmpty);
      expect(
        await File(
          '${taskDirectory.path}${Platform.pathSeparator}task.json',
        ).exists(),
        isFalse,
      );
      expect(
        await File(
          '${taskDirectory.path}${Platform.pathSeparator}.removed',
        ).exists(),
        isTrue,
      );
      expect(await original.readAsBytes(), [1, 2, 3, 4]);
      expect(await rendered.readAsBytes(), [5, 6, 7]);
    },
  );

  test('records and reads a lightweight output fingerprint', () async {
    const id = '123457-abcd02';
    final taskDirectory = await repository.directoryFor(id);
    await taskDirectory.create(recursive: true);
    final image = File(
      '${taskDirectory.path}${Platform.pathSeparator}image.jxl',
    )..writeAsBytesSync([9, 8, 7]);
    final fingerprint = await repository.fingerprintFile(image.path);

    expect(fingerprint?.sizeBytes, 3);
    expect(fingerprint?.modifiedAtMicros, greaterThan(0));
  });

  test('new-run clone preserves local texture warp preference', () async {
    final source = Directory('${temporary.path}/source')..createSync();
    final sourceImage = File('${source.path}/image.jpg')
      ..writeAsBytesSync([1, 2, 3, 4]);
    final task = StitchTask(
      id: '123458-abcd03',
      createdAt: DateTime.utc(2026, 10, 4),
      sourceDirectory: source.path,
      outputDirectory: '${temporary.path}/output',
      photos: [
        ImportedPhoto(
          originalName: 'image.jpg',
          storedPath: sourceImage.path,
          sha256: sha256.convert([1, 2, 3, 4]).toString(),
          width: 100,
          height: 80,
          originalOrder: 0,
        ),
      ],
      grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 128,
      workers: 1,
      phase: StitchPhase.failed,
      localTextureWarp: false,
    );

    final cloned = await repository.duplicateForNewRun(task);

    expect(cloned.localTextureWarp, isFalse);
    expect(StitchTask.fromJson(cloned.toJson()).localTextureWarp, isFalse);
    expect(cloned.autoExportOnCompletion, isTrue);
    expect(StitchTask.fromJson(cloned.toJson()).autoExportOnCompletion, isTrue);
  });
}
