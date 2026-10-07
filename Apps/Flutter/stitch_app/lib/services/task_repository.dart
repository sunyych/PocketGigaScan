import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/stitch_task.dart';
import '../models/export_fingerprint.dart';
import 'legacy_support_directory.dart';
import 'task_record_service.dart';

class TaskRepository {
  TaskRepository({this.rootDirectory});
  final Directory? rootDirectory;
  TaskRecordService? _recordService;
  static Future<void> _writeTail = Future.value();

  Future<Directory> root() async {
    final directory =
        rootDirectory ??
        await legacyCompatibleSupportDirectory(
          platformSupportRoot: await getApplicationSupportDirectory(),
          dataFolder: 'tasks',
        );
    await directory.create(recursive: true);
    return directory;
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _writeTail.then((_) => action());
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  String createId() {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final suffix = Random.secure()
        .nextInt(0x7fffffff)
        .toRadixString(16)
        .padLeft(8, '0');
    return '$now-$suffix';
  }

  Future<Directory> directoryFor(String id) async {
    final base = await root();
    final resolvedRoot = await base.resolveSymbolicLinks();
    if (id.trim().isEmpty ||
        id != id.trim() ||
        id == '.' ||
        id == '..' ||
        id.endsWith('.') ||
        p.isAbsolute(id) ||
        id.contains('/') ||
        id.contains('\\') ||
        id.contains(':')) {
      throw const FileSystemException('Invalid task directory');
    }
    // Build new children from the canonical root. On Windows, the support
    // directory can be reached through an 8.3 alias while resolveSymbolicLinks
    // returns its long name; mixing those paths makes valid children appear
    // outside the root. Existing children are still resolved below so a
    // junction/symlink that escapes the task root is rejected.
    final directory = Directory(p.join(resolvedRoot, id));
    final resolved = await directory.exists()
        ? await directory.resolveSymbolicLinks()
        : p.normalize(directory.absolute.path);
    if (!p.isWithin(resolvedRoot, resolved)) {
      throw const FileSystemException('Invalid task directory');
    }
    return directory;
  }

  Future<void> save(StitchTask task) async {
    await _serialized(() async {
      final directory = await directoryFor(task.id);
      if (await _isRemoved(directory)) return;
      await directory.create(recursive: true);
      final file = File(p.join(directory.path, 'task.json'));
      Map<String, Object?>? priorRecord;
      if (await file.exists()) {
        try {
          final prior = jsonDecode(await file.readAsString());
          if (prior is Map && prior['record'] is Map) {
            final oldRecord = (prior['record'] as Map).cast<String, Object?>();
            if (TaskRecordService.identityForJson(
                  prior.cast<String, Object?>(),
                ) ==
                TaskRecordService.identityForTask(task)) {
              priorRecord = TaskRecordService.updateRequestedTaskFields(
                task,
                oldRecord,
              );
            }
          }
        } on Object {
          // Preserve the source file on malformed input; a normal save replaces it atomically.
        }
      }
      final recordBuilder = _recordService ??= TaskRecordService(this);
      final record = await recordBuilder.buildRecordForTask(
        task,
        priorRecord ?? TaskRecordService.initialRecord(task),
      );
      final envelope = <String, Object?>{
        ...task.toJson(),
        'schemaVersion': 2,
        'record': record,
      };
      final temp = File('${file.path}.tmp-${createId()}');
      await temp.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(envelope)}\n',
        flush: true,
      );
      await temp.rename(file.path);
    });
  }

  /// Updates only the diagnostic member of the authoritative task.json file.
  /// The task identity is checked under the same serialized write queue as saves.
  Future<void> writeRecord(String id, Map<String, Object?> record) =>
      _serialized(() async {
        if (!RegExp(r'^[0-9]+-[a-f0-9]+$').hasMatch(id)) {
          throw const FileSystemException('Invalid task id');
        }
        final directory = await directoryFor(id);
        if (await _isRemoved(directory)) return;
        final file = File(p.join(directory.path, 'task.json'));
        if (!await file.exists()) return;
        final value = jsonDecode(await file.readAsString());
        if (value is! Map || value['id'] != id) return;
        final envelope = value.cast<String, Object?>();
        final task = StitchTask.fromJson(envelope);
        if (record['identity'] != TaskRecordService.identityForTask(task)) {
          return;
        }
        final recordBuilder = _recordService ??= TaskRecordService(this);
        final updatedRecord = await recordBuilder.buildRecordForTask(
          task,
          TaskRecordService.updateRequestedTaskFields(task, record),
        );
        final updated = <String, Object?>{
          ...envelope,
          'schemaVersion': 2,
          'record': updatedRecord,
        };
        final temp = File('${file.path}.tmp-${createId()}');
        await temp.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(updated)}\n',
          flush: true,
        );
        await temp.rename(file.path);
      });

  Future<bool> _isRemoved(Directory directory) =>
      File(p.join(directory.path, '.removed')).exists();

  Future<bool> isRemoved(String id) async {
    if (!RegExp(r'^[0-9]+-[a-f0-9]+$').hasMatch(id)) return false;
    return _isRemoved(await directoryFor(id));
  }

  /// Removes only the task metadata. Inputs, render tiles and exports remain.
  /// The marker is written first and is retained so a late save cannot restore it.
  Future<void> removeTaskRecord(String id) => _serialized(() async {
    if (!RegExp(r'^[0-9]+-[a-f0-9]+$').hasMatch(id)) {
      throw const FileSystemException('Invalid task id');
    }
    final directory = await directoryFor(id);
    await directory.create(recursive: true);
    final marker = File(p.join(directory.path, '.removed'));
    if (!await marker.exists()) {
      final temporary = File('${marker.path}.tmp-${createId()}');
      await temporary.writeAsString('$id\n', flush: true);
      await temporary.rename(marker.path);
    }
    final record = File(p.join(directory.path, 'task.json'));
    if (await record.exists()) await record.delete();
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File &&
          (p.basename(entry.path).startsWith('task.json.tmp-') ||
              p.basename(entry.path).startsWith('record.tmp-'))) {
        await entry.delete();
      }
    }
  });

  Future<ExportFileFingerprint?> fingerprintFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) return null;
    return ExportFileFingerprint(
      sizeBytes: stat.size,
      modifiedAtMicros: stat.modified.microsecondsSinceEpoch,
    );
  }

  Future<StitchTask?> loadById(String id) async {
    if (!RegExp(r'^[0-9]+-[a-f0-9]+$').hasMatch(id)) return null;
    return _serialized(() async {
      final directory = await directoryFor(id);
      if (await _isRemoved(directory)) return null;
      final file = File(p.join(directory.path, 'task.json'));
      if (!await file.exists()) return null;
      try {
        final value = jsonDecode(await file.readAsString());
        if (value is! Map<String, Object?> ||
            (value['schemaVersion'] != 1 && value['schemaVersion'] != 2) ||
            value['id'] != id) {
          return null;
        }
        return StitchTask.fromJson(value);
      } on Object {
        return null;
      }
    });
  }

  Future<List<StitchTask>> loadAll() async {
    final base = await root();
    final tasks = <StitchTask>[];
    await for (final entity in base.list(followLinks: false)) {
      if (entity is! Directory) continue;
      if (await _isRemoved(entity)) continue;
      final file = File(p.join(entity.path, 'task.json'));
      if (!await file.exists()) continue;
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is! Map<String, Object?> ||
            (json['schemaVersion'] != 1 && json['schemaVersion'] != 2)) {
          continue;
        }
        final loaded = StitchTask.fromJson(json);
        final resumed =
            loaded.phase == StitchPhase.interrupted &&
                loaded.phase != StitchPhase.imported
            ? loaded.copyWith(
                phase: StitchPhase.interrupted,
                pauseReason: '应用未运行期间的原生状态不会自动恢复',
              )
            : loaded;
        tasks.add(resumed);
        if (resumed.phase != loaded.phase ||
            resumed.pauseReason != loaded.pauseReason) {
          await save(resumed);
        }
      } on Object {
        // Keep unreadable task records untouched so local evidence is not destroyed.
      }
    }
    tasks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return tasks;
  }

  Future<Directory> prepareOutput(StitchTask task) async {
    final output = Directory(task.outputDirectory);
    if (await output.exists()) {
      final isEmpty = await output.list(followLinks: false).isEmpty;
      if (!isEmpty) {
        throw const FileSystemException('已有处理目录；请创建新任务，避免覆盖或误恢复旧参数');
      }
    } else {
      await output.create(recursive: true);
    }
    return output;
  }

  Future<StitchTask> duplicateForNewRun(
    StitchTask old, {
    bool autoExportOnCompletion = true,
  }) async {
    final id = createId();
    final directory = await directoryFor(id);
    for (final photo in old.photos) {
      final original = File(photo.storedPath);
      if (!await original.exists()) {
        throw FileSystemException('缺少已导入原片', photo.storedPath);
      }
      final digest = await sha256.bind(original.openRead()).first;
      if (digest.toString() != photo.sha256) {
        throw FileSystemException('原片内容已变化；请重新导入以创建新任务', photo.storedPath);
      }
    }
    final task = StitchTask(
      id: id,
      createdAt: DateTime.now(),
      // Each task points at an immutable app-owned input copy. A new run shares those
      // originals and gets a unique output directory, avoiding redundant large copies.
      sourceDirectory: old.sourceDirectory,
      outputDirectory: p.join(directory.path, 'output'),
      photos: old.photos,
      grid: old.grid,
      horizontalFovDegrees: old.horizontalFovDegrees,
      memoryBudgetMiB: old.memoryBudgetMiB,
      workers: old.workers,
      phase: StitchPhase.imported,
      centralReference: old.centralReference,
      forceGridFallback: old.forceGridFallback,
      autoGridOverlap: old.autoGridOverlap,
      gridHorizontalOverlap: old.gridHorizontalOverlap,
      gridVerticalOverlap: old.gridVerticalOverlap,
      cameraProfileId: old.cameraProfileId,
      cameraCalibrationOverridden: old.cameraCalibrationOverridden,
      performanceOptions: old.performanceOptions.normalized,
      exportFormat: old.exportFormat,
      autoExportOnCompletion: autoExportOnCompletion,
      refineGridNeighbors: old.refineGridNeighbors,
      seamBlendMode: old.seamBlendMode,
      localTextureWarp: old.localTextureWarp,
    );
    await save(task);
    return task;
  }
}
