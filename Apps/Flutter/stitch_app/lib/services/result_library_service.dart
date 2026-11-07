import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/export_fingerprint.dart';
import '../models/stitch_task.dart';
import 'native_job_api.dart';
import 'task_record_service.dart';
import 'task_repository.dart';

class ResultLibraryException implements Exception {
  const ResultLibraryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Performs file and task-record changes for completed panorama results.
class ResultLibraryService {
  ResultLibraryService({
    required this.repository,
    this.api,
    this.isTaskBusy,
    this.maxNativeExportDuration = const Duration(minutes: 20),
    this.nativePollInterval = const Duration(milliseconds: 250),
  });

  final TaskRepository repository;
  final JobApi? api;
  final bool Function(String taskId)? isTaskBusy;
  final Duration maxNativeExportDuration;
  final Duration nativePollInterval;

  static final Map<String, Future<void>> _taskTails = {};
  static final Random _random = Random.secure();

  static String resultName(StitchTask task) {
    final displayName = task.displayName?.trim();
    if (displayName != null && displayName.isNotEmpty) return displayName;
    final exportPath = task.exportPath?.trim();
    if (exportPath != null && exportPath.isNotEmpty) {
      final name = p.basenameWithoutExtension(exportPath);
      if (name.isNotEmpty) return name;
    }
    final source = task.sourceDirectory.trim();
    return p.basename(p.normalize(source));
  }

  Future<StitchTask> renameResult(
    StitchTask task,
    String newBaseName,
  ) => _withTaskLock(task.id, () async {
    final latest = await _loadEligible(task);
    final paths = await _existingResultPaths(latest);
    if (paths.isEmpty) {
      throw const ResultLibraryException('没有可改名的整图文件；请先导出或另存结果。');
    }
    final primaryPath = await _choosePrimaryPath(latest, paths);
    if (latest.exportPath != null &&
        await _sameExistingPath(latest.exportPath!, primaryPath)) {
      final primaryFingerprint = await repository.fingerprintFile(primaryPath);
      _checkFingerprint(latest, primaryPath, primaryFingerprint);
    }

    final primaryExtension = p.extension(primaryPath);
    if (primaryExtension.isEmpty) {
      throw const ResultLibraryException('整图文件没有可保留的扩展名。');
    }
    final baseName = _validatedBaseName(newBaseName, primaryExtension);
    final plans = <_RenamePlan>[];
    final pathMap = <String, String>{};
    var metadataCommitted = false;
    try {
      for (final sourcePath in paths) {
        final sourceFile = await _validatedResultFile(latest, sourcePath);
        final extension = p.extension(sourceFile.path);
        if (extension.isEmpty) {
          throw ResultLibraryException('无法为结果文件保留扩展名：$sourcePath');
        }
        final destinationPath = p.join(
          p.dirname(sourceFile.path),
          '$baseName$extension',
        );
        final caseOnly = _isCaseOnlyPathChange(
          sourceFile.path,
          destinationPath,
        );
        final normalizedSource = p.normalize(p.absolute(sourceFile.path));
        final normalizedDestination = p.normalize(p.absolute(destinationPath));
        if (!caseOnly && normalizedSource == normalizedDestination) {
          pathMap[sourceFile.path] = destinationPath;
          continue;
        }
        final plan = await _prepareRename(
          sourceFile,
          File(destinationPath),
          caseOnly: caseOnly,
        );
        plans.add(plan);
        pathMap[sourceFile.path] = destinationPath;
        for (final reference in [
          latest.exportPath,
          latest.publishedExportPath,
          latest.exportCheckpointPath,
        ].whereType<String>()) {
          if (await _sameExistingPath(reference, sourceFile.path)) {
            pathMap[reference] = destinationPath;
          }
        }
      }

      final newExportPath =
          await _mappedPath(latest.exportPath, pathMap) ??
          await _mappedPath(primaryPath, pathMap);
      final updatedFingerprint = newExportPath == null
          ? null
          : await repository.fingerprintFile(newExportPath);
      if (newExportPath != null && updatedFingerprint == null) {
        throw const ResultLibraryException('改名后的整图文件不可用。');
      }
      final updated = latest.copyWith(
        displayName: baseName,
        exportPath: newExportPath,
        clearExportPath: newExportPath == null,
        exportFingerprint: updatedFingerprint,
        clearExportFingerprint: updatedFingerprint == null,
        publishedExportPath: await _mappedPath(
          latest.publishedExportPath,
          pathMap,
        ),
        clearPublishedExportPath:
            latest.publishedExportPath != null &&
            await _mappedPath(latest.publishedExportPath, pathMap) == null,
        exportCheckpointPath: await _mappedPath(
          latest.exportCheckpointPath,
          pathMap,
        ),
        clearExportCheckpointPath:
            latest.exportCheckpointPath != null &&
            await _mappedPath(latest.exportCheckpointPath, pathMap) == null,
        exportDirectory: newExportPath == null
            ? latest.exportDirectory
            : p.dirname(newExportPath),
      );
      await repository.save(updated);
      metadataCommitted = true;
      for (final plan in plans) {
        try {
          await _cleanupRenameSource(plan);
        } on Object catch (error) {
          throw ResultLibraryException(
            '改名已保存，但旧文件未能清理：${plan.source.path}（$error）',
          );
        }
      }
      return updated;
    } on Object {
      // Once the task record points at the new path, file rollback would
      // leave the record dangling. Cleanup failures therefore preserve the
      // committed destination and report the retained old path.
      if (metadataCommitted) rethrow;
      await _rollbackRenames(plans);
      rethrow;
    }
  });

