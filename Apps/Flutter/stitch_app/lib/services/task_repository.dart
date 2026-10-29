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
    await _removeTaskRecord(id);
  });

  /// Removes the record and, when requested, app-owned task files. The durable
  /// tombstone is retained even when cleanup is incomplete so late writes can
  /// never resurrect the task.
  Future<TaskRemovalResult> removeTaskRecordWithCleanup(
    StitchTask task, {
    required bool deleteOwnedFiles,
  }) async {
    if (deleteOwnedFiles) {
      final savedTask = await loadById(task.id);
      final alreadyRemoved = await isRemoved(task.id);
      if (!alreadyRemoved &&
          (savedTask == null ||
              TaskRecordService.identityForTask(savedTask) !=
                  TaskRecordService.identityForTask(task))) {
        throw const FileSystemException('任务记录身份无法验证，已跳过文件清理');
      }
    }
    // Keep the existing virtual method in the path so repository fakes and
    // platform-specific subclasses continue to observe/guard record removal.
    await removeTaskRecord(task.id);
    if (!deleteOwnedFiles) return const TaskRemovalResult();
    try {
      return await _serialized(() => _cleanupOwnedTaskFiles(task));
    } on Object catch (error) {
      return TaskRemovalResult(failures: ['文件清理阶段失败：$error']);
    }
  }

  Future<void> _removeTaskRecord(String id) async {
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
  }

  Future<TaskRemovalResult> _cleanupOwnedTaskFiles(StitchTask task) async {
    final failures = <String>[];
    final taskDirectory = await directoryFor(task.id);
    final canonicalTaskDirectory = await taskDirectory.resolveSymbolicLinks();
    final canonicalRoot = await (await root()).resolveSymbolicLinks();
    if (!p.isWithin(canonicalRoot, canonicalTaskDirectory)) {
      return const TaskRemovalResult(failures: ['任务目录不在应用任务存储目录内']);
    }

    final others = await _readOtherTasksForCleanup(task.id);
    if (others == null) {
      return const TaskRemovalResult(failures: ['其他任务记录无法读取，已跳过共享数据清理']);
    }
    final inputDirectory = Directory(p.join(canonicalTaskDirectory, 'input'));
    final usbCopyDirectory = Directory(
      p.join(canonicalTaskDirectory, 'usb-copy'),
    );
    final ownedInputs = await _verifiedInputDirectory(task, inputDirectory);
    if (ownedInputs) {
      final shared = await _isReferencedByOtherTask(
        others,
        inputDirectory.path,
      );
      if (shared) {
        failures.add('input目录被其他任务共用，已保留');
      } else {
        await _deleteValidatedDirectory(
          inputDirectory,
          taskDirectory: taskDirectory,
          failures: failures,
        );
      }
    } else if (await inputDirectory.exists()) {
      failures.add('input目录无法验证所有权或内容已变化，已保留');
    }

    final taskOutputPath = await _canonicalExistingOrAbsolute(
      task.outputDirectory,
    );
    final taskDirOutput = p.normalize(p.join(taskDirectory.path, 'output'));
    final taskDirRender = p.normalize(p.join(taskDirectory.path, 'render'));
    final outputIsOwnedDirectory =
        p.equals(
          taskOutputPath,
          await _canonicalExistingOrAbsolute(taskDirOutput),
        ) ||
        p.equals(
          taskOutputPath,
          await _canonicalExistingOrAbsolute(taskDirRender),
        );
    if (outputIsOwnedDirectory) {
      final taskOutputDirectory = Directory(task.outputDirectory);
      final sharedOutput = await _isReferencedByOtherTask(
        others,
        taskOutputDirectory.path,
      );
      if (sharedOutput) {
        failures.add('渲染目录被其他任务引用，已保留');
      } else {
        await _deleteValidatedDirectory(
          taskOutputDirectory,
          taskDirectory: taskDirectory,
          failures: failures,
        );
      }
    } else {
      failures.add('渲染目录不在任务专属目录内，已保留');
    }

    if (await _isReferencedByOtherTask(others, usbCopyDirectory.path)) {
      failures.add('USB 临时副本被其他任务引用，已保留');
    } else {
      await _deleteValidatedDirectory(
        usbCopyDirectory,
        taskDirectory: taskDirectory,
        failures: failures,
      );
    }
    final thumbnail = File(
      p.join(canonicalTaskDirectory, 'camera-thumbnail.jpg'),
    );
    if (await _isFileReferencedByOtherTask(others, thumbnail.path)) {
      failures.add('任务缩略图被其他任务引用，已保留');
    } else {
      await _deleteOwnedTaskFile(
        thumbnail,
        taskDirectory: taskDirectory,
        failures: failures,
      );
    }
    await _deleteOwnedTaskFile(
      File(p.join(canonicalTaskDirectory, '.input-import.lock')),
      taskDirectory: taskDirectory,
      failures: failures,
    );

    final exportPath = task.exportPath;
    final expectedFingerprint = task.exportFingerprint;
    if (exportPath != null && expectedFingerprint != null) {
      try {
        await _deleteVerifiedExport(
          task,
          exportPath,
          expectedFingerprint,
          others,
        );
      } on Object catch (error) {
        failures.add('导出文件保留（$error）');
      }
    } else if (exportPath != null) {
      failures.add('导出文件缺少可验证指纹，已保留');
    }
    final publishedExportPath = task.publishedExportPath?.trim();
    if (publishedExportPath != null && publishedExportPath.isNotEmpty) {
      final sameAsPrivateExport =
          exportPath != null &&
          await _sameLocalFileOrUri(publishedExportPath, exportPath);
      if (!sameAsPrivateExport) {
        failures.add('已发布的外部副本已保留，请在目标位置删除');
      }
    }
    return TaskRemovalResult(failures: failures);
  }

  Future<List<StitchTask>?> _readOtherTasksForCleanup(String excludedId) async {
    final base = await root();
    final others = <StitchTask>[];
    await for (final entry in base.list(followLinks: false)) {
      if (entry is! Directory || p.basename(entry.path) == excludedId) continue;
      try {
        final canonical = await entry.resolveSymbolicLinks();
        final canonicalBase = await base.resolveSymbolicLinks();
        if (!p.isWithin(canonicalBase, canonical)) continue;
        if (await _isRemoved(entry)) continue;
        final file = File(p.join(entry.path, 'task.json'));
        if (!await file.exists()) continue;
        final decoded = await file.readAsString();
        final value = jsonDecode(decoded);
        if (value is! Map<String, Object?> || value['id'] == excludedId) {
          continue;
        }
        others.add(StitchTask.fromJson(value));
      } on Object {
        // An unreadable unrelated task cannot prove a shared path is unowned.
        return null;
      }
    }
    return others;
  }

  Future<bool> _verifiedInputDirectory(
    StitchTask task,
    Directory inputDirectory,
  ) async {
    if (task.photos.isEmpty || !await inputDirectory.exists()) return false;
    final canonicalInput = await inputDirectory.resolveSymbolicLinks();
    final canonicalTask = await Directory(
      p.dirname(inputDirectory.path),
    ).resolveSymbolicLinks();
    if (p.dirname(canonicalInput) != canonicalTask ||
        p.basename(canonicalInput) != 'input') {
      return false;
    }
    for (final photo in task.photos) {
      final path = p.normalize(p.absolute(photo.storedPath));
      if (!p.isWithin(inputDirectory.path, path)) return false;
      final file = File(path);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      try {
        if (await file.resolveSymbolicLinks() != path) return false;
        final digest = await sha256.bind(file.openRead()).first;
        if (digest.toString() != photo.sha256) return false;
      } on Object {
        return false;
      }
    }
    return true;
  }

  Future<bool> _isReferencedByOtherTask(
    List<StitchTask> others,
    String directory,
  ) async {
    for (final other in others) {
      final references = <String>[
        other.sourceDirectory,
        other.outputDirectory,
        if (other.exportPath != null) other.exportPath!,
        if (other.exportDirectory != null) other.exportDirectory!,
        for (final photo in other.photos) photo.storedPath,
      ];
      for (final reference in references) {
        if (await _pathReferencesDirectory(reference, directory)) return true;
      }
    }
    return false;
  }

  Future<bool> _pathReferencesDirectory(String path, String directory) async {
    if (path.trim().isEmpty || _isNonFileUri(path)) return false;
    final normalizedPath = await _canonicalExistingOrAbsolute(path);
    final normalizedDirectory = await _canonicalExistingOrAbsolute(directory);
    return p.equals(normalizedPath, normalizedDirectory) ||
        p.isWithin(normalizedDirectory, normalizedPath) ||
        p.isWithin(normalizedPath, normalizedDirectory);
  }

  bool _isNonFileUri(String path) =>
      RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://').hasMatch(path) ||
      path.startsWith('content:');

  Future<bool> _sameLocalFileOrUri(String first, String second) async {
    final firstIsUri = _isNonFileUri(first);
    final secondIsUri = _isNonFileUri(second);
    if (firstIsUri || secondIsUri) {
      return firstIsUri && secondIsUri && first == second;
    }
    return p.equals(
      await _canonicalExistingOrAbsolute(first),
      await _canonicalExistingOrAbsolute(second),
    );
  }

  Future<String> _canonicalExistingOrAbsolute(String path) async {
    final absolute = p.normalize(p.absolute(path));
    try {
      return await FileSystemEntity.isDirectory(absolute)
          ? await Directory(absolute).resolveSymbolicLinks()
          : await File(absolute).resolveSymbolicLinks();
    } on Object {
      return absolute;
    }
  }

  Future<void> _deleteValidatedDirectory(
    Directory directory, {
    required Directory taskDirectory,
    required List<String> failures,
  }) async {
    if (!await directory.exists()) return;
    try {
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FileSystemException('任务目录是链接或非目录，已跳过清理');
      }
      final canonicalTask = await taskDirectory.resolveSymbolicLinks();
      final canonicalDirectory = await directory.resolveSymbolicLinks();
      if (p.dirname(canonicalDirectory) != canonicalTask ||
          !const {
            'input',
            'output',
            'render',
            'usb-copy',
          }.contains(p.basename(canonicalDirectory))) {
        throw const FileSystemException('任务目录路径不安全');
      }
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (await FileSystemEntity.type(entity.path, followLinks: false) ==
            FileSystemEntityType.link) {
          throw FileSystemException('目录包含链接，已跳过清理', entity.path);
        }
        final resolved = await entity.resolveSymbolicLinks();
        if (!p.isWithin(canonicalDirectory, resolved)) {
          throw FileSystemException('目录包含越界路径，已跳过清理', entity.path);
        }
      }
      await directory.delete(recursive: true);
    } on Object catch (error) {
      failures.add('${p.basename(directory.path)}目录保留（$error）');
    }
  }

  Future<void> _deleteOwnedTaskFile(
    File file, {
    required Directory taskDirectory,
    required List<String> failures,
  }) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    try {
      final canonicalTask = await taskDirectory.resolveSymbolicLinks();
      final canonicalFile = await file.resolveSymbolicLinks();
      if (p.dirname(canonicalFile) != canonicalTask ||
          await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const FileSystemException('任务临时文件路径不安全');
      }
      await file.delete();
    } on Object catch (error) {
      failures.add('${p.basename(file.path)}保留（$error）');
    }
  }

  Future<void> _deleteVerifiedExport(
    StitchTask task,
    String path,
    ExportFileFingerprint expected,
    List<StitchTask> others,
  ) async {
    if (_isNonFileUri(path)) throw const FileSystemException('不支持删除此存储 URI');
    final normalized = p.normalize(p.absolute(path));
    if (task.photos.any(
      (photo) =>
          p.equals(normalized, p.normalize(p.absolute(photo.storedPath))),
    )) {
      throw const FileSystemException('路径指向任务原片');
    }
    final repositoryRoot = await (await root()).resolveSymbolicLinks();
    if (p.isWithin(repositoryRoot, normalized)) {
      throw const FileSystemException('拒绝从任务存储目录删除导出路径');
    }
    if (await _isFileReferencedByOtherTask(others, normalized)) {
      throw const FileSystemException('文件被其他任务引用');
    }
    final file = File(normalized);
    if (await FileSystemEntity.type(normalized, followLinks: false) !=
        FileSystemEntityType.file) {
      if (await FileSystemEntity.type(normalized, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return;
      }
      throw const FileSystemException('路径不是普通文件');
    }
    if (await file.resolveSymbolicLinks() != normalized) {
      throw const FileSystemException('拒绝删除符号链接');
    }
    final current = await fingerprintFile(normalized);
    if (current == null ||
        current.sizeBytes != expected.sizeBytes ||
        current.modifiedAtMicros != expected.modifiedAtMicros) {
      throw const FileSystemException('导出文件指纹已变化');
    }
    await file.delete();
  }

  Future<bool> _isFileReferencedByOtherTask(
    List<StitchTask> others,
    String filePath,
  ) async {
    final canonicalFile = await _canonicalExistingOrAbsolute(filePath);
    for (final other in others) {
      final exactReferences = <String>[
        if (other.exportPath != null) other.exportPath!,
        if (other.exportCheckpointPath != null) other.exportCheckpointPath!,
        if (other.previewThumbnailPath != null) other.previewThumbnailPath!,
        for (final photo in other.photos) photo.storedPath,
      ];
      for (final reference in exactReferences) {
        if (_isNonFileUri(reference)) continue;
        if (p.equals(
          canonicalFile,
          await _canonicalExistingOrAbsolute(reference),
        )) {
          return true;
        }
      }
      if (!_isNonFileUri(other.sourceDirectory)) {
        final sourceDirectory = await _canonicalExistingOrAbsolute(
          other.sourceDirectory,
        );
        if (p.equals(sourceDirectory, canonicalFile) ||
            p.isWithin(sourceDirectory, canonicalFile)) {
          return true;
        }
      }
    }
    return false;
  }

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
      protectPeople: old.protectPeople,
      smoothWater: old.smoothWater,
      maxEdgeReprojectionRmsPixels: old.maxEdgeReprojectionRmsPixels,
      registrationRepairOffered: old.registrationRepairOffered,
    );
    await save(task);
    return task;
  }
}

class TaskRemovalResult {
  const TaskRemovalResult({this.failures = const []});

  final List<String> failures;

  bool get cleanupComplete => failures.isEmpty;
}
