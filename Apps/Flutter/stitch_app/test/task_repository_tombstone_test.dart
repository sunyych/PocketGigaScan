import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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

  test('constructs a new task folder beneath the canonical root', () async {
    const id = '123459-abcd04';
    final canonicalRoot = await root
        .create(recursive: true)
        .then((_) => root.resolveSymbolicLinks());

    final directory = await repository.directoryFor(id);

    expect(directory.path, p.join(canonicalRoot, id));
    expect(p.isWithin(canonicalRoot, directory.path), isTrue);
  });

  test('resolves an aliased root before creating and saving a task', () async {
    const id = '123461-abcd06';
    final canonicalRoot = Directory(
      '${temporary.path}${Platform.pathSeparator}canonical-tasks',
    )..createSync(recursive: true);
    final rootAlias = Link(
      '${temporary.path}${Platform.pathSeparator}tasks-alias',
    );
    await rootAlias.create(canonicalRoot.path);
    final aliasedRepository = TaskRepository(
      rootDirectory: Directory(rootAlias.path),
    );
    final task = StitchTask(
      id: id,
      createdAt: DateTime.utc(2026, 10, 5),
      sourceDirectory: 'source',
      outputDirectory: 'output',
      photos: const [],
      grid: const GridOptions(),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 128,
      workers: 1,
      phase: StitchPhase.imported,
    );

    await aliasedRepository.save(task);

    final resolvedRoot = await canonicalRoot.resolveSymbolicLinks();
    final directory = await aliasedRepository.directoryFor(id);
    expect(directory.path, p.join(resolvedRoot, id));
    expect(await aliasedRepository.loadById(id), isNotNull);
    expect(await File(p.join(directory.path, 'task.json')).exists(), isTrue);
  });

  test('rejects empty, absolute, and traversal task IDs', () async {
    for (final id in [
      '',
      '..',
      '.. ',
      ' .',
      'id.',
      '../outside',
      r'..\outside',
      p.absolute('${temporary.path}${Platform.pathSeparator}outside'),
    ]) {
      await expectLater(
        repository.directoryFor(id),
        throwsA(isA<FileSystemException>()),
        reason: 'Task ID must stay inside the canonical task root: $id',
      );
    }
  });

  test(
    'rejects an existing task link that resolves outside the root',
    () async {
      const id = '123460-abcd05';
      final outside = Directory(
        '${temporary.path}${Platform.pathSeparator}outside',
      )..createSync(recursive: true);
      final link = Link(p.join(root.path, id));
      await root.create(recursive: true);
      await link.create(outside.path);

      await expectLater(
        repository.directoryFor(id),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

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

  test(
    'cleanup removes verified task copies but keeps originals and tombstone',
    () async {
      const id = '123462-abcd07';
      final taskDirectory = await repository.directoryFor(id);
      final input = Directory(p.join(taskDirectory.path, 'input'))
        ..createSync(recursive: true);
      final output = Directory(p.join(taskDirectory.path, 'render'))
        ..createSync(recursive: true);
      final copiedInput = File(p.join(input.path, '0000.jpg'))
        ..writeAsBytesSync([1, 2, 3, 4]);
      final original = File(p.join(temporary.path, 'original.jpg'))
        ..writeAsBytesSync([1, 2, 3, 4]);
      final tile = File(p.join(output.path, 'tile.png'))
        ..writeAsBytesSync([5, 6, 7]);
      final exportDirectory = Directory(p.join(temporary.path, 'exports'))
        ..createSync();
      final export = File(p.join(exportDirectory.path, 'panorama.png'))
        ..writeAsBytesSync([8, 9, 10]);
      final photo = ImportedPhoto(
        originalName: 'original.jpg',
        storedPath: copiedInput.path,
        sha256: sha256.convert([1, 2, 3, 4]).toString(),
        width: 100,
        height: 80,
        originalOrder: 0,
      );
      final task = StitchTask(
        id: id,
        createdAt: DateTime.utc(2026, 10, 29),
        sourceDirectory: input.path,
        outputDirectory: output.path,
        photos: [photo],
        grid: const GridOptions(),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 128,
        workers: 1,
        phase: StitchPhase.failed,
        exportPath: export.path,
        exportFingerprint: await repository.fingerprintFile(export.path),
      );
      await repository.save(task);

      final result = await repository.removeTaskRecordWithCleanup(
        task,
        deleteOwnedFiles: true,
      );

      expect(result.cleanupComplete, isTrue);
      expect(await copiedInput.exists(), isFalse);
      expect(await tile.exists(), isFalse);
      expect(await export.exists(), isFalse);
      expect(await original.exists(), isTrue);
      expect(
        await File(p.join(taskDirectory.path, '.removed')).exists(),
        isTrue,
      );
      expect(await repository.loadById(id), isNull);
    },
  );

  test('cleanup preserves input copy shared with a new-run clone', () async {
    const id = '123463-abcd08';
    final taskDirectory = await repository.directoryFor(id);
    final input = Directory(p.join(taskDirectory.path, 'input'))
      ..createSync(recursive: true);
    final output = Directory(p.join(taskDirectory.path, 'render'))
      ..createSync(recursive: true);
    final copiedInput = File(p.join(input.path, '0000.jpg'))
      ..writeAsBytesSync([1, 2, 3, 4]);
    final photo = ImportedPhoto(
      originalName: 'original.jpg',
      storedPath: copiedInput.path,
      sha256: sha256.convert([1, 2, 3, 4]).toString(),
      width: 100,
      height: 80,
      originalOrder: 0,
    );
    final task = StitchTask(
      id: id,
      createdAt: DateTime.utc(2026, 10, 29),
      sourceDirectory: input.path,
      outputDirectory: output.path,
      photos: [photo],
      grid: const GridOptions(),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 128,
      workers: 1,
      phase: StitchPhase.failed,
    );
    await repository.save(task);
    final clone = await repository.duplicateForNewRun(task);

    final result = await repository.removeTaskRecordWithCleanup(
      task,
      deleteOwnedFiles: true,
    );

    expect(result.cleanupComplete, isFalse);
    expect(await copiedInput.exists(), isTrue);
    expect(await File(clone.photos.single.storedPath).readAsBytes(), [
      1,
      2,
      3,
      4,
    ]);
    expect(await repository.loadById(clone.id), isNotNull);
    expect(await File(p.join(taskDirectory.path, '.removed')).exists(), isTrue);
  });

  test('cleanup skips a render tree containing an escaping link', () async {
    const id = '123467-abcd12';
    final taskDirectory = await repository.directoryFor(id);
    final output = Directory(p.join(taskDirectory.path, 'render'))
      ..createSync(recursive: true);
    final outside = Directory(p.join(temporary.path, 'outside'))..createSync();
    final outsideFile = File(p.join(outside.path, 'keep.txt'))
      ..writeAsStringSync('keep');
    final link = Link(p.join(output.path, 'linked'));
    try {
      await link.create(outside.path);
    } on Object {
      return;
    }
    final task = StitchTask(
      id: id,
      createdAt: DateTime.utc(2026, 10, 29),
      sourceDirectory: 'external',
      outputDirectory: output.path,
      photos: const [],
      grid: const GridOptions(),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 128,
      workers: 1,
      phase: StitchPhase.failed,
    );
    await repository.save(task);

    final result = await repository.removeTaskRecordWithCleanup(
      task,
      deleteOwnedFiles: true,
    );

    expect(result.cleanupComplete, isFalse);
    expect(await output.exists(), isTrue);
    expect(await outsideFile.readAsString(), 'keep');
    expect(await File(p.join(taskDirectory.path, '.removed')).exists(), isTrue);
  });

  test('cleanup refuses changed exports and URI paths', () async {
    const id = '123464-abcd09';
    final taskDirectory = await repository.directoryFor(id);
    final output = Directory(p.join(taskDirectory.path, 'output'))
      ..createSync(recursive: true);
    final export = File(p.join(temporary.path, 'changed-export.png'))
      ..writeAsBytesSync([1, 2, 3]);
    final staleFingerprint = await repository.fingerprintFile(export.path);
    await export.writeAsBytes([1, 2, 3, 4]);
    final task = StitchTask(
      id: id,
      createdAt: DateTime.utc(2026, 10, 29),
      sourceDirectory: 'external',
      outputDirectory: output.path,
      photos: const [],
      grid: const GridOptions(),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 128,
      workers: 1,
      phase: StitchPhase.failed,
      exportPath: export.path,
      exportFingerprint: staleFingerprint,
    );
    await repository.save(task);

    final result = await repository.removeTaskRecordWithCleanup(
      task,
      deleteOwnedFiles: true,
    );

    expect(result.cleanupComplete, isFalse);
    expect(await export.exists(), isTrue);
    expect(result.failures.join(' '), contains('指纹'));
  });

  test(
    'cleanup reports that a published content URI remains at its destination',
    () async {
      const id = '123468-abcd13';
      final taskDirectory = await repository.directoryFor(id);
      final output = Directory(p.join(taskDirectory.path, 'render'))
        ..createSync(recursive: true);
      final task = StitchTask(
        id: id,
        createdAt: DateTime.utc(2026, 10, 29),
        sourceDirectory: 'external',
        outputDirectory: output.path,
        photos: const [],
        grid: const GridOptions(),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 128,
        workers: 1,
        phase: StitchPhase.completed,
        publishedExportPath: 'content://media/external/images/42',
      );
      await repository.save(task);

      final result = await repository.removeTaskRecordWithCleanup(
        task,
        deleteOwnedFiles: true,
      );

      expect(result.cleanupComplete, isFalse);
      expect(result.failures, contains('已发布的外部副本已保留，请在目标位置删除'));
      expect(await output.exists(), isFalse);
    },
  );

  test(
    'shared export destination does not make distinct task exports shared',
    () async {
      final sharedExportDirectory = Directory(p.join(temporary.path, 'shared'))
        ..createSync();
      const firstId = '123465-abcd10';
      const secondId = '123466-abcd11';
      final firstTaskDirectory = await repository.directoryFor(firstId);
      final secondTaskDirectory = await repository.directoryFor(secondId);
      final firstOutput = Directory(p.join(firstTaskDirectory.path, 'render'))
        ..createSync(recursive: true);
      final secondOutput = Directory(p.join(secondTaskDirectory.path, 'render'))
        ..createSync(recursive: true);
      final firstExport = File(p.join(sharedExportDirectory.path, 'first.png'))
        ..writeAsBytesSync([1, 2, 3]);
      final secondExport = File(
        p.join(sharedExportDirectory.path, 'second.png'),
      )..writeAsBytesSync([4, 5, 6]);
      final first = StitchTask(
        id: firstId,
        createdAt: DateTime.utc(2026, 10, 29),
        sourceDirectory: p.join(temporary.path, 'source-one'),
        outputDirectory: firstOutput.path,
        exportPath: firstExport.path,
        exportDirectory: sharedExportDirectory.path,
        exportFingerprint: await repository.fingerprintFile(firstExport.path),
        photos: const [],
        grid: const GridOptions(),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 128,
        workers: 1,
        phase: StitchPhase.completed,
      );
      final second = StitchTask(
        id: secondId,
        createdAt: DateTime.utc(2026, 10, 29),
        sourceDirectory: p.join(temporary.path, 'source-two'),
        outputDirectory: secondOutput.path,
        exportPath: secondExport.path,
        exportDirectory: sharedExportDirectory.path,
        exportFingerprint: await repository.fingerprintFile(secondExport.path),
        photos: const [],
        grid: const GridOptions(),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 128,
        workers: 1,
        phase: StitchPhase.completed,
      );
      await repository.save(first);
      await repository.save(second);

      final result = await repository.removeTaskRecordWithCleanup(
        first,
        deleteOwnedFiles: true,
      );

      expect(result.cleanupComplete, isTrue);
      expect(await firstExport.exists(), isFalse);
      expect(await secondExport.exists(), isTrue);
      expect(await secondOutput.exists(), isTrue);
    },
  );

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
      maxEdgeReprojectionRmsPixels: 17.5,
    );

    final cloned = await repository.duplicateForNewRun(task);

    expect(cloned.localTextureWarp, isFalse);
    expect(cloned.maxEdgeReprojectionRmsPixels, 17.5);
    expect(
      StitchTask.fromJson(cloned.toJson()).maxEdgeReprojectionRmsPixels,
      17.5,
    );
    expect(StitchTask.fromJson(cloned.toJson()).localTextureWarp, isFalse);
    expect(cloned.autoExportOnCompletion, isTrue);
    expect(StitchTask.fromJson(cloned.toJson()).autoExportOnCompletion, isTrue);
  });
}