  Future<StitchTask> exportResultToDirectory(
    StitchTask task,
    String directory, {
    void Function(double progress)? onProgress,
  }) => _withTaskLock(task.id, () async {
    final latest = await _loadEligible(task, allowExportHandoff: true);
    if (latest.phase != StitchPhase.completed) {
      return _resumeExportHandoff(latest, directory, onProgress: onProgress);
    }
    if (directory.trim().isEmpty) {
      throw const ResultLibraryException('请选择有效的导出文件夹。');
    }
    final targetDirectory = Directory(p.absolute(directory));
    await targetDirectory.create(recursive: true);
    final canonicalDirectory = await targetDirectory.resolveSymbolicLinks();
    var sourcePath = latest.exportPath;
    var sourceExists = sourcePath != null && await File(sourcePath).exists();
    if (!sourceExists && latest.publishedExportPath != null) {
      final publishedExists = await File(latest.publishedExportPath!).exists();
      if (publishedExists) {
        sourcePath = latest.publishedExportPath;
        sourceExists = true;
      }
    }
    if (sourceExists) {
      final sourcePathValue = sourcePath!;
      final sourceFingerprint = await repository.fingerprintFile(
        sourcePathValue,
      );
      if (latest.exportPath != null &&
          await _sameExistingPath(sourcePathValue, latest.exportPath!)) {
        _checkFingerprint(latest, sourcePathValue, sourceFingerprint);
      } else if (sourceFingerprint == null) {
        throw ResultLibraryException('整图文件不存在或为空：$sourcePathValue');
      }
      final source = await _validatedResultFile(latest, sourcePathValue);
      final extension = p.extension(source.path);
      if (extension.isEmpty) {
        throw const ResultLibraryException('整图文件没有可保留的扩展名。');
      }
      final safeName = _validatedBaseName(resultName(latest), extension);
      final destination = await _copyToUniqueDestination(
        source,
        canonicalDirectory,
        safeName,
        extension,
        onProgress: onProgress,
      );
      final fingerprint = await repository.fingerprintFile(destination.path);
      if (fingerprint == null) {
        await _deleteIfExists(destination);
        throw const ResultLibraryException('另存后的整图文件不可用。');
      }
      final updated = latest.copyWith(
        exportPath: destination.path,
        exportFingerprint: fingerprint,
        exportDirectory: canonicalDirectory,
        publishedExportPath: destination.path,
        clearExportCheckpointPath: true,
        clearPublishError: true,
      );
      try {
        await repository.save(updated);
      } on Object {
        await _deleteIfExists(destination);
        rethrow;
      }
      onProgress?.call(1);
      return updated;
    }

    return _exportFromNative(
      latest,
      canonicalDirectory,
      onProgress: onProgress,
    );
  });

  Future<TaskRemovalResult> deleteResult(
    StitchTask task, {
    required Future<TaskRemovalResult> Function(StitchTask latest) remove,
  }) => _withTaskLock(task.id, () async {
    final latest = await _loadEligible(task);
    if (latest.phase != StitchPhase.completed ||
        latest.stage == 'result-library-export' ||
        latest.exportCheckpointPath != null) {
      throw const ResultLibraryException('结果仍在导出或等待恢复，无法删除任务。');
    }
    return remove(latest);
  });

