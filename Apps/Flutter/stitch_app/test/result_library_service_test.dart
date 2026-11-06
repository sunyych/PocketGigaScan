import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/export_fingerprint.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/result_library_service.dart';
import 'package:stitch_app/services/task_record_service.dart';
import 'package:stitch_app/services/task_repository.dart';

class _MemoryRepository extends TaskRepository {
  _MemoryRepository() : super(rootDirectory: Directory.systemTemp);

  final records = <String, StitchTask>{};
  bool failNextSave = false;

  @override
  Future<StitchTask?> loadById(String id) async => records[id];

  @override
  Future<void> save(StitchTask task) async {
    if (failNextSave) {
      failNextSave = false;
      throw const FileSystemException('record write rejected');
    }
    records[task.id] = task;
  }
}

class _ExportApi implements JobApi {
  _ExportApi({this.failExport = false, this.failFirstPoll = false});

  final bool failExport;
  final bool failFirstPoll;
  int statusCalls = 0;
  int exportCalls = 0;
  int startCalls = 0;
  int cancelCalls = 0;
  bool cancelled = false;
  String? requestedJobId;
  String? destination;

  @override
  bool get isAvailable => true;
  @override
  String? get unavailableReason => null;

  @override
  Future<Map<String, Object?>> status(String jobId) async {
    statusCalls++;
    if (exportCalls == 0) {
      requestedJobId = jobId;
      return {'ok': true, 'state': 'completed', 'operation': 'render'};
    }
    if (cancelled) {
      return {
        'ok': true,
        'state': 'cancelled',
        'operation': 'export',
        'exportDestination': destination,
      };
    }
    if (failFirstPoll && statusCalls == 2) {
      throw const FileSystemException('temporary status channel failure');
    }
    if (failFirstPoll && statusCalls == 3) {
      return {
        'ok': true,
        'state': 'running',
        'operation': 'export',
        'exportDestination': destination,
        'progress': 0.6,
      };
    }
    if (failExport) {
      return {
        'ok': true,
        'state': 'failed',
        'operation': 'export',
        'exportDestination': destination,
        'error': {'code': 'EXPORT_FAILED', 'message': 'fixture failure'},
      };
    }
    if (statusCalls == 2) {
      return {
        'ok': true,
        'state': 'running',
        'operation': 'export',
        'exportDestination': destination,
        'progress': 0.6,
      };
    }
    await File(destination!).writeAsBytes([1, 2, 3, 4]);
    return {
      'ok': true,
      'state': 'completed',
      'operation': 'export',
      'exportDestination': destination,
      'progress': 1,
    };
  }

  @override
  Future<Map<String, Object?>> export(String jobId, String path) async {
    exportCalls++;
    requestedJobId = jobId;
    destination = path;
    if (await File(path).exists()) {
      throw const NativeJobException(
        'destination exists',
        code: 'OUTPUT_EXISTS',
      );
    }
    return {
      'ok': true,
      'state': 'running',
      'operation': 'export',
      'exportDestination': path,
    };
  }

  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async {
    startCalls++;
    throw StateError('result export must not start a render');
  }

  @override
  Future<Map<String, Object?>> pause(String jobId) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, Object?>> resume(String jobId) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, Object?>> cancel(String jobId) async {
    cancelCalls++;
    cancelled = true;
    return {
      'ok': true,
      'state': 'pausing',
      'operation': 'export',
      'exportDestination': destination,
    };
  }

  @override
  Future<Map<String, Object?>> capabilities() async => const {};
  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) async => const {};
}

StitchTask _task({
  required String id,
  required String sourceDirectory,
  required String outputDirectory,
  String? exportPath,
  String? publishedExportPath,
  String? displayName,
  String? nativeJobId,
  ExportFileFingerprint? exportFingerprint,
}) => StitchTask(
  id: id,
  createdAt: DateTime.utc(2026),
  sourceDirectory: sourceDirectory,
  outputDirectory: outputDirectory,
  photos: const [],
  grid: const GridOptions(),
  horizontalFovDegrees: 45,
  memoryBudgetMiB: 512,
  workers: 2,
  phase: StitchPhase.completed,
  exportPath: exportPath,
  publishedExportPath: publishedExportPath,
  displayName: displayName,
  nativeJobId: nativeJobId,
  exportFingerprint: exportFingerprint,
);

Future<Directory> _tempDirectory(String prefix) =>
    Directory.systemTemp.createTemp('result-library-$prefix-');