  Future<StitchTask> _exportFromNative(
    StitchTask task,
    String directory, {
    void Function(double progress)? onProgress,
  }) async {
    final nativeApi = api;
    if (nativeApi == null) {
      throw const ResultLibraryException('无法恢复整图：原生合成接口不可用。');
    }
    final jobId = task.nativeJobId?.trim().isNotEmpty == true
        ? task.nativeJobId!.trim()
        : task.outputDirectory;
    final initialStatus = await nativeApi.status(jobId);
    final initialState = initialStatus['state'] as String?;
    final initialOperation = initialStatus['operation'] as String?;
    if (initialState == 'running' ||
        initialState == 'queued' ||
        initialState == 'pausing') {
      throw const ResultLibraryException('任务正在运行，暂时不能恢复整图导出。');
    }
    if (initialState != 'completed' &&
        !(initialOperation == 'export' &&
            {'failed', 'cancelled'}.contains(initialState))) {
      throw ResultLibraryException(
        '原生任务状态不支持整图导出恢复：${initialState ?? 'unknown'}。',
      );
    }

    final extension = '.${task.exportFormat.extension}';
    final safeName = _validatedBaseName(resultName(task), extension);
    var destination = await _uniquePath(directory, safeName, extension);
    var checkpointTask = task.copyWith(
      phase: StitchPhase.exporting,
      stage: 'result-library-export',
      autoExportOnCompletion: false,
      exportDirectory: directory,
      exportCheckpointPath: destination.path,
      clearError: true,
    );
    await repository.save(checkpointTask);
    var exportAttempted = false;
    try {
      final deadline = DateTime.now().add(maxNativeExportDuration);
      Map<String, Object?> status;
      while (true) {
        try {
          exportAttempted = true;
          status = await nativeApi.export(jobId, destination.path);
        } on NativeJobException catch (error) {
          if (error.code != 'OUTPUT_EXISTS') rethrow;
          exportAttempted = false;
          destination = await _uniquePath(directory, safeName, extension);
          checkpointTask = checkpointTask.copyWith(
            exportCheckpointPath: destination.path,
          );
          await repository.save(checkpointTask);
          continue;
        }
        break;
      }
      _verifyNativeExportTarget(status, destination.path);
      while (true) {
        final state = status['state'] as String?;
        final operation = status['operation'] as String?;
        if (state == 'completed') {
          _verifyNativeExportTarget(status, destination.path);
          break;
        }
        if (state == 'failed' || state == 'cancelled') {
          throw ResultLibraryException(
            '原生整图导出${state == 'failed' ? '失败' : '已取消'}：${_errorText(status['error'])}',
          );
        }
        if (operation != 'export' ||
            (state != 'running' && state != 'queued' && state != 'paused')) {
          throw ResultLibraryException(
            '原生核心未在导出指定的整图：${state ?? 'unknown'} / ${operation ?? 'unknown'}。',
          );
        }
        _verifyNativeExportTarget(status, destination.path);
        final progress = (status['progress'] as num?)?.toDouble();
        if (progress != null && progress.isFinite) {
          onProgress?.call(progress.clamp(0, 1).toDouble());
        }
        if (DateTime.now().isAfter(deadline)) {
          throw const _NativeExportTimedOut();
        }
        await Future<void>.delayed(nativePollInterval);
        status = await nativeApi.status(jobId);
      }
      final fingerprint = await repository.fingerprintFile(destination.path);
      if (fingerprint == null) {
        throw const ResultLibraryException('核心报告导出完成，但整图文件不存在或为空。');
      }
      final completed = task.copyWith(
        phase: StitchPhase.completed,
        stage: 'done',
        autoExportOnCompletion: false,
        exportPath: destination.path,
        exportFingerprint: fingerprint,
        exportDirectory: directory,
        publishedExportPath: destination.path,
        clearExportCheckpointPath: true,
        clearError: true,
        clearPublishError: true,
      );
      await repository.save(completed);
      onProgress?.call(1);
      return completed;
    } on _NativeExportTimedOut {
      final quiescent = exportAttempted
          ? await _stopNativeExport(nativeApi, jobId, destination.path)
          : null;
      if (!exportAttempted) {
        await _restoreFailedNativeExport(task, '导出未能启动。');
        rethrow;
      }
      if (quiescent == null) {
        throw ResultLibraryException(
          '整图导出超时；原生核心状态暂不可确认，保留导出检查点：${destination.path}',
        );
      }
      if (quiescent['state'] == 'completed' &&
          _ownsNativeExport(quiescent, destination.path)) {
        return _persistCompletedNativeExport(task, directory, destination.path);
      }
      if (quiescent['state'] == 'completed') {
        await _restoreFailedNativeExport(task, '原生状态不再对应本次导出。');
        rethrow;
      }
      if (!{'failed', 'cancelled'}.contains(quiescent['state'])) {
        throw ResultLibraryException(
          '整图导出超时；已请求停止原生导出但仍在运行，保留导出检查点：${destination.path}',
        );
      }
      await _restoreFailedNativeExport(task, '等待超时后已取消导出。');
      rethrow;
    } on Object catch (error) {
      final quiescent = exportAttempted
          ? await _stopNativeExport(nativeApi, jobId, destination.path)
          : null;
      if (!exportAttempted) {
        await _restoreFailedNativeExport(task, error.toString());
        rethrow;
      }
      if (quiescent == null) {
        throw ResultLibraryException(
          '整图恢复失败，原生核心状态无法确认；保留导出检查点：${destination.path}（$error）',
        );
      }
      if (quiescent['state'] == 'completed' &&
          _ownsNativeExport(quiescent, destination.path)) {
        try {
          return await _persistCompletedNativeExport(
            task,
            directory,
            destination.path,
          );
        } on Object catch (persistError) {
          throw ResultLibraryException(
            '原生核心已完成导出但任务记录更新失败；已保留文件 ${destination.path}（$error；$persistError）',
          );
        }
      }
      if (quiescent['state'] == 'completed') {
        await _restoreFailedNativeExport(task, error.toString());
        rethrow;
      }
      if (!{'failed', 'cancelled'}.contains(quiescent['state'])) {
        throw ResultLibraryException(
          '整图恢复失败，原生核心仍可能在写入；保留导出检查点：${destination.path}（$error）',
        );
      }
      await _restoreFailedNativeExport(task, error.toString());
      rethrow;
    }
  }

  Future<StitchTask> _loadEligible(
    StitchTask requested, {
    bool allowExportHandoff = false,
  }) async {
    if (isTaskBusy?.call(requested.id) == true) {
      throw const ResultLibraryException('任务正在运行，无法修改结果文件。');
    }
    if (!_isCompletedOrHandoff(requested, allowExportHandoff)) {
      throw const ResultLibraryException('只有已完成的合成任务可以操作结果。');
    }
    final latest = await repository.loadById(requested.id);
    if (latest == null) {
      throw const ResultLibraryException('任务记录不存在或已被删除。');
    }
    if (TaskRecordService.identityForTask(latest) !=
        TaskRecordService.identityForTask(requested)) {
      throw const ResultLibraryException('任务已变化，请刷新结果列表后重试。');
    }
    if (!_isCompletedOrHandoff(latest, allowExportHandoff)) {
      throw const ResultLibraryException('任务状态已变化，只有已完成的合成任务可以操作结果。');
    }
    if (isTaskBusy?.call(latest.id) == true) {
      throw const ResultLibraryException('任务正在运行，无法修改结果文件。');
    }
    return latest;
  }

  bool _isCompletedOrHandoff(StitchTask task, bool allowExportHandoff) =>
      task.phase == StitchPhase.completed ||
      (allowExportHandoff &&
          task.phase == StitchPhase.interrupted &&
          task.stage == 'result-library-export' &&
          task.exportCheckpointPath != null);

  Future<List<String>> _existingResultPaths(StitchTask task) async {
    final candidates = [
      task.exportPath,
      task.publishedExportPath,
      task.exportCheckpointPath,
    ].whereType<String>().where((path) => path.trim().isNotEmpty);
    final existing = <String>[];
    for (final candidate in candidates) {
      final file = File(candidate);
      if (!await file.exists()) continue;
      final canonical = await file.resolveSymbolicLinks();
      if (!existing.any((path) => p.equals(path, canonical))) {
        existing.add(canonical);
      }
    }
    return existing;
  }

  Future<String> _choosePrimaryPath(
    StitchTask task,
    List<String> existing,
  ) async {
    for (final candidate in [task.exportPath, task.publishedExportPath]) {
      if (candidate == null) continue;
      for (final path in existing) {
        if (await _sameExistingPath(candidate, path)) return path;
      }
    }
    return existing.first;
  }

  void _checkFingerprint(
    StitchTask task,
    String path,
    ExportFileFingerprint? actual,
  ) {
    if (actual == null) {
      throw ResultLibraryException('整图文件不存在或为空：$path');
    }
    final expected = task.exportFingerprint;
    if (expected != null &&
        (expected.sizeBytes != actual.sizeBytes ||
            expected.modifiedAtMicros != actual.modifiedAtMicros)) {
      throw const ResultLibraryException('整图文件与保存的指纹不匹配，已拒绝覆盖或重新绑定。');
    }
  }