Future<StitchTask> _seedFileTask(
  Directory temp, {
  String id = 'memory-task',
  String baseName = 'panorama',
  List<int> contents = const [1, 2, 3],
}) async {
  final sourceDirectory = Directory(p.join(temp.path, 'input'));
  final outputDirectory = Directory(p.join(temp.path, 'render'));
  await sourceDirectory.create();
  await outputDirectory.create();
  final file = File(p.join(temp.path, '$baseName.png'));
  await file.writeAsBytes(contents);
  final repository = TaskRepository(rootDirectory: temp);
  final fingerprint = await repository.fingerprintFile(file.path);
  return _task(
    id: id,
    sourceDirectory: sourceDirectory.path,
    outputDirectory: outputDirectory.path,
    exportPath: file.path,
    exportFingerprint: fingerprint,
  );
}

void main() {
  test('display name round-trips and legacy result naming stays path-free', () {
    final task = _task(
      id: 'legacy',
      sourceDirectory: r'C:\scans\South Hall',
      outputDirectory: r'C:\render\legacy',
      exportPath: r'C:\exports\old-name.tif',
    );
    expect(ResultLibraryService.resultName(task), 'old-name');
    final named = task.copyWith(displayName: 'Lobby');
    expect(
      ResultLibraryService.resultName(StitchTask.fromJson(named.toJson())),
      'Lobby',
    );
    final older = Map<String, Object?>.from(task.toJson())
      ..remove('displayName');
    expect(StitchTask.fromJson(older).displayName, isNull);
  });

  test(
    'rename moves the real output and persists viewer path fingerprint',
    () async {
      final temp = await _tempDirectory('rename');
      addTearDown(() => temp.delete(recursive: true));
      final taskId = '${DateTime.now().microsecondsSinceEpoch}-abcdef12';
      final sourceDirectory = Directory(p.join(temp.path, 'input'));
      final outputDirectory = Directory(p.join(temp.path, 'render'));
      await sourceDirectory.create();
      await outputDirectory.create();
      final original = File(p.join(temp.path, 'first.png'));
      await original.writeAsBytes([7, 8, 9, 10]);
      final repository = TaskRepository(
        rootDirectory: Directory(p.join(temp.path, 'task-records')),
      );
      final task = _task(
        id: taskId,
        sourceDirectory: sourceDirectory.path,
        outputDirectory: outputDirectory.path,
        exportPath: original.path,
        exportFingerprint: await repository.fingerprintFile(original.path),
      );
      await repository.save(task);

      final updated = await ResultLibraryService(
        repository: repository,
      ).renameResult(task, 'renamed');

      expect(updated.exportPath, p.join(temp.path, 'renamed.png'));
      expect(await File(updated.exportPath!).readAsBytes(), [7, 8, 9, 10]);
      expect(await original.exists(), isFalse);
      final loaded = (await repository.loadById(taskId))!;
      expect(loaded.displayName, 'renamed');
      expect(
        (await repository.fingerprintFile(loaded.exportPath!))?.toJson(),
        loaded.exportFingerprint?.toJson(),
      );
      final viewerRecord = await TaskRecordService(
        repository,
      ).loadRecord(taskId);
      final outputs = viewerRecord!.record['outputs'] as Map<String, Object?>;
      expect(outputs['exportPath'], loaded.exportPath);
      expect(outputs['exportFingerprint'], loaded.exportFingerprint!.toJson());
      expect(
        viewerRecord.record['identity'],
        TaskRecordService.identityForTask(loaded),
      );
      expect(outputs['renderDirectory'], loaded.outputDirectory);
    },
  );

  test('rename collision does not replace either file', () async {
    final temp = await _tempDirectory('collision');
    addTearDown(() => temp.delete(recursive: true));
    final task = await _seedFileTask(temp);
    final collision = File(p.join(temp.path, 'taken.png'));
    await collision.writeAsBytes([88, 99]);
    final repository = _MemoryRepository()..records[task.id] = task;

    await expectLater(
      ResultLibraryService(repository: repository).renameResult(task, 'taken'),
      throwsA(isA<ResultLibraryException>()),
    );
    expect(await File(task.exportPath!).readAsBytes(), [1, 2, 3]);
    expect(await collision.readAsBytes(), [88, 99]);
  });

  test(
    'case-only rename rollback restores the original Windows filename',
    () async {
      final temp = await _tempDirectory('case-only-rollback');
      addTearDown(() => temp.delete(recursive: true));
      final task = await _seedFileTask(temp, baseName: 'Panorama');
      final repository = _MemoryRepository()
        ..records[task.id] = task
        ..failNextSave = true;

      await expectLater(
        ResultLibraryService(
          repository: repository,
        ).renameResult(task, 'panorama'),
        throwsA(isA<FileSystemException>()),
      );

      final files = await temp
          .list()
          .where((entity) => entity is File)
          .map((entity) => p.basename(entity.path))
          .toList();
      expect(files, ['Panorama.png']);
      expect(await File(task.exportPath!).readAsBytes(), [1, 2, 3]);
    },
    skip: !Platform.isWindows,
  );

  test('rename rejects Windows invalid and reserved names', () async {
    final temp = await _tempDirectory('invalid-name');
    addTearDown(() => temp.delete(recursive: true));
    final task = await _seedFileTask(temp);
    final repository = _MemoryRepository()..records[task.id] = task;
    final service = ResultLibraryService(repository: repository);

    for (final name in ['', r'bad\name', 'trailing.', 'CON', 'LPT1.txt']) {
      await expectLater(
        service.renameResult(task, name),
        throwsA(isA<ResultLibraryException>()),
      );
    }
    expect(await File(task.exportPath!).exists(), isTrue);
  });

  test('export rejects path traversal stored in a display name', () async {
    final temp = await _tempDirectory('unsafe-display-name');
    addTearDown(() => temp.delete(recursive: true));
    final seeded = await _seedFileTask(temp);
    final task = seeded.copyWith(displayName: '../escape');
    final repository = _MemoryRepository()..records[task.id] = task;
    final destination = Directory(p.join(temp.path, 'exports'))..createSync();

    await expectLater(
      ResultLibraryService(
        repository: repository,
      ).exportResultToDirectory(task, destination.path),
      throwsA(isA<ResultLibraryException>()),
    );
    expect(await File(p.join(temp.path, 'escape.png')).exists(), isFalse);
    expect(await destination.list().isEmpty, isTrue);
  });

  test('metadata write failure rolls back copy and preserves source', () async {
    final temp = await _tempDirectory('rollback');
    addTearDown(() => temp.delete(recursive: true));
    final task = await _seedFileTask(temp);
    final repository = _MemoryRepository()
      ..records[task.id] = task
      ..failNextSave = true;

    await expectLater(
      ResultLibraryService(repository: repository).renameResult(task, 'new'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File(task.exportPath!).readAsBytes(), [1, 2, 3]);
    expect(await File(p.join(temp.path, 'new.png')).exists(), isFalse);
  });

  test(
    'export copies without deleting source and chooses a collision-free name',
    () async {
      final temp = await _tempDirectory('copy');
      addTearDown(() => temp.delete(recursive: true));
      final task = await _seedFileTask(temp);
      final destination = Directory(p.join(temp.path, 'exports'));
      await destination.create();
      final occupied = File(p.join(destination.path, 'panorama.png'));
      await occupied.writeAsBytes([55]);
      final repository = _MemoryRepository()..records[task.id] = task;

      final copied = await ResultLibraryService(
        repository: repository,
      ).exportResultToDirectory(task, destination.path);

      expect(p.basename(copied.exportPath!), 'panorama (2).png');
      expect(await File(copied.exportPath!).readAsBytes(), [1, 2, 3]);
      expect(await File(task.exportPath!).exists(), isTrue);
      expect(await occupied.readAsBytes(), [55]);
      expect(copied.exportDirectory, await destination.resolveSymbolicLinks());
      expect(copied.publishedExportPath, copied.exportPath);
      expect(
        copied.exportFingerprint?.toJson(),
        (await repository.fingerprintFile(copied.exportPath!))?.toJson(),
      );
    },
  );

  test('large result copy streams bytes and reports progress', () async {
    final temp = await _tempDirectory('large-copy');
    addTearDown(() => temp.delete(recursive: true));
    final bytes = List<int>.filled(1024 * 1024, 31);
    final source = File(p.join(temp.path, 'large.png'));
    final sink = source.openWrite();
    for (var chunk = 0; chunk < 16; chunk++) {
      sink.add(bytes);
    }
    await sink.close();
    final sourceDirectory = Directory(p.join(temp.path, 'input'))..createSync();
    final outputDirectory = Directory(p.join(temp.path, 'render'))
      ..createSync();
    final task = _task(
      id: 'large-copy-task',
      sourceDirectory: sourceDirectory.path,
      outputDirectory: outputDirectory.path,
      exportPath: source.path,
      exportFingerprint: await TaskRepository(
        rootDirectory: temp,
      ).fingerprintFile(source.path),
    );
    final targetDirectory = Directory(p.join(temp.path, 'exports'))
      ..createSync();
    final repository = _MemoryRepository()..records[task.id] = task;
    final progress = <double>[];

    final copied = await ResultLibraryService(repository: repository)
        .exportResultToDirectory(
          task,
          targetDirectory.path,
          onProgress: progress.add,
        );

    expect(await File(copied.exportPath!).length(), 16 * 1024 * 1024);
    expect(await source.exists(), isTrue);
    expect(progress, isNotEmpty);
    expect(progress.last, 1);
  });

  test(
    'missing output is restored by asynchronous native export only',
    () async {
      final temp = await _tempDirectory('native-export');
      addTearDown(() => temp.delete(recursive: true));
      final sourceDirectory = Directory(p.join(temp.path, 'input'))
        ..createSync();
      final outputDirectory = Directory(p.join(temp.path, 'render'))
        ..createSync();
      await File(p.join(outputDirectory.path, 'level-0.png')).writeAsBytes([1]);
      final task = _task(
        id: 'native-export-task',
        sourceDirectory: sourceDirectory.path,
        outputDirectory: outputDirectory.path,
      );
      final repository = _MemoryRepository()..records[task.id] = task;
      final api = _ExportApi();
      final exportProgress = <double>[];

      final restored =
          await ResultLibraryService(
            repository: repository,
            api: api,
            nativePollInterval: Duration.zero,
          ).exportResultToDirectory(
            task,
            p.join(temp.path, 'exports'),
            onProgress: exportProgress.add,
          );

      expect(api.requestedJobId, outputDirectory.path);
      expect(api.exportCalls, 1);
      expect(api.startCalls, 0);
      expect(await File(restored.exportPath!).readAsBytes(), [1, 2, 3, 4]);
      expect(restored.phase, StitchPhase.completed);
      expect(restored.exportCheckpointPath, isNull);
      expect(exportProgress, contains(0.6));
    },
  );

  test(
    'native export failure restores completed task without fake output',
    () async {
      final temp = await _tempDirectory('native-failure');
      addTearDown(() => temp.delete(recursive: true));
      final sourceDirectory = Directory(p.join(temp.path, 'input'))
        ..createSync();
      final outputDirectory = Directory(p.join(temp.path, 'render'))
        ..createSync();
      final task = _task(
        id: 'native-failure-task',
        sourceDirectory: sourceDirectory.path,
        outputDirectory: outputDirectory.path,
      );
      final repository = _MemoryRepository()..records[task.id] = task;
      final api = _ExportApi(failExport: true);

      await expectLater(
        ResultLibraryService(
          repository: repository,
          api: api,
          nativePollInterval: Duration.zero,
        ).exportResultToDirectory(task, p.join(temp.path, 'exports')),
        throwsA(isA<ResultLibraryException>()),
      );
      final restored = repository.records[task.id]!;
      expect(restored.phase, StitchPhase.completed);
      expect(restored.exportPath, isNull);
      expect(restored.exportCheckpointPath, isNull);
      expect(restored.error, contains('fixture failure'));
      expect(api.startCalls, 0);
      expect(
        await Directory(p.join(temp.path, 'exports')).list().isEmpty,
        isTrue,
      );
    },
  );

  test(
    'status failure cancels the matching native export and restores task',
    () async {
      final temp = await _tempDirectory('native-poll-failure');
      addTearDown(() => temp.delete(recursive: true));
      final sourceDirectory = Directory(p.join(temp.path, 'input'))
        ..createSync();
      final outputDirectory = Directory(p.join(temp.path, 'render'))
        ..createSync();
      final task = _task(
        id: 'native-poll-failure-task',
        sourceDirectory: sourceDirectory.path,
        outputDirectory: outputDirectory.path,
      );
      final repository = _MemoryRepository()..records[task.id] = task;
      final api = _ExportApi(failFirstPoll: true);

      await expectLater(
        ResultLibraryService(
          repository: repository,
          api: api,
          nativePollInterval: Duration.zero,
        ).exportResultToDirectory(task, p.join(temp.path, 'exports')),
        throwsA(isA<FileSystemException>()),
      );
      expect(api.cancelCalls, 1);
      expect(repository.records[task.id]!.phase, StitchPhase.completed);
      expect(repository.records[task.id]!.exportCheckpointPath, isNull);
    },
  );

  test('busy and stale tasks are rejected before file operations', () async {
    final temp = await _tempDirectory('busy');
    addTearDown(() => temp.delete(recursive: true));
    final task = await _seedFileTask(temp);
    final repository = _MemoryRepository()..records[task.id] = task;
    final service = ResultLibraryService(
      repository: repository,
      isTaskBusy: (_) => true,
    );

    await expectLater(
      service.renameResult(task, 'busy'),
      throwsA(isA<ResultLibraryException>()),
    );
    expect(await File(task.exportPath!).exists(), isTrue);
  });
}