  Future<void> _restoreFailedNativeExport(StitchTask task, String error) async {
    final restored = task.copyWith(
      phase: StitchPhase.completed,
      stage: 'result-library-export-failed',
      autoExportOnCompletion: false,
      clearExportCheckpointPath: true,
      error: '整图恢复失败：$error',
    );
    await repository.save(restored);
  }

  Future<StitchTask> _persistCompletedNativeExport(
    StitchTask task,
    String directory,
    String destination,
  ) async {
    final fingerprint = await repository.fingerprintFile(destination);
    if (fingerprint == null) {
      throw ResultLibraryException('原生核心报告导出完成，但文件不存在或为空；保留检查点：$destination');
    }
    final completed = task.copyWith(
      phase: StitchPhase.completed,
      stage: 'done',
      autoExportOnCompletion: false,
      exportPath: destination,
      exportFingerprint: fingerprint,
      exportDirectory: directory,
      publishedExportPath: destination,
      clearExportCheckpointPath: true,
      clearError: true,
      clearPublishError: true,
    );
    await repository.save(completed);
    return completed;
  }

  Future<StitchTask> _resumeExportHandoff(
    StitchTask task,
    String directory, {
    void Function(double progress)? onProgress,
  }) async {
    final nativeApi = api;
    if (nativeApi == null) {
      throw const ResultLibraryException('无法恢复整图：原生合成接口不可用。');
    }
    if (directory.trim().isEmpty) {
      throw const ResultLibraryException('请选择有效的导出文件夹。');
    }
    final targetDirectory = Directory(p.absolute(directory));
    await targetDirectory.create(recursive: true);
    final target = await targetDirectory.resolveSymbolicLinks();
    final checkpoint = task.exportCheckpointPath!;
    final jobId = task.nativeJobId?.trim().isNotEmpty == true
        ? task.nativeJobId!.trim()
        : task.outputDirectory;
    final deadline = DateTime.now().add(maxNativeExportDuration);
    var status = await nativeApi.status(jobId);
    while (true) {
      if (!_ownsNativeExport(status, checkpoint)) {
        final state = status['state'] as String?;
        if (state == 'completed' && status['operation'] == 'render') {
          final restored = task.copyWith(
            phase: StitchPhase.completed,
            stage: 'result-library-export-failed',
            clearExportCheckpointPath: true,
            clearError: true,
          );
          await repository.save(restored);
          return _exportFromNative(restored, target, onProgress: onProgress);
        }
        if (state == 'failed' || state == 'cancelled') {
          await _restoreFailedNativeExport(task, '原生任务未能恢复已记录的整图导出。');
        }
        throw ResultLibraryException('无法确认已记录的整图导出目标；保留检查点：$checkpoint');
      }
      final state = status['state'] as String?;
      if (state == 'completed') {
        final completed = await _persistCompletedNativeExport(
          task,
          p.dirname(checkpoint),
          checkpoint,
        );
        if (p.equals(
          p.normalize(p.absolute(target)),
          p.normalize(p.absolute(p.dirname(checkpoint))),
        )) {
          return completed;
        }
        return _copyCompletedResult(completed, target, onProgress: onProgress);
      }
      if (state == 'failed' || state == 'cancelled') {
        await _restoreFailedNativeExport(
          task,
          '原生整图导出${state == 'failed' ? '失败' : '已取消'}：${_errorText(status['error'])}',
        );
        throw ResultLibraryException(
          '原生整图导出${state == 'failed' ? '失败' : '已取消'}：${_errorText(status['error'])}',
        );
      }
      if (state != 'running' &&
          state != 'queued' &&
          state != 'pausing' &&
          state != 'paused') {
        throw ResultLibraryException('原生整图导出状态未知；保留检查点：$checkpoint');
      }
      final progress = (status['progress'] as num?)?.toDouble();
      if (progress != null && progress.isFinite) {
        onProgress?.call(progress.clamp(0, 1).toDouble());
      }
      if (DateTime.now().isAfter(deadline)) {
        final quiescent = await _stopNativeExport(nativeApi, jobId, checkpoint);
        if (quiescent != null && _ownsNativeExport(quiescent, checkpoint)) {
          final finalState = quiescent['state'];
          if (finalState == 'completed') {
            final completed = await _persistCompletedNativeExport(
              task,
              p.dirname(checkpoint),
              checkpoint,
            );
            if (p.equals(
              p.normalize(p.absolute(target)),
              p.normalize(p.absolute(p.dirname(checkpoint))),
            )) {
              return completed;
            }
            return _copyCompletedResult(
              completed,
              target,
              onProgress: onProgress,
            );
          }
          if (finalState == 'failed' || finalState == 'cancelled') {
            await _restoreFailedNativeExport(task, '等待超时后已取消原生整图导出。');
            throw const ResultLibraryException('整图导出等待超时，原生任务已停止；可以重新导出。');
          }
        }
        throw ResultLibraryException('整图导出仍未静止，保留原生检查点以便重新连接：$checkpoint');
      }
      await Future<void>.delayed(nativePollInterval);
      status = await nativeApi.status(jobId);
    }
  }

  Future<StitchTask> _copyCompletedResult(
    StitchTask task,
    String directory, {
    void Function(double progress)? onProgress,
  }) async {
    final sourcePath = task.exportPath;
    if (sourcePath == null) {
      throw const ResultLibraryException('已完成的整图记录缺少文件路径。');
    }
    final fingerprint = await repository.fingerprintFile(sourcePath);
    _checkFingerprint(task, sourcePath, fingerprint);
    final source = await _validatedResultFile(task, sourcePath);
    final extension = p.extension(source.path);
    final safeName = _validatedBaseName(resultName(task), extension);
    final destination = await _copyToUniqueDestination(
      source,
      directory,
      safeName,
      extension,
      onProgress: onProgress,
    );
    final copiedFingerprint = await repository.fingerprintFile(
      destination.path,
    );
    if (copiedFingerprint == null) {
      await _deleteIfExists(destination);
      throw const ResultLibraryException('另存后的整图文件不可用。');
    }
    final updated = task.copyWith(
      exportPath: destination.path,
      exportFingerprint: copiedFingerprint,
      exportDirectory: directory,
      publishedExportPath: destination.path,
      clearExportCheckpointPath: true,
      clearPublishError: true,
    );
    try {
      await repository.save(updated);
    } on Object {
      await _deleteIfExists(destination);
      rethrow;
    }
    onProgress?.call(1);
    return updated;
  }

  Future<File> _validatedResultFile(StitchTask task, String path) async {
    final absolute = p.normalize(p.absolute(path));
    final entityType = await FileSystemEntity.type(
      absolute,
      followLinks: false,
    );
    if (entityType != FileSystemEntityType.file) {
      throw ResultLibraryException('结果不是普通文件，已拒绝操作：$path');
    }
    final file = File(absolute);
    final canonical = await file.resolveSymbolicLinks();
    for (final photo in task.photos) {
      if (await _sameExistingPath(photo.storedPath, canonical)) {
        throw const ResultLibraryException('结果路径指向原片文件，已拒绝操作。');
      }
    }
    if (_isProtectedRenderArtifact(task, canonical)) {
      throw ResultLibraryException('结果路径指向合成金字塔或任务状态文件，已拒绝操作：$path');
    }
    return File(canonical);
  }

  bool _isProtectedRenderArtifact(StitchTask task, String path) {
    final root = task.outputDirectory.trim();
    if (root.isEmpty || root.contains('://')) return false;
    final normalizedRoot = p.normalize(p.absolute(root));
    if (!p.isWithin(normalizedRoot, path)) return false;
    final relative = p.relative(path, from: normalizedRoot);
    final segments = p.split(relative);
    if (segments.isEmpty) return true;
    final leaf = segments.last.toLowerCase();
    if (segments.first.toLowerCase().startsWith('level-')) return true;
    return const {
      'manifest.json',
      'layout.json',
      'job-state.json',
      'job-request.json',
      'registration.json',
      'result-stats.json',
    }.contains(leaf);
  }

  String _validatedBaseName(String value, String extension) {
    if (value != value.trim()) {
      throw const ResultLibraryException('文件名前后不能包含空格。');
    }
    var name = value;
    if (name.toLowerCase().endsWith(extension.toLowerCase())) {
      name = name.substring(0, name.length - extension.length);
    }
    if (name.isEmpty || name == '.' || name == '..') {
      throw const ResultLibraryException('文件名不能为空。');
    }
    if (RegExp(r'[\\/:*?"<>|\x00-\x1f]').hasMatch(name) ||
        name.endsWith('.') ||
        name.endsWith(' ')) {
      throw const ResultLibraryException('文件名包含 Windows 不支持的字符。');
    }
    final deviceStem = name.split('.').first.toUpperCase();
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])$',
    ).hasMatch(deviceStem)) {
      throw const ResultLibraryException('文件名是 Windows 保留设备名。');
    }
    if (name.length > 180) {
      throw const ResultLibraryException('文件名过长。');
    }
    return name;
  }

  Future<_RenamePlan> _prepareRename(
    File source,
    File destination, {
    required bool caseOnly,
  }) async {
    if (!caseOnly && await destination.exists()) {
      throw ResultLibraryException('目标文件已存在：${destination.path}');
    }
    if (!caseOnly) {
      await _copyExclusive(source, destination);
      return _RenamePlan(source: source, destination: destination);
    }

    final staging = await _uniquePath(
      p.dirname(source.path),
      '.result-rename-${_random.nextInt(1 << 32)}',
      '.tmp',
    );
    await _copyExclusive(source, staging);
    var destinationCreated = false;
    try {
      await source.delete();
      await _copyExclusive(staging, destination);
      destinationCreated = true;
      return _RenamePlan(
        source: source,
        destination: destination,
        staging: staging,
      );
    } on Object {
      if (destinationCreated) {
        try {
          await destination.delete();
        } on Object catch (error) {
          throw ResultLibraryException(
            '大小写改名失败；保留目标 ${destination.path} 和恢复副本 ${staging.path}（$error）',
          );
        }
      }
      if (!await source.exists()) {
        try {
          await _copyExclusive(staging, source);
          await staging.delete();
        } on Object catch (error) {
          throw ResultLibraryException(
            '大小写改名失败；恢复原文件失败，保留恢复副本：${staging.path}（$error）',
          );
        }
      } else {
        throw ResultLibraryException(
          '大小写改名失败；保留原文件及恢复副本：${source.path}、${staging.path}',
        );
      }
      rethrow;
    }
  }

  Future<void> _cleanupRenameSource(_RenamePlan plan) async {
    if (plan.staging != null) {
      await plan.staging!.delete();
      return;
    }
    await plan.source.delete();
  }

  Future<void> _rollbackRenames(List<_RenamePlan> plans) async {
    final failures = <String>[];
    for (final plan in plans.reversed) {
      try {
        await plan.destination.delete();
      } on Object catch (error) {
        failures.add('保留目标文件 ${plan.destination.path}（$error）');
      }
      if (plan.staging != null) {
        if (!await plan.source.exists()) {
          try {
            await _copyExclusive(plan.staging!, plan.source);
            await plan.staging!.delete();
          } on Object catch (error) {
            failures.add('原文件恢复副本保留 ${plan.staging!.path}（$error）');
          }
        } else {
          failures.add('原路径已被其他文件占用，恢复副本保留 ${plan.staging!.path}');
        }
      }
    }
    if (failures.isNotEmpty) {
      throw ResultLibraryException('改名回滚未能完全清理：${failures.join('；')}');
    }
  }

  Future<String?> _mappedPath(String? path, Map<String, String> pathMap) async {
    if (path == null) return null;
    for (final entry in pathMap.entries) {
      if (p.equals(
            p.normalize(p.absolute(path)),
            p.normalize(p.absolute(entry.key)),
          ) ||
          _isCaseOnlyPathChange(path, entry.key) ||
          await _sameExistingPath(path, entry.key)) {
        return entry.value;
      }
    }
    return null;
  }

  Future<bool> _sameExistingPath(String a, String b) async {
    final normalizedA = p.normalize(p.absolute(a));
    final normalizedB = p.normalize(p.absolute(b));
    if (p.equals(normalizedA, normalizedB) ||
        _isCaseOnlyPathChange(normalizedA, normalizedB)) {
      return true;
    }
    try {
      return await FileSystemEntity.identical(a, b);
    } on FileSystemException {
      return false;
    }
  }

  bool _isCaseOnlyPathChange(String source, String destination) =>
      Platform.isWindows &&
      p.normalize(p.absolute(source)) != p.normalize(p.absolute(destination)) &&
      p.normalize(p.absolute(source)).toLowerCase() ==
          p.normalize(p.absolute(destination)).toLowerCase();

  Future<File> _copyToUniqueDestination(
    File source,
    String directory,
    String baseName,
    String extension, {
    void Function(double progress)? onProgress,
  }) async {
    for (var index = 1; index <= 10000; index++) {
      final suffix = index == 1 ? '' : ' ($index)';
      final destination = File(p.join(directory, '$baseName$suffix$extension'));
      try {
        await _copyExclusive(source, destination, onProgress: onProgress);
        return destination;
      } on _DestinationAlreadyExists {
        continue;
      }
    }
    throw const ResultLibraryException('无法生成不冲突的文件名。');
  }

  Future<File> _uniquePath(
    String directory,
    String baseName,
    String extension,
  ) async {
    for (var index = 1; index <= 10000; index++) {
      final suffix = index == 1 ? '' : ' ($index)';
      final candidate = File(p.join(directory, '$baseName$suffix$extension'));
      if (!await candidate.exists()) return candidate;
    }
    throw const ResultLibraryException('无法生成不冲突的文件名。');
  }

  Future<void> _copyExclusive(
    File source,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    RandomAccessFile? output;
    var destinationCreated = false;
    try {
      try {
        await destination.create(exclusive: true);
      } on FileSystemException {
        final type = await FileSystemEntity.type(
          destination.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.notFound) {
          throw const _DestinationAlreadyExists();
        }
        rethrow;
      }
      destinationCreated = true;
      output = await destination.open(mode: FileMode.writeOnly);
      final before = await source.stat();
      final length = before.size;
      final digestBefore = await sha256.bind(source.openRead()).first;
      var copied = 0;
      final digestDuringCopy = _SingleDigestSink();
      final digestInput = sha256.startChunkedConversion(digestDuringCopy);
      await for (final chunk in source.openRead()) {
        await output.writeFrom(chunk);
        digestInput.add(chunk);
        copied += chunk.length;
        if (length > 0) {
          onProgress?.call((copied / length).clamp(0, 1).toDouble());
        }
      }
      digestInput.close();
      final after = await source.stat();
      final digestCopied = digestDuringCopy.value;
      if (copied != length ||
          before.size != after.size ||
          before.modified.microsecondsSinceEpoch !=
              after.modified.microsecondsSinceEpoch ||
          digestBefore != digestCopied) {
        throw const ResultLibraryException('改名或另存期间源文件发生变化，已丢弃不完整副本。');
      }
      await output.flush();
      await output.close();
      output = null;
    } on Object {
      try {
        await output?.close();
      } on Object {
        // The destination cleanup below is best effort after a failed write.
      }
      if (destinationCreated) await _deleteIfExists(destination);
      rethrow;
    }
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // Keep cleanup failures from hiding the primary failure or last copy.
    }
  }

  Future<Map<String, Object?>?> _stopNativeExport(
    JobApi nativeApi,
    String jobId,
    String destination,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    Map<String, Object?>? lastStatus;
    var cancelRequested = false;
    while (DateTime.now().isBefore(deadline)) {
      Map<String, Object?> status;
      try {
        status = await nativeApi.status(jobId);
      } on Object {
        await Future<void>.delayed(nativePollInterval);
        continue;
      }
      lastStatus = status;
      if ({'completed', 'failed', 'cancelled'}.contains(status['state'])) {
        return status;
      }
      if (!_ownsNativeExport(status, destination)) return null;
      if (!cancelRequested) {
        cancelRequested = true;
        try {
          await nativeApi.cancel(jobId);
        } on Object {
          // A non-cancellable commit may finish while we keep checking.
        }
      }
      await Future<void>.delayed(nativePollInterval);
    }
    return lastStatus;
  }

  bool _ownsNativeExport(Map<String, Object?> status, String destination) =>
      status['operation'] == 'export' &&
      status['exportDestination'] is String &&
      _pathsMatch(status['exportDestination']! as String, destination);

  void _verifyNativeExportTarget(Map<String, Object?> status, String expected) {
    if (status['operation'] != 'export') {
      throw const ResultLibraryException('原生核心当前操作不是整图导出。');
    }
    final actual = status['exportDestination'];
    if (actual is! String || !_pathsMatch(actual, expected)) {
      throw const ResultLibraryException('原生核心导出目标与请求路径不一致。');
    }
  }

  bool _pathsMatch(String a, String b) =>
      p.equals(p.normalize(p.absolute(a)), p.normalize(p.absolute(b)));

  String _errorText(Object? value) {
    if (value is Map) return '${value['message'] ?? value['code'] ?? value}';
    return value?.toString() ?? '未知错误';
  }

  Future<T> _withTaskLock<T>(String id, Future<T> Function() action) async {
    final previous = _taskTails[id] ?? Future<void>.value();
    final release = Completer<void>();
    _taskTails[id] = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
      if (identical(_taskTails[id], release.future)) _taskTails.remove(id);
    }
  }
}

class _RenamePlan {
  const _RenamePlan({
    required this.source,
    required this.destination,
    this.staging,
  });

  final File source;
  final File destination;
  final File? staging;
}

class _NativeExportTimedOut implements Exception {
  const _NativeExportTimedOut();
}

class _DestinationAlreadyExists implements Exception {
  const _DestinationAlreadyExists();
}

class _SingleDigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
