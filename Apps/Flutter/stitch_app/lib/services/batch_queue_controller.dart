import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/batch_queue.dart';
import '../models/app_settings.dart';
import '../models/grid_options.dart';
import '../models/performance_options.dart';
import '../models/stitch_task.dart';
import '../models/stitch_timeline.dart';
import '../models/stitch_quality.dart';
import '../models/dwarf_download.dart';
import 'batch_folder_importer.dart';
import 'batch_queue_repository.dart';
import 'native_job_api.dart';
import 'mobile_runtime_service.dart';
import 'mobile_storage_service.dart';
import 'spherical_request.dart';
import 'task_repository.dart';
import 'task_record_service.dart';
import 'dwarf_download_service.dart';

class BatchQueueController extends ChangeNotifier {
  BatchQueueController({
    required this.api,
    BatchQueueRepository? queueRepository,
    TaskRepository? taskRepository,
    BatchFolderImporter? importer,
    DateTime Function()? clock,
    this.requireLargeJobApproval = false,
    this.runtimeService,
    this.storageService,
  }) : _queueRepository = queueRepository ?? BatchQueueRepository(),
       _taskRepository = taskRepository ?? TaskRepository(),
       _importer = importer ?? BatchFolderImporter(),
       _clock = clock ?? DateTime.now;

  final JobApi api;
  JobApi get _api => api;
  final BatchQueueRepository _queueRepository;
  final TaskRepository _taskRepository;
  final BatchFolderImporter _importer;
  final DateTime Function() _clock;
  bool requireLargeJobApproval;
  final MobileRuntimeService? runtimeService;
  final MobileStorageService? storageService;
  MobileResourceBudget? resourceBudget;
  bool resourceConfigurationReady = true;
  int? desiredMemoryBudgetMiB;
  int? desiredMaxConcurrentJobs;
  int newTaskMemoryBudgetMiB = 512;

  /// Native jobs whose Android foreground-service timeout still needs a
  /// quiescent checkpoint. Populate this before [initialize].
  final Set<String> pendingRuntimePauseJobIds = {};
  final List<BatchQueue> _queues = [];
  final Set<String> _inFlight = {};
  final Set<String> _runtimeGuardUnavailableJobs = {};
  final Set<String> _deletingTaskIds = {};
  final Map<String, StitchTask> _taskCache = {};
  final Map<String, int> _generations = {};
  final Map<String, int> _timelineUiSequences = {};
  Future<void> _taskWriteTail = Future.value();
  Future<void> _queueWriteTail = Future.value();
  Future<void> _tickWork = Future.value();
  Timer? _timer;
  bool _loading = false;
  bool _importing = false;
  bool _disposed = false;
  bool _ticking = false;
  String? error;

  String _nextTimelineUiId(String taskId, StitchTimeline timeline) {
    var sequence = _timelineUiSequences[taskId] ?? 0;
    final prefix = 'ui:$taskId:';
    for (final event in timeline.events) {
      if (!event.id.startsWith(prefix)) continue;
      final saved = int.tryParse(event.id.substring(prefix.length));
      if (saved != null && saved > sequence) sequence = saved;
    }
    sequence++;
    _timelineUiSequences[taskId] = sequence;
    return '$prefix$sequence';
  }

  String? _normalizedTimelineStage(String? stage) {
    return canonicalStitchTimelineStage(stage);
  }

  bool _nativeHistoryCoversTaskState(
    StitchTimeline previous,
    StitchTimeline current,
    StitchTask task,
  ) {
    final previousIds = previous.events.map((event) => event.id).toSet();
    final expectedState = task.phase == StitchPhase.exporting
        ? 'running'
        : task.phase.name;
    return current.events.any(
      (event) =>
          event.id.startsWith('native:${task.nativeJobId}:') &&
          !previousIds.contains(event.id) &&
          _normalizedTimelineStage(event.stage) ==
              _normalizedTimelineStage(task.stage) &&
          (event.state == expectedState ||
              (task.phase == StitchPhase.exporting &&
                  event.state == 'queued')) &&
          (task.phase != StitchPhase.exporting || event.operation == 'export'),
    );
  }

  StitchTimeline _mergeTimelineWithoutDuplicateUi(
    StitchTimeline previous,
    StitchTimeline candidate,
  ) {
    final previousIds = previous.events.map((event) => event.id).toSet();
    final merged = previous.merge(candidate);
    final incomingNative = merged.events.where(
      (event) =>
          event.id.startsWith('native:') && !previousIds.contains(event.id),
    );
    if (incomingNative.isEmpty) return merged;
    final filtered = merged.events.where((event) {
      if (!event.id.startsWith('ui:')) return true;
      return !incomingNative.any((native) {
        final nearInTime =
            (native.timestampUtc.difference(event.timestampUtc).inMilliseconds)
                .abs() <=
            const Duration(seconds: 30).inMilliseconds;
        final equivalentState =
            event.state == native.state ||
            (native.operation == 'export' &&
                native.state == 'running' &&
                event.state == 'exporting');
        return nearInTime &&
            _normalizedTimelineStage(event.stage) ==
                _normalizedTimelineStage(native.stage) &&
            event.operation == native.operation &&
            equivalentState;
      });
    }).toList();
    return StitchTimeline(events: List.unmodifiable(filtered));
  }

  int _generation(String id) => _generations[id] ?? 0;
  int _bumpGeneration(String id) => _generations[id] = _generation(id) + 1;
  bool _stillReady(String queueId, String itemId, int generation) =>
      !_disposed &&
      generation == _generation(itemId) &&
      _find(queueId, itemId)?.item.state == BatchItemState.ready;
  String _nativeErrorText(Object? value, String fallback) {
    if (value is String && value.isNotEmpty) return value;
    if (value is Map<String, Object?>) {
      final message = value['message'];
      final code = value['code'];
      if (message is String && message.isNotEmpty) {
        return code is String ? '$code: $message' : message;
      }
    }
    return fallback;
  }

  StitchPhase _phaseForNative(Object? state) => switch (state) {
    'queued' => StitchPhase.queued,
    'running' => StitchPhase.running,
    'pausing' => StitchPhase.pausing,
    'paused' => StitchPhase.paused,
    'completed' => StitchPhase.completed,
    'failed' => StitchPhase.failed,
    'cancelled' => StitchPhase.cancelled,
    _ => StitchPhase.interrupted,
  };

  Future<Map<String, Object?>> _requestPauseAndInspect(String jobId) async {
    try {
      await _api.pause(jobId);
    } on Object {
      // The subsequent status read is authoritative even if pause threw.
    }
    try {
      return await _api.status(jobId);
    } on Object {
      return const {'state': 'unknown'};
    }
  }

  bool _pathIsWithin(String root, String path) {
    final normalizedRoot = p.normalize(p.absolute(root));
    final normalizedPath = p.normalize(p.absolute(path));
    return p.equals(normalizedRoot, normalizedPath) ||
        p.isWithin(normalizedRoot, normalizedPath);
  }

  Future<BatchFolderSnapshot?> _snapshotDirectFolder(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) return null;
    final files = <File>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File &&
            const {
              '.jpg',
              '.jpeg',
            }.contains(p.extension(entity.path).toLowerCase())) {
          files.add(entity);
        }
      }
    } on Object {
      return null;
    }
    files.sort(
      (a, b) => p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase()),
    );
    if (files.isEmpty) return null;
    return BatchFolderSnapshot(
      directory: directory.path,
      files: List.unmodifiable(files),
    );
  }

  Future<void> _saveTask(
    StitchTask task, {
    String? guardItem,
    int? generation,
  }) async {
    final next = _taskWriteTail.then((_) async {
      if (guardItem != null && generation != _generation(guardItem)) return;
      var persisted = task;
      final previous = _taskCache[task.id];
      if (previous != null) {
        persisted = task.copyWith(
          timeline: _mergeTimelineWithoutDuplicateUi(
            previous.timeline,
            task.timeline,
          ),
        );
      }
      final nativeHistoryCoversTransition =
          previous != null &&
          _nativeHistoryCoversTaskState(
            previous.timeline,
            persisted.timeline,
            persisted,
          );
      final inferredOperation =
          const {
            'publishing',
            'published',
            'publish-failed',
          }.contains(persisted.stage)
          ? 'publish'
          : previous?.phase == StitchPhase.exporting ||
                persisted.phase == StitchPhase.exporting
          ? 'export'
          : null;
      final candidateUiCoversTransition = persisted.timeline.events.any(
        (event) =>
            event.id.startsWith('ui:') &&
            _normalizedTimelineStage(event.stage) ==
                _normalizedTimelineStage(persisted.stage) &&
            (inferredOperation == 'publish' ||
                event.state == persisted.phase.name ||
                (persisted.phase == StitchPhase.exporting &&
                    event.state == 'running')) &&
            (inferredOperation == null || event.operation == inferredOperation),
      );
      if (previous != null &&
          !nativeHistoryCoversTransition &&
          !candidateUiCoversTransition &&
          (previous.phase != persisted.phase ||
              _normalizedTimelineStage(previous.stage) !=
                  _normalizedTimelineStage(persisted.stage))) {
        persisted = persisted.copyWith(
          timeline: persisted.timeline.mergeUiEvent(
            id: _nextTimelineUiId(task.id, persisted.timeline),
            kind: previous.phase != persisted.phase ? 'state' : 'stage',
            timestampUtc: _clock().toUtc(),
            stage: _normalizedTimelineStage(task.stage),
            state: persisted.phase.name,
            operation: inferredOperation,
          ),
        );
      }
      await _taskRepository.save(persisted);
      if (await _taskRepository.loadById(task.id) == null) {
        _taskCache.remove(task.id);
      } else {
        _taskCache[task.id] = persisted;
      }
    });
    _taskWriteTail = next.catchError((Object _) {});
    await next;
  }

  StitchTask _mergeNativeEvents(StitchTask task, Map<String, Object?> status) {
    final values = status['events'];
    if (task.nativeJobId == null || values is! List) return task;
    final events = values
        .whereType<Map>()
        .map(
          (value) => value.map((key, value) => MapEntry(key.toString(), value)),
        )
        .toList();
    if (events.isEmpty) return task;
    return task.copyWith(
      timeline: task.timeline.mergeNativeBatch(
        events,
        jobId: task.nativeJobId!,
      ),
    );
  }

  Future<StitchTask> _publishPrivateExport(
    StitchTask task, {
    String? guardItem,
    int? generation,
  }) async {
    final destination = task.exportDirectory;
    final source = task.exportPath;
    if (storageService == null ||
        destination == null ||
        !destination.startsWith('content://') ||
        source == null) {
      return task;
    }
    if (guardItem != null && generation != _generation(guardItem)) {
      return task;
    }
    final started = task.copyWith(
      publishError: '发布失败：发布结果尚未确认。私有整图已保留，可重试发布。',
      timeline: task.timeline.mergeUiEvent(
        id: _nextTimelineUiId(task.id, task.timeline),
        kind: 'publish-started',
        timestampUtc: _clock().toUtc(),
        stage: 'publishing',
        state: 'running',
        operation: 'publish',
      ),
    );
    await _saveTask(started, guardItem: guardItem, generation: generation);
    try {
      final result = await (storageService ?? const MobileStorageService())
          .publishExport(
            source,
            destinationUri: destination,
            mimeType: switch (task.exportFormat) {
              ExportFormat.png => 'image/png',
              ExportFormat.tiff => 'image/tiff',
              ExportFormat.jpegXl => 'image/jxl',
            },
            suggestedName: p.basename(source),
          );
      if (guardItem != null && generation != _generation(guardItem)) {
        return task;
      }
      final published = started.copyWith(
        publishedExportPath: result.uri,
        clearPublishError: true,
        timeline: started.timeline.mergeUiEvent(
          id: _nextTimelineUiId(task.id, started.timeline),
          kind: 'publish',
          timestampUtc: _clock().toUtc(),
          stage: 'published',
          state: 'completed',
          operation: 'publish',
        ),
      );
      await _saveTask(published, guardItem: guardItem, generation: generation);
      return published;
    } on Object catch (error) {
      final failed = started.copyWith(
        publishError: '发布失败：$error。私有整图已保留，可重试发布。',
        timeline: started.timeline.mergeUiEvent(
          id: _nextTimelineUiId(task.id, started.timeline),
          kind: 'publish-failed',
          timestampUtc: _clock().toUtc(),
          stage: 'publish-failed',
          state: 'failed',
          operation: 'publish',
        ),
      );
      await _saveTask(failed, guardItem: guardItem, generation: generation);
      return failed;
    }
  }

  Future<void> retryPublish(String queueId, String itemId) async {
    final found = _find(queueId, itemId);
    if (found == null || found.item.taskId == null) return;
    final task = await _loadTask(found.item);
    if (task == null || task.exportPath == null || task.publishError == null) {
      return;
    }
    final generation = _generation(itemId);
    final result = await _publishPrivateExport(
      task,
      guardItem: itemId,
      generation: generation,
    );
    if (generation != _generation(itemId)) return;
    await _replaceState(
      queueId,
      itemId,
      BatchItemState.completed,
      message:
          result.publishError ??
          result.publishedExportPath ??
          result.exportPath,
    );
  }

  List<BatchQueue> get queues => List.unmodifiable(_queues);
  bool get loading => _loading || _importing;

  Future<void> initialize() async {
    _loading = true;
    if (!_disposed) notifyListeners();
    try {
      _queues
        ..clear()
        ..addAll(await _queueRepository.loadAll());
      for (var index = 0; index < _queues.length; index++) {
        final queue = _queues[index];
        final items = <BatchQueueItem>[];
        for (final item in queue.items) {
          StitchTask? preloadedTask;
          if ((item.state != BatchItemState.running &&
                  item.state != BatchItemState.exporting &&
                  !item.pauseRequested) ||
              item.taskId == null) {
            if (pendingRuntimePauseJobIds.isEmpty || item.taskId == null) {
              if (item.state == BatchItemState.completed &&
                  item.taskId != null) {
                final completedTask = await _loadTask(item);
                items.add(
                  completedTask?.publishError == null
                      ? item
                      : item.copyWith(message: completedTask!.publishError),
                );
              } else {
                items.add(item);
              }
              continue;
            }
            preloadedTask = await _loadTask(item);
            if (preloadedTask?.nativeJobId == null ||
                !pendingRuntimePauseJobIds.contains(
                  preloadedTask!.nativeJobId,
                )) {
              items.add(item);
              continue;
            }
          }
          try {
            final task = preloadedTask ?? await _loadTask(item);
            if (task?.nativeJobId == null) {
              items.add(
                item.copyWith(
                  state: BatchItemState.failed,
                  message: '任务缺少原生作业编号',
                ),
              );
              continue;
            }
            if (pendingRuntimePauseJobIds.contains(task!.nativeJobId)) {
              final inspected = await _requestPauseAndInspect(
                task.nativeJobId!,
              );
              final nativeState = inspected['state'] as String? ?? 'unknown';
              final operation = inspected['operation'] as String? ?? 'render';
              final isQuiescent = const {
                'paused',
                'completed',
                'failed',
                'cancelled',
              }.contains(nativeState);
              if (isQuiescent) {
                pendingRuntimePauseJobIds.remove(task.nativeJobId);
              } else {
                _inFlight.add(item.id);
              }
              final phase = _phaseForNative(nativeState);
              await _saveTask(
                task.copyWith(
                  phase: phase,
                  stage: nativeState == 'completed' && operation != 'export'
                      ? 'export-pending'
                      : task.stage,
                  autoExportOnCompletion:
                      nativeState == 'completed' && operation != 'export'
                      ? false
                      : task.autoExportOnCompletion,
                  clearExportCheckpointPath:
                      nativeState == 'completed' && operation != 'export',
                  pauseReason: isQuiescent
                      ? 'Android 后台运行时限已到；核心状态已确认'
                      : 'Android 后台运行时限已到；正在核对暂停状态',
                ),
              );
              final nextState = switch (nativeState) {
                'paused' => BatchItemState.paused,
                'failed' => BatchItemState.failed,
                'cancelled' => BatchItemState.cancelled,
                'completed' when operation == 'export' =>
                  BatchItemState.exporting,
                'completed' => BatchItemState.paused,
                _ when operation == 'export' => BatchItemState.exporting,
                _ => BatchItemState.running,
              };
              items.add(
                item.copyWith(
                  state: nextState,
                  pauseRequested:
                      !isQuiescent ||
                      nativeState == 'paused' ||
                      (nativeState == 'completed' && operation != 'export'),
                  message: isQuiescent
                      ? nativeState == 'paused'
                            ? '已安全暂停'
                            : '核心作业已结束'
                      : '正在安全暂停；等待核心确认',
                  lastTickAt: isQuiescent ? null : _clock(),
                  clearLastTickAt: isQuiescent,
                  clearEtaSeconds: isQuiescent,
                ),
              );
              continue;
            }
            if (requireLargeJobApproval &&
                task.needsLargeJobConfirmation &&
                !task.hasCurrentLargeJobApproval) {
              final status = await _api.status(task.nativeJobId!);
              final timelineTask = _mergeNativeEvents(task, status);
              var nativeState = status['state'] as String? ?? 'unknown';
              final nativeOperation =
                  status['operation'] as String? ?? 'render';
              if (nativeState == 'completed' && nativeOperation != 'export') {
                await runtimeService?.setProcessingActive(
                  false,
                  jobId: task.nativeJobId!,
                );
                await _saveTask(
                  timelineTask.copyWith(
                    phase: StitchPhase.completed,
                    stage: 'export-pending',
                    clearExportCheckpointPath: true,
                    pauseReason: '大型任务需要重新确认后才能导出',
                  ),
                );
                items.add(
                  item.copyWith(
                    state: BatchItemState.needsApproval,
                    pauseRequested: false,
                    clearLastTickAt: true,
                    clearEtaSeconds: true,
                    message: '大型任务需要确认后才会导出',
                  ),
                );
                continue;
              }
              if (const {
                'queued',
                'running',
                'pausing',
                'exporting',
              }.contains(nativeState)) {
                await _api.pause(task.nativeJobId!);
                for (var attempt = 0; attempt < 40; attempt++) {
                  await Future<void>.delayed(const Duration(milliseconds: 250));
                  nativeState = await _nativeState(task.nativeJobId!);
                  if (nativeState == 'paused' ||
                      !_isNativeActive(nativeState)) {
                    break;
                  }
                }
              }
              await _saveTask(
                timelineTask.copyWith(
                  phase: nativeState == 'paused'
                      ? StitchPhase.paused
                      : StitchPhase.pausing,
                  pauseReason: '大型任务需要重新确认',
                ),
              );
              items.add(
                item.copyWith(
                  state: BatchItemState.needsApproval,
                  pauseRequested: nativeState != 'paused',
                  message: nativeState == 'paused'
                      ? '大型任务需要重新确认'
                      : '正在安全暂停大型任务；确认后才能继续',
                  clearLastTickAt: true,
                  clearEtaSeconds: true,
                ),
              );
              if (nativeState != 'paused' && _isNativeActive(nativeState)) {
                _inFlight.add(item.id);
              }
              continue;
            }
            final status = await _api.status(task.nativeJobId!);
            final timelineTask = _mergeNativeEvents(task, status);
            final state = status['state'] as String? ?? 'paused';
            final operation = status['operation'] as String? ?? 'render';
            final savedDestination =
                status['exportDestination'] as String? ??
                timelineTask.exportCheckpointPath ??
                timelineTask.exportPath;
            if (state == 'completed' && operation == 'export') {
              final output = savedDestination == null
                  ? null
                  : File(savedDestination);
              final fingerprint =
                  output != null &&
                      await output.exists() &&
                      await output.length() > 0
                  ? await _taskRepository.fingerprintFile(savedDestination!)
                  : null;
              if (fingerprint != null) {
                final completedTask = await _publishPrivateExport(
                  timelineTask.copyWith(
                    phase: StitchPhase.completed,
                    exportPath: savedDestination,
                    exportFingerprint: fingerprint,
                    clearExportCheckpointPath: true,
                    progress: 1,
                  ),
                  guardItem: item.id,
                  generation: _generation(item.id),
                );
                await _saveTask(completedTask);
                items.add(
                  item.copyWith(
                    state: BatchItemState.completed,
                    progress: 1,
                    message:
                        completedTask.publishError ??
                        completedTask.publishedExportPath ??
                        savedDestination,
                  ),
                );
              } else {
                await _saveTask(
                  timelineTask.copyWith(
                    phase: StitchPhase.completed,
                    clearExportCheckpointPath: true,
                    error: '核心报告导出完成，但输出文件不存在或为空；保留上次成功输出。',
                  ),
                );
                items.add(
                  item.copyWith(
                    state: BatchItemState.failed,
                    progress: 0.9,
                    message: '核心报告导出完成，但找不到非空整图文件',
                  ),
                );
              }
              continue;
            }
            if (operation == 'export' &&
                savedDestination != null &&
                savedDestination != task.exportCheckpointPath) {
              await _saveTask(
                timelineTask.copyWith(
                  exportCheckpointPath: savedDestination,
                  stage: 'export',
                ),
              );
            }
            if (state == 'completed') {
              items.add(
                item.copyWith(
                  state: BatchItemState.exporting,
                  progress: 0.85,
                  message: '合成完成，等待整图导出',
                ),
              );
              continue;
            }
            if (state == 'failed' || state == 'cancelled') {
              items.add(
                item.copyWith(
                  state: state == 'failed'
                      ? BatchItemState.failed
                      : BatchItemState.cancelled,
                  message: _nativeErrorText(status['error'], state),
                ),
              );
              continue;
            }
            if (item.pauseRequested) {
              if (state == 'paused') {
                items.add(
                  item.copyWith(
                    state: BatchItemState.paused,
                    lastTickAt: null,
                    clearLastTickAt: true,
                    message: '已暂停',
                  ),
                );
              } else {
                if (state == 'running' || state == 'queued') {
                  await _api.pause(task.nativeJobId!);
                }
                _inFlight.add(item.id);
                items.add(
                  item.copyWith(
                    state: BatchItemState.running,
                    lastTickAt: _clock(),
                    message: '继续完成暂停请求',
                  ),
                );
              }
              continue;
            }
            final shouldResume = state == 'paused' || state == 'interrupted';
            if (requireLargeJobApproval && runtimeService != null) {
              final protected = await runtimeService!.setProcessingActive(
                true,
                jobId: task.nativeJobId!,
              );
              if (!protected) {
                final inspected = state == 'paused' || state == 'interrupted'
                    ? status
                    : await _requestPauseAndInspect(task.nativeJobId!);
                final actualState = inspected['state'] as String? ?? 'unknown';
                await runtimeService!.setProcessingActive(
                  false,
                  jobId: task.nativeJobId!,
                );
                await _saveTask(
                  task.copyWith(
                    phase: _phaseForNative(actualState),
                    pauseReason: actualState == 'paused'
                        ? 'Android 无法启动后台运行保护，任务已安全暂停'
                        : 'Android 无法启动后台运行保护，正在核对暂停状态',
                  ),
                );
                if (actualState != 'paused' &&
                    actualState != 'completed' &&
                    actualState != 'failed' &&
                    actualState != 'cancelled') {
                  _inFlight.add(item.id);
                }
                items.add(
                  item.copyWith(
                    state: actualState == 'paused'
                        ? BatchItemState.paused
                        : actualState == 'failed'
                        ? BatchItemState.failed
                        : actualState == 'cancelled'
                        ? BatchItemState.cancelled
                        : actualState == 'completed'
                        ? BatchItemState.exporting
                        : operation == 'export'
                        ? BatchItemState.exporting
                        : BatchItemState.running,
                    pauseRequested:
                        actualState != 'paused' &&
                        actualState != 'completed' &&
                        actualState != 'failed' &&
                        actualState != 'cancelled',
                    clearLastTickAt:
                        actualState == 'paused' ||
                        actualState == 'failed' ||
                        actualState == 'cancelled',
                    lastTickAt:
                        actualState == 'paused' ||
                            actualState == 'failed' ||
                            actualState == 'cancelled'
                        ? null
                        : _clock(),
                    message: actualState == 'paused'
                        ? '无法启动后台运行保护；任务已安全暂停'
                        : '无法启动后台运行保护；正在核对核心暂停状态',
                  ),
                );
                continue;
              }
            }
            if (shouldResume) {
              try {
                await _api.resume(task.nativeJobId!);
              } on NativeJobException catch (exception) {
                if (exception.code == 'RESOURCE_BUSY') {
                  await runtimeService?.setProcessingActive(
                    false,
                    jobId: task.nativeJobId!,
                  );
                  items.add(
                    item.copyWith(
                      state: BatchItemState.ready,
                      message: '等待核心资源以恢复原任务',
                    ),
                  );
                  continue;
                }
                rethrow;
              }
            }
            _inFlight.add(item.id);
            items.add(
              item.copyWith(
                state:
                    operation == 'export' ||
                        item.state == BatchItemState.exporting
                    ? BatchItemState.exporting
                    : BatchItemState.running,
                lastTickAt: _clock(),
                progressSamples: const [],
                clearEtaSeconds: true,
                message: shouldResume ? '已恢复原生任务' : '已连接正在运行的原生任务',
              ),
            );
          } on Object catch (exception) {
            // Keep the native job attached and retry status on the normal poll.
            _inFlight.add(item.id);
            items.add(
              item.copyWith(
                state: item.state,
                message: '恢复状态暂不可用，将自动重试：$exception',
              ),
            );
          }
        }
        _queues[index] = queue.copyWith(items: items);
      }
      await _persistAll();
      _loading = false;
      if (!_disposed) notifyListeners();
      for (final queue in List<BatchQueue>.of(_queues)) {
        final pending = queue.items
            .where(
              (item) =>
                  item.state == BatchItemState.pending && item.taskId == null,
            )
            .toList();
        if (pending.isNotEmpty) {
          List<BatchFolderSnapshot> snapshots;
          try {
            snapshots = await _importer.snapshot(queue.parentDirectory);
          } on Object catch (exception) {
            for (final item in pending) {
              await _replaceState(
                queue.id,
                item.id,
                BatchItemState.failed,
                message: '无法重新读取母目录：$exception',
              );
            }
            continue;
          }
          for (final item in pending) {
            BatchFolderSnapshot? snapshot;
            for (final candidate in snapshots) {
              if (p.normalize(candidate.directory) ==
                  p.normalize(item.sourceDirectory)) {
                snapshot = candidate;
                break;
              }
            }
            if (snapshot == null) {
              await _replaceState(
                queue.id,
                item.id,
                BatchItemState.failed,
                message: '找不到原始子目录',
              );
            } else {
              await _importSnapshot(queue, item, snapshot);
            }
          }
        }
      }
      error = null;
    } on Object catch (exception) {
      error = '读取批处理队列失败：$exception';
    } finally {
      _loading = false;
      if (!_disposed) notifyListeners();
    }
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(tick()),
    );
    unawaited(tick());
  }

  Future<void> addParent(
    String parentPath, {
    ExportFormat outputFormat = ExportFormat.tiff,
    AppSettings? settings,
  }) async {
    if (_importing) return;
    final selectedFormat = settings?.exportFormat ?? outputFormat;
    if (selectedFormat == ExportFormat.jpegXl) {
      final response = await _api.capabilities();
      final caps =
          response['capabilities'] as Map<String, Object?>? ?? const {};
      if (caps['jpegXlAvailable'] != true) {
        throw StateError('核心未报告可用的 JPEG XL 编码器');
      }
    }
    _importing = true;
    if (!_disposed) notifyListeners();
    try {
      // Complete this snapshot before creating any queue task or output folder.
      final snapshots = await _importer.snapshot(parentPath);
      if (snapshots.isEmpty) throw const FormatException('母目录中没有直接子目录');
      final batchId = _taskRepository.createId();
      final parentName = p.basename(p.normalize(parentPath));
      final outputPath = p.join(
        p.dirname(p.normalize(parentPath)),
        '${parentName}_stitched',
      );
      final configuredDestination = settings?.outputDirectory;
      final items = <BatchQueueItem>[];
      for (final snapshot in snapshots) {
        final id = _taskRepository.createId();
        items.add(
          BatchQueueItem(
            id: id,
            name: p.basename(snapshot.directory),
            sourceDirectory: snapshot.directory,
            state: snapshot.error == null
                ? BatchItemState.pending
                : BatchItemState.skipped,
            message: snapshot.error,
          ),
        );
      }
      final queue = BatchQueue(
        id: batchId,
        createdAt: _clock(),
        parentDirectory: parentPath,
        outputDirectory: outputPath,
        items: items,
        outputFormat: selectedFormat,
        exportDestination: configuredDestination,
        performanceOptions: settings?.performance ?? const PerformanceOptions(),
        refineGridNeighbors: settings?.refineGridNeighbors ?? true,
        seamBlendMode: settings?.seamBlendMode ?? SeamBlendMode.deghost,
        localTextureWarp: settings?.localTextureWarp ?? true,
      );
      _queues.insert(0, queue);
      await _save(queue);
      if (!_disposed) notifyListeners();
      for (final snapshot in snapshots) {
        final item = queue.items.firstWhere(
          (value) =>
              p.normalize(value.sourceDirectory) ==
              p.normalize(snapshot.directory),
        );
        if (item.state == BatchItemState.pending) {
          await _importSnapshot(queue, item, snapshot);
        }
      }
      await _releaseStagingIfFullyImported(queue.id, parentPath);
      error = null;
    } on Object catch (exception) {
      error = '导入批次失败：$exception';
    } finally {
      _importing = false;
      if (!_disposed) notifyListeners();
    }
    unawaited(tick());
  }

  /// Adds only explicitly completed device panorama directories. Source paths
  /// are persisted in queue items, so retrying this call after a UI/process
  /// restart cannot create duplicate stitch work.
  Future<void> addCompletedPanoramas(
    List<DwarfDownloadBatch> completedBatches, {
    AppSettings? settings,
  }) async {
    if (_importing || completedBatches.isEmpty) return;
    final validatedPaths = <String>[];
    for (final requested in completedBatches) {
      if (!requested.isComplete) {
        throw StateError('DWARF download ${requested.id} is not complete');
      }
      final validator = DwarfDownloadService(
        rootDirectory: p.dirname(requested.directory),
      );
      try {
        final persisted = await validator.loadBatch(requested.id);
        if (persisted == null ||
            !persisted.isComplete ||
            !p.equals(
              p.normalize(p.absolute(persisted.directory)),
              p.normalize(p.absolute(requested.directory)),
            )) {
          throw StateError(
            'DWARF download ${requested.id} has no matching complete manifest',
          );
        }
        for (final file in persisted.files) {
          final normalizedFile = p.normalize(p.absolute(file.path));
          if (!file.complete ||
              !p.isWithin(
                p.normalize(p.absolute(persisted.directory)),
                normalizedFile,
              ) ||
              !await File(file.path).exists() ||
              await File(file.path).length() < 4) {
            throw StateError(
              'DWARF download ${requested.id} contains an incomplete source file',
            );
          }
          final source = File(file.path);
          final length = await source.length();
          final expectedLength = file.original.size;
          if (expectedLength != null && length != expectedLength) {
            throw StateError(
              'DWARF download ${requested.id} contains a source with an unexpected size',
            );
          }
          final digest = await sha256.bind(source.openRead()).first;
          if (file.sha256 == null || digest.toString() != file.sha256) {
            throw StateError(
              'DWARF download ${requested.id} contains a source that failed SHA-256 verification',
            );
          }
        }
        final snapshot = await _snapshotDirectFolder(persisted.directory);
        if (snapshot == null ||
            snapshot.files.length != persisted.files.length) {
          throw StateError(
            'DWARF download ${requested.id} contains files outside its completed manifest',
          );
        }
        validatedPaths.add(persisted.directory);
      } finally {
        validator.close();
      }
    }
    final uniquePaths = <String>[];
    for (final path in validatedPaths) {
      final normalized = p.normalize(p.absolute(path));
      if (uniquePaths.any((existing) => p.equals(existing, normalized))) {
        continue;
      }
      final alreadyQueued = _queues.any(
        (queue) => queue.items.any(
          (item) => p.equals(
            p.normalize(p.absolute(item.sourceDirectory)),
            normalized,
          ),
        ),
      );
      if (!alreadyQueued) uniquePaths.add(normalized);
    }
    if (uniquePaths.isEmpty) {
      error = null;
      return;
    }
    _importing = true;
    if (!_disposed) notifyListeners();
    try {
      final snapshots = <BatchFolderSnapshot>[];
      for (final path in uniquePaths) {
        final snapshot = await _snapshotDirectFolder(path);
        snapshots.add(
          snapshot ??
              BatchFolderSnapshot(
                directory: path,
                files: const [],
                error: '全景目录没有可导入的 JPEG 原片',
              ),
        );
      }
      final parentDirectory = p.dirname(uniquePaths.first);
      final batchId = _taskRepository.createId();
      final items = <BatchQueueItem>[];
      for (final snapshot in snapshots) {
        final matchingBatch = completedBatches.firstWhere(
          (batch) => p.equals(
            p.normalize(p.absolute(batch.directory)),
            p.normalize(p.absolute(snapshot.directory)),
          ),
        );
        final title = matchingBatch.metadata['title'];
        items.add(
          BatchQueueItem(
            id: _taskRepository.createId(),
            name: title is String && title.trim().isNotEmpty
                ? title.trim()
                : p.basename(snapshot.directory),
            sourceDirectory: snapshot.directory,
            state: snapshot.error == null
                ? BatchItemState.pending
                : BatchItemState.skipped,
            message: snapshot.error,
          ),
        );
      }
      final outputPath = p.join(
        p.dirname(parentDirectory),
        '${p.basename(parentDirectory)}_stitched',
      );
      final queue = BatchQueue(
        id: batchId,
        createdAt: _clock(),
        parentDirectory: parentDirectory,
        outputDirectory: outputPath,
        items: items,
        outputFormat: settings?.exportFormat ?? ExportFormat.tiff,
        exportDestination: settings?.outputDirectory,
        performanceOptions: settings?.performance ?? const PerformanceOptions(),
        refineGridNeighbors: settings?.refineGridNeighbors ?? true,
        seamBlendMode: settings?.seamBlendMode ?? SeamBlendMode.deghost,
        localTextureWarp: settings?.localTextureWarp ?? true,
      );
      _queues.insert(0, queue);
      await _save(queue);
      if (!_disposed) notifyListeners();
      for (final snapshot in snapshots) {
        final item = queue.items.firstWhere(
          (candidate) =>
              p.equals(candidate.sourceDirectory, snapshot.directory),
        );
        if (item.state == BatchItemState.pending) {
          await _importSnapshot(queue, item, snapshot);
        }
      }
      error = null;
    } on Object catch (exception) {
      error = '设备全景导入失败：$exception';
    } finally {
      _importing = false;
      if (!_disposed) notifyListeners();
    }
    unawaited(tick());
  }

  Future<void> _releaseStagingIfFullyImported(
    String queueId,
    String parentPath,
  ) async {
    if (storageService == null) return;
    BatchQueue? queue;
    for (final candidate in _queues) {
      if (candidate.id == queueId) {
        queue = candidate;
        break;
      }
    }
    if (queue == null || queue.items.isEmpty) return;
    for (final item in queue.items) {
      final taskId = item.taskId;
      if (taskId == null) return;
      final task = await _taskRepository.loadById(taskId);
      if (task == null ||
          _pathIsWithin(parentPath, task.sourceDirectory) ||
          task.photos.any(
            (photo) => _pathIsWithin(parentPath, photo.storedPath),
          )) {
        return;
      }
    }
    await storageService!.releaseBatchParent(parentPath);
  }

  Future<void> _importSnapshot(
    BatchQueue queue,
    BatchQueueItem baseItem,
    BatchFolderSnapshot snapshot, {
    String? taskId,
  }) async {
    try {
      final importedTaskId = taskId ?? baseItem.id;
      final taskDirectory = (await _taskRepository.directoryFor(
        importedTaskId,
      )).path;
      final imported = await _importer.importFolder(snapshot, taskDirectory);
      final task = StitchTask(
        id: importedTaskId,
        createdAt: _clock(),
        sourceDirectory: imported.inputDirectory,
        outputDirectory: p.join(taskDirectory, 'render'),
        photos: imported.photos,
        grid: imported.grid,
        horizontalFovDegrees: imported.fovDegrees ?? 45,
        memoryBudgetMiB: newTaskMemoryBudgetMiB,
        workers: 1,
        phase: StitchPhase.imported,
        cameraProfileId: imported.cameraProfileId,
        performanceOptions: queue.performanceOptions,
        exportFormat: queue.outputFormat,
        refineGridNeighbors: queue.refineGridNeighbors,
        seamBlendMode: queue.seamBlendMode,
        localTextureWarp: queue.localTextureWarp,
        exportDirectory: queue.exportDestination ?? queue.outputDirectory,
      );
      await _saveTask(task);
      final needsSettings = imported.needsLayout || !imported.cameraVerified;
      final message = needsSettings
          ? [
              if (imported.needsLayout) '需要设置行列',
              if (!imported.cameraVerified) '需要设置相机视角',
            ].join('；')
          : imported.hasIndexedGrid
          ? '按文件名识别 ${imported.grid.rows}×${imported.grid.columns}'
          : '估算为 ${imported.grid.rows}×${imported.grid.columns}，按行排列';
      final found = _find(queue.id, baseItem.id);
      if (found == null) return;
      await _replaceItem(
        found.index,
        baseItem.copyWith(
          taskId: importedTaskId,
          durableInputDirectory: imported.inputDirectory,
          state: needsSettings
              ? BatchItemState.needsSettings
              : BatchItemState.ready,
          estimatedLayout: imported.estimatedLayout,
          message: message,
        ),
      );
      await tick();
    } on Object catch (exception) {
      final found = _find(queue.id, baseItem.id);
      if (found != null) {
        await _replaceItem(
          found.index,
          baseItem.copyWith(
            state: BatchItemState.failed,
            message: '导入失败：$exception',
          ),
        );
      }
    }
  }

  Future<void> setSettings({
    required String queueId,
    required String itemId,
    required int rows,
    required int columns,
    required double horizontalFovDegrees,
  }) async {
    final found = _find(queueId, itemId);
    if (found == null) return;
    final settingsTask = await _loadTask(found.item);
    if (rows < 1 ||
        columns < 1 ||
        !GridOptions.productFits(rows, columns) ||
        rows * columns != settingsTask?.photos.length) {
      throw const FormatException('行列数必须与原片数量一致');
    }
    if (!horizontalFovDegrees.isFinite ||
        horizontalFovDegrees <= 1 ||
        horizontalFovDegrees >= 179) {
      throw const FormatException('水平视角需介于 1° 与 179°');
    }
    final task = await _loadTask(found.item);
    if (task == null) throw const FileSystemException('找不到该队列任务');
    final filenameLayout =
        task.grid.mode == GridMode.filename &&
        GridMapping.fromFilenames(task.photos).isValid &&
        GridMapping.fromFilenames(task.photos).rows == rows &&
        GridMapping.fromFilenames(task.photos).columns == columns;
    final updated = task.copyWith(
      grid: filenameLayout
          ? task.grid
          : GridOptions(mode: GridMode.sequence, rows: rows, columns: columns),
      horizontalFovDegrees: horizontalFovDegrees,
      clearCameraProfileId: true,
      cameraCalibrationOverridden: true,
    );
    await _saveTask(updated);
    final item = found.item.copyWith(
      state: BatchItemState.ready,
      estimatedLayout: !filenameLayout,
      message: filenameLayout
          ? '已确认文件名中的 $rows×$columns 网格与相机视角'
          : '已确认 $rows×$columns 顺序排列与相机视角',
    );
    await _replaceItem(found.index, item);
    await _tickAfterCurrent();
  }

  Future<void> approveLargeJob(String queueId, String itemId) async {
    final found = _find(queueId, itemId);
    if (found == null || found.item.state != BatchItemState.needsApproval) {
      return;
    }
    final task = await _loadTask(found.item);
    if (task == null) throw const FileSystemException('找不到该队列任务');
    if (!requireLargeJobApproval || !task.needsLargeJobConfirmation) {
      throw StateError('此队列项目不需要大型任务确认');
    }
    if (task.nativeJobId != null) {
      _runtimeGuardUnavailableJobs.remove(task.nativeJobId);
      var state = await _nativeState(task.nativeJobId!);
      if (_isNativeActive(state)) {
        await _api.pause(task.nativeJobId!);
        for (var attempt = 0; attempt < 40; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          state = await _nativeState(task.nativeJobId!);
          if (!_isNativeActive(state)) break;
        }
        if (_isNativeActive(state)) {
          throw StateError('大型任务尚未安全暂停，确认后不能继续');
        }
      }
    }
    await _saveTask(
      task.copyWith(largeJobApprovalScope: task.currentLargeJobApprovalScope),
    );
    final current = _find(queueId, itemId);
    if (current == null || current.item.state != BatchItemState.needsApproval) {
      return;
    }
    await _replaceItem(
      current.index,
      current.item.copyWith(
        state: BatchItemState.ready,
        clearMessage: true,
        pauseRequested: false,
      ),
    );
    await _tickAfterCurrent();
  }

  Future<bool> pauseJobByNativeId(String jobId) async {
    for (final queue in _queues) {
      for (final item in queue.items) {
        if (item.taskId == null) continue;
        final task = await _loadTask(item);
        if (task?.nativeJobId != jobId) continue;
        await pause(queue.id, item.id);
        final state = await _nativeState(jobId);
        final quiescent = const {
          'paused',
          'completed',
          'failed',
          'cancelled',
        }.contains(state);
        if (quiescent) pendingRuntimePauseJobIds.remove(jobId);
        return quiescent;
      }
    }
    return false;
  }

  Future<(int, int, double)> settingsFor(String queueId, String itemId) async {
    final found = _find(queueId, itemId);
    final task = found == null ? null : await _loadTask(found.item);
    if (task == null) return (1, 1, 45.0);
    return (task.grid.rows, task.grid.columns, task.horizontalFovDegrees);
  }

  Future<void> pause(String queueId, String itemId) async {
    final found = _find(queueId, itemId);
    if (found == null) return;
    final generation = _bumpGeneration(found.item.id);
    final queued =
        found.item.state == BatchItemState.ready ||
        found.item.state == BatchItemState.pending;
    await _replaceItem(
      found.index,
      found.item.copyWith(
        state: queued ? BatchItemState.paused : found.item.state,
        pauseRequested: true,
        message: queued ? '已暂停' : '已提交暂停请求',
      ),
    );
    if (found.item.taskId == null) {
      return;
    }
    final task = await _loadTask(found.item);
    if (task?.nativeJobId == null) {
      await _replaceState(
        queueId,
        itemId,
        BatchItemState.paused,
        message: '已暂停',
      );
      return;
    }
    final inspected = await _requestPauseAndInspect(task!.nativeJobId!);
    final state = inspected['state'] as String? ?? 'unknown';
    final operation = inspected['operation'] as String? ?? 'render';
    final completedRenderTimeout =
        pendingRuntimePauseJobIds.contains(task.nativeJobId) &&
        state == 'completed' &&
        operation != 'export';
    if (completedRenderTimeout) {
      _inFlight.remove(found.item.id);
      await _saveTask(
        task.copyWith(
          phase: StitchPhase.completed,
          stage: 'export-pending',
          autoExportOnCompletion: false,
          clearExportCheckpointPath: true,
          pauseReason: 'Android 后台运行时限已到；等待手动恢复导出',
        ),
        guardItem: found.item.id,
        generation: generation,
      );
      await runtimeService?.setProcessingActive(
        false,
        jobId: task.nativeJobId!,
      );
      final current = _find(queueId, itemId);
      if (current != null && generation == _generation(itemId)) {
        await _replaceItem(
          current.index,
          current.item.copyWith(
            state: BatchItemState.paused,
            pauseRequested: true,
            message: '后台时间到；整图导出已暂停，点击恢复继续',
            clearLastTickAt: true,
            clearEtaSeconds: true,
          ),
        );
      }
      return;
    }
    final isPaused = state == 'paused';
    final isTerminal = const {
      'completed',
      'failed',
      'cancelled',
    }.contains(state);
    if (isPaused || isTerminal) {
      _inFlight.remove(found.item.id);
    } else {
      _inFlight.add(found.item.id);
    }
    await _saveTask(
      task.copyWith(
        phase: _phaseForNative(state),
        pauseReason: isPaused ? '已暂停' : '已请求暂停，等待核心确认',
      ),
      guardItem: found.item.id,
      generation: generation,
    );
    final current = _find(queueId, itemId);
    if (current == null || generation != _generation(itemId)) return;
    final nextState = isPaused
        ? BatchItemState.paused
        : state == 'failed'
        ? BatchItemState.failed
        : state == 'cancelled'
        ? BatchItemState.cancelled
        : state == 'completed'
        ? operation == 'export'
              ? BatchItemState.completed
              : BatchItemState.exporting
        : operation == 'export'
        ? BatchItemState.exporting
        : BatchItemState.running;
    await _replaceItem(
      current.index,
      current.item.copyWith(
        state: nextState,
        pauseRequested: !isPaused && !isTerminal,
        message: isPaused ? '已暂停' : '已请求暂停，等待核心确认',
        elapsedSeconds: isPaused
            ? _elapsed(current.item)
            : current.item.elapsedSeconds,
        lastTickAt: isPaused || isTerminal ? null : _clock(),
        clearLastTickAt: isPaused || isTerminal,
        progressSamples: isPaused ? const [] : current.item.progressSamples,
        etaSeconds: isPaused ? null : current.item.etaSeconds,
        clearEtaSeconds: isPaused,
      ),
    );
  }

  Future<void> cancel(String queueId, String itemId) async {
    final found = _find(queueId, itemId);
    if (found == null) return;
    _bumpGeneration(found.item.id);
    _inFlight.remove(found.item.id);
    if (found.item.taskId == null) {
      await _replaceItem(
        found.index,
        found.item.copyWith(
          state: BatchItemState.cancelled,
          pauseRequested: false,
          message: '已取消',
        ),
      );
      return;
    }
    final task = await _loadTask(found.item);
    if (task?.nativeJobId != null) {
      try {
        await _api.cancel(task!.nativeJobId!);
        await _saveTask(task.copyWith(phase: StitchPhase.cancelled));
      } on Object catch (exception) {
        error = '取消失败：$exception';
      }
    }
    await _replaceItem(
      found.index,
      found.item.copyWith(
        state: BatchItemState.cancelled,
        pauseRequested: false,
        message: '已取消',
      ),
    );
    unawaited(tick());
  }

  /// Removes a local task only after any native job is confirmed stopped.
  /// The task repository keeps a durable tombstone and never deletes inputs,
  /// tiles or exported images.
  Future<void> removeTask(String taskId) async {
    if (_loading || _importing) {
      throw StateError('队列正在恢复或导入，请稍后再删除任务');
    }
    final refs = <(BatchQueue, BatchQueueItem)>[
      for (final queue in _queues)
        for (final item in queue.items)
          if (item.taskId == taskId) (queue, item),
    ];
    for (final ref in refs) {
      _bumpGeneration(ref.$2.id);
      _deletingTaskIds.add(ref.$2.id);
      _inFlight.add(ref.$2.id);
    }
    // Drain already-enqueued task writes before asking the repository to tombstone.
    await _taskWriteTail;
    try {
      var task = await _taskRepository.loadById(taskId);
      task ??= _taskCache[taskId];
      if (task == null) throw StateError('找不到本地任务记录');
      final jobId = task.nativeJobId;
      if (jobId != null) {
        var state = await _nativeState(jobId);
        if (_isNativeActive(state)) {
          await _api.cancel(jobId);
          for (var attempt = 0; attempt < 120; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
            state = await _nativeState(jobId);
            if (!_isNativeActive(state)) break;
          }
        }
        if (!_isNativeTerminal(state)) {
          throw StateError('原生任务状态为 $state；停止确认前保留本地任务');
        }
      } else if (_isActivePhase(task.phase)) {
        throw StateError('任务缺少原生作业编号；无法确认已停止');
      }
      // Commit the task tombstone before dropping durable queue ownership. If
      // storage denies the metadata write, leave the queue reference available
      // for an explicit retry and keep the task visible in the local cache.
      await _taskRepository.removeTaskRecord(taskId);
      for (final ref in refs) {
        while (true) {
          final current = _find(ref.$1.id, ref.$2.id);
          if (current == null) break;
          final queue = current.queue;
          final next = queue.copyWith(
            items: [
              for (final item in queue.items)
                if (item.id != ref.$2.id) item,
            ],
          );
          await _save(next);
          final live = _find(ref.$1.id, ref.$2.id);
          if (live == null) break;
          if (!identical(live.queue, queue)) {
            // Recompute after every awaited write so a concurrent queue edit
            // cannot be overwritten by a stale removal snapshot.
            continue;
          }
          _queues[live.index] = next;
          break;
        }
      }
      _taskCache.remove(taskId);
      for (final ref in refs) {
        _inFlight.remove(ref.$2.id);
      }
      notifyListeners();
    } finally {
      for (final ref in refs) {
        _deletingTaskIds.remove(ref.$2.id);
      }
    }
  }

  Future<void> removeQueueItem(String queueId, String itemId) async {
    final found = _find(queueId, itemId);
    if (found == null) return;
    if (found.item.taskId != null) {
      await removeTask(found.item.taskId!);
      return;
    }
    if (_loading || _importing) {
      throw StateError('队列正在恢复或导入，请稍后再删除');
    }
    if (found.item.state == BatchItemState.running ||
        found.item.state == BatchItemState.exporting) {
      throw StateError('任务仍在处理中；停止后才能删除队列项目');
    }
    _bumpGeneration(found.item.id);
    _inFlight.remove(found.item.id);
    final queue = found.queue.copyWith(
      items: [
        for (final item in found.queue.items)
          if (item.id != itemId) item,
      ],
    );
    _queues[found.index] = queue;
    await _save(queue);
    notifyListeners();
  }

  Future<String> _nativeState(String jobId) async =>
      (await _api.status(jobId))['state'] as String? ?? 'unknown';

  bool _isNativeActive(String state) =>
      state == 'queued' ||
      state == 'running' ||
      state == 'pausing' ||
      state == 'exporting';

  bool _isNativeTerminal(String state) =>
      const {'completed', 'failed', 'cancelled', 'paused'}.contains(state);

  bool _isActivePhase(StitchPhase phase) => const {
    StitchPhase.queued,
    StitchPhase.running,
    StitchPhase.pausing,
    StitchPhase.exporting,
  }.contains(phase);

  Future<void> retry(String queueId, String itemId) async {
    final found = _find(queueId, itemId);
    if (found == null) return;
    var task = await _loadTask(found.item);
    if (task?.nativeJobId != null) {
      _runtimeGuardUnavailableJobs.remove(task!.nativeJobId);
    }
    if (task == null) {
      final queue = _queues.firstWhere((value) => value.id == queueId);
      BatchFolderSnapshot? snapshot = await _snapshotDirectFolder(
        found.item.sourceDirectory,
      );
      final oldTaskId = found.item.taskId;
      if (snapshot == null && oldTaskId != null) {
        final oldTask = await _taskRepository.loadById(oldTaskId);
        if (oldTask != null &&
            found.item.durableInputDirectory != null &&
            p.normalize(found.item.durableInputDirectory!) ==
                p.normalize(oldTask.sourceDirectory)) {
          snapshot = await _snapshotDirectFolder(oldTask.sourceDirectory);
        }
      }
      if (snapshot == null && oldTaskId != null) {
        final oldTaskDirectory = await _taskRepository.directoryFor(oldTaskId);
        snapshot = await _snapshotDirectFolder(
          p.join(oldTaskDirectory.path, 'input'),
        );
      }
      if (snapshot == null) {
        try {
          final snapshots = await _importer.snapshot(queue.parentDirectory);
          for (final candidate in snapshots) {
            if (p.normalize(candidate.directory) ==
                p.normalize(found.item.sourceDirectory)) {
              snapshot = candidate;
              break;
            }
          }
        } on Object {
          // The durable per-task input copy is preferred when staging was released.
        }
      }
      if (snapshot == null) {
        await _replaceItem(
          found.index,
          found.item.copyWith(
            state: BatchItemState.failed,
            message: '找不到原始子目录，无法重新导入',
          ),
        );
        return;
      }
      final taskId = _taskRepository.createId();
      final pending = found.item.copyWith(
        taskId: taskId,
        clearDurableInputDirectory: true,
        state: BatchItemState.pending,
        clearMessage: true,
      );
      await _replaceItem(found.index, pending);
      await _importSnapshot(queue, pending, snapshot, taskId: taskId);
      await _releaseStagingIfFullyImported(queue.id, queue.parentDirectory);
      unawaited(tick());
      return;
    }
    if (task.phase == StitchPhase.completed) {
      await _replaceItem(
        found.index,
        found.item.copyWith(
          state: BatchItemState.exporting,
          pauseRequested: false,
          progress: 0.85,
          etaSeconds: null,
          clearEtaSeconds: true,
          progressSamples: const [],
          clearMessage: true,
        ),
      );
    } else {
      if (task.phase == StitchPhase.failed ||
          task.phase == StitchPhase.cancelled) {
        task = await _taskRepository.duplicateForNewRun(
          task,
          autoExportOnCompletion: false,
        );
      }
      await _replaceItem(
        found.index,
        found.item.copyWith(
          taskId: task.id,
          state: BatchItemState.ready,
          pauseRequested: false,
          progress: 0,
          etaSeconds: null,
          clearEtaSeconds: true,
          progressSamples: const [],
          clearMessage: true,
        ),
      );
    }
    unawaited(tick());
  }

  Future<void> tick() {
    if (_ticking) return _tickWork;
    if (_loading || _disposed) return Future<void>.value();
    _ticking = true;
    final work = _runTick().whenComplete(() => _ticking = false);
    _tickWork = work;
    return work;
  }

  Future<void> _tickAfterCurrent() async {
    if (_ticking) await _tickWork;
    await tick();
  }

  Future<void> _runTick() async {
    await _pollRunning();
    if (_disposed) return;
    await _startReady();
  }

  Future<void> _pollRunning() async {
    for (final queue in List<BatchQueue>.of(_queues)) {
      for (final item in List<BatchQueueItem>.of(queue.items)) {
        if (_deletingTaskIds.contains(item.id)) continue;
        if (item.state == BatchItemState.exporting &&
            !_inFlight.contains(item.id)) {
          final task = await _loadTask(item);
          if (task?.nativeJobId != null) {
            await _recoverExport(queue, item, task!);
          }
          continue;
        }
        if (!_inFlight.contains(item.id) || item.taskId == null) continue;
        final task = await _loadTask(item);
        if (task?.nativeJobId == null) {
          _inFlight.remove(item.id);
          continue;
        }
        final generation = _generation(item.id);
        try {
          var status = await _api.status(task!.nativeJobId!);
          if (pendingRuntimePauseJobIds.contains(task.nativeJobId) &&
              _isNativeActive(status['state'] as String? ?? 'unknown')) {
            status = await _requestPauseAndInspect(task.nativeJobId!);
          }
          final current = _find(queue.id, item.id);
          if (current == null ||
              generation != _generation(item.id) ||
              !_inFlight.contains(item.id) ||
              current.item.state == BatchItemState.cancelled ||
              (current.item.state == BatchItemState.paused &&
                  !current.item.pauseRequested) ||
              current.item.state == BatchItemState.failed) {
            continue;
          }
          final state = status['state'] as String? ?? 'running';
          final operation = status['operation'] as String? ?? 'render';
          final progress = (status['progress'] as num? ?? item.progress)
              .toDouble()
              .clamp(0, 1)
              .toDouble();
          final phaseProgress = operation == 'export'
              ? ((progress - 0.92) / 0.08).clamp(0, 1).toDouble()
              : progress;
          final stage = status['stage'] as String? ?? task.stage;
          final priorSamples = current.item.progressOperation == operation
              ? current.item.progressSamples
              : const <ProgressSample>[];
          final samples = _appendSample(priorSamples, phaseProgress);
          final eta = _estimateEta(samples);
          final taskWithTimeline = _mergeNativeEvents(task, status);
          final updatedTask = taskWithTimeline.copyWith(
            progress: progress,
            stage: stage,
            phase: _taskPhaseForStatus(state, operation),
            resultStats: status['resultStats'] is Map<String, Object?>
                ? {
                    ...status['resultStats'] as Map<String, Object?>,
                    if (status['exportFormat'] is String)
                      'exportFormat': status['exportFormat'],
                    if (status['tiffVariant'] is String)
                      'tiffVariant': status['tiffVariant'],
                  }
                : task.resultStats,
            clearError: state == 'running' || state == 'queued',
            error: state == 'failed'
                ? _nativeErrorText(status['error'], '合成失败')
                : null,
          );
          await _saveTask(
            updatedTask,
            guardItem: item.id,
            generation: generation,
          );
          if (generation != _generation(item.id) ||
              !_inFlight.contains(item.id)) {
            continue;
          }
          final exportDestination = status['exportDestination'] as String?;
          var operationTask = updatedTask;
          if (operation == 'export' && exportDestination != null) {
            if (state == 'completed') {
              operationTask = updatedTask.copyWith(
                exportCheckpointPath: exportDestination,
                stage: 'export',
              );
            } else {
              operationTask = updatedTask.copyWith(
                exportCheckpointPath: exportDestination,
                stage: 'export',
              );
            }
            await _saveTask(
              operationTask,
              guardItem: item.id,
              generation: generation,
            );
          }
          if (generation != _generation(item.id) ||
              !_inFlight.contains(item.id)) {
            continue;
          }
          if (state == 'completed' && operation == 'export') {
            await runtimeService?.setProcessingActive(
              false,
              jobId: task.nativeJobId!,
            );
            _inFlight.remove(item.id);
            final path =
                exportDestination ??
                task.exportCheckpointPath ??
                task.exportPath;
            final file = path == null ? null : File(path);
            if (file != null &&
                await file.exists() &&
                await file.length() > 0 &&
                generation == _generation(item.id)) {
              final fingerprint = await _taskRepository.fingerprintFile(path!);
              if (fingerprint == null) {
                await _saveTask(
                  operationTask.copyWith(
                    phase: StitchPhase.completed,
                    clearExportCheckpointPath: true,
                    error: '核心报告导出完成，但输出文件不存在或为空；保留上次成功输出。',
                  ),
                  guardItem: item.id,
                  generation: generation,
                );
                await _replaceState(
                  queue.id,
                  item.id,
                  BatchItemState.failed,
                  progress: 0.9,
                  message: '核心报告导出完成，但找不到非空整图文件',
                );
                continue;
              }
              final completedTask = await _publishPrivateExport(
                operationTask.copyWith(
                  phase: StitchPhase.completed,
                  exportPath: path,
                  exportFingerprint: fingerprint,
                  clearExportCheckpointPath: true,
                  progress: 1,
                ),
                guardItem: item.id,
                generation: generation,
              );
              await _saveTask(
                completedTask.copyWith(
                  phase: StitchPhase.completed,
                  exportPath: path,
                  exportFingerprint: fingerprint,
                  clearExportCheckpointPath: true,
                  progress: 1,
                ),
                guardItem: item.id,
                generation: generation,
              );
              if (generation != _generation(item.id)) continue;
              await _replaceState(
                queue.id,
                item.id,
                BatchItemState.completed,
                progress: 1,
                message:
                    completedTask.publishError ??
                    completedTask.publishedExportPath ??
                    path,
              );
            } else {
              await _saveTask(
                operationTask.copyWith(
                  phase: StitchPhase.completed,
                  clearExportCheckpointPath: true,
                  error: '核心报告导出完成，但输出文件不存在或为空；保留上次成功输出。',
                ),
                guardItem: item.id,
                generation: generation,
              );
              await _replaceState(
                queue.id,
                item.id,
                BatchItemState.failed,
                progress: 0.9,
                message: '核心报告导出完成，但找不到整图文件',
              );
            }
          } else if (state == 'completed') {
            await _exportCompleted(
              queue,
              item,
              operationTask,
              expectedGeneration: generation,
            );
          } else if (state == 'failed' ||
              state == 'cancelled' ||
              state == 'paused') {
            pendingRuntimePauseJobIds.remove(task.nativeJobId);
            if (state == 'paused' ||
                state == 'failed' ||
                state == 'cancelled') {
              await runtimeService?.setProcessingActive(
                false,
                jobId: task.nativeJobId!,
              );
              _runtimeGuardUnavailableJobs.remove(task.nativeJobId);
            }
            _inFlight.remove(item.id);
            final latest = _find(queue.id, item.id);
            if (latest == null || generation != _generation(item.id)) continue;
            final needsApproval =
                state == 'paused' &&
                requireLargeJobApproval &&
                updatedTask.needsLargeJobConfirmation &&
                !updatedTask.hasCurrentLargeJobApproval;
            await _replaceItem(
              latest.index,
              latest.item.copyWith(
                state: state == 'failed'
                    ? BatchItemState.failed
                    : state == 'paused'
                    ? needsApproval
                          ? BatchItemState.needsApproval
                          : BatchItemState.paused
                    : BatchItemState.cancelled,
                pauseRequested: state == 'paused'
                    ? latest.item.pauseRequested
                    : false,
                progress: progress,
                elapsedSeconds: _elapsed(item),
                lastTickAt: null,
                clearLastTickAt: true,
                etaSeconds: null,
                clearEtaSeconds: true,
                progressSamples: state == 'paused' ? const [] : samples,
                message: state == 'failed'
                    ? updatedTask.error
                    : state == 'paused'
                    ? '已暂停'
                    : '已取消',
              ),
            );
          } else if (operation == 'export') {
            final found = _find(queue.id, item.id);
            if (found != null && generation == _generation(item.id)) {
              await _replaceItem(
                found.index,
                found.item.copyWith(
                  state: BatchItemState.exporting,
                  progress: 0.85 + (phaseProgress * 0.15),
                  etaSeconds: eta,
                  clearEtaSeconds: eta == null,
                  elapsedSeconds: _elapsed(item),
                  lastTickAt: _clock(),
                  progressSamples: samples,
                  progressOperation: operation,
                  message: '导出整图 ${queue.outputFormat.label}',
                ),
              );
            }
          } else {
            final found = _find(queue.id, item.id);
            if (found != null &&
                generation == _generation(item.id) &&
                !found.item.pauseRequested) {
              await _replaceItem(
                found.index,
                found.item.copyWith(
                  state: BatchItemState.running,
                  progress: progress.clamp(0, 1) * 0.85,
                  etaSeconds: eta,
                  clearEtaSeconds: eta == null,
                  progressSamples: samples,
                  progressOperation: operation,
                  elapsedSeconds: _elapsed(item),
                  lastTickAt: _clock(),
                  message: stage,
                ),
              );
            }
          }
        } on Object catch (exception) {
          final found = _find(queue.id, item.id);
          if (found != null &&
              generation == _generation(item.id) &&
              _inFlight.contains(item.id) &&
              found.item.state != BatchItemState.cancelled &&
              found.item.state != BatchItemState.paused) {
            await _replaceItem(
              found.index,
              found.item.copyWith(
                state: BatchItemState.running,
                message: '状态暂时不可用，保留原任务并重试：$exception',
              ),
            );
          }
        }
      }
    }
  }

  Future<void> _exportCompleted(
    BatchQueue queue,
    BatchQueueItem item,
    StitchTask task, {
    int? expectedGeneration,
  }) async {
    final generation = expectedGeneration ?? _generation(item.id);
    final initial = _find(queue.id, item.id);
    if (generation != _generation(item.id) ||
        initial == null ||
        initial.item.state == BatchItemState.cancelled ||
        initial.item.state == BatchItemState.paused) {
      return;
    }
    if (initial.item.pauseRequested ||
        (task.nativeJobId != null &&
            pendingRuntimePauseJobIds.contains(task.nativeJobId))) {
      _inFlight.remove(item.id);
      await _saveTask(
        task.copyWith(
          phase: StitchPhase.completed,
          stage: 'export-pending',
          autoExportOnCompletion: false,
          clearExportCheckpointPath: true,
          pauseReason: '后台运行已暂停；等待手动恢复导出',
        ),
        guardItem: item.id,
        generation: generation,
      );
      if (task.nativeJobId != null) {
        await runtimeService?.setProcessingActive(
          false,
          jobId: task.nativeJobId!,
        );
      }
      final current = _find(queue.id, item.id);
      if (current != null && generation == _generation(item.id)) {
        await _replaceItem(
          current.index,
          current.item.copyWith(
            state: BatchItemState.paused,
            pauseRequested: true,
            message: '整图导出已暂停，点击恢复继续',
            clearLastTickAt: true,
            clearEtaSeconds: true,
          ),
        );
      }
      return;
    }
    if (task.phase == StitchPhase.exporting && _inFlight.contains(item.id)) {
      return;
    }
    if (requireLargeJobApproval &&
        task.needsLargeJobConfirmation &&
        !task.hasCurrentLargeJobApproval) {
      await _deferCompletedExport(
        queue,
        item,
        task,
        BatchItemState.needsApproval,
        '大型任务需要确认后才会开始',
        generation,
      );
      return;
    }
    if (!await _completedExportFitsMemoryBudget(task)) {
      await _deferCompletedExport(
        queue,
        item,
        task,
        BatchItemState.ready,
        '等待共享内存预算释放后再导出整图',
        generation,
      );
      return;
    }
    if (requireLargeJobApproval && runtimeService != null) {
      if (!resourceConfigurationReady) {
        await _deferCompletedExport(
          queue,
          item,
          task,
          BatchItemState.ready,
          '无法设置 Android 渲染资源预算，已暂缓启动。',
          generation,
        );
        return;
      }
      try {
        resourceBudget = await runtimeService!.readResourceBudget();
      } on Object {
        // Keep the last conservative budget and still require a live thermal check when available.
      }
      if (resourceBudget?.shouldDeferNewStarts == true) {
        await _deferCompletedExport(
          queue,
          item,
          task,
          BatchItemState.ready,
          '设备温度较高，待温度降低后再启动新任务。',
          generation,
        );
        return;
      }
      if (_runtimeGuardUnavailableJobs.contains(task.nativeJobId)) {
        _inFlight.remove(item.id);
        return;
      }
      final protected = await runtimeService!.setProcessingActive(
        true,
        jobId: task.nativeJobId!,
      );
      if (!protected) {
        _runtimeGuardUnavailableJobs.add(task.nativeJobId!);
        await _deferCompletedExport(
          queue,
          item,
          task,
          BatchItemState.ready,
          '无法启动 Android 后台运行保护；整图导出尚未启动',
          generation,
        );
        return;
      }
    }
    if (!await _completedExportFitsMemoryBudget(task)) {
      await _deferCompletedExport(
        queue,
        item,
        task,
        BatchItemState.ready,
        '共享资源预算已变化，等待释放后再导出整图',
        generation,
      );
      return;
    }
    _inFlight.add(item.id);
    await _replaceState(
      queue.id,
      item.id,
      BatchItemState.exporting,
      progress: 0.85,
      message: '合成完成，正在导出整图 ${queue.outputFormat.label}',
    );
    if (generation != _generation(item.id)) {
      _inFlight.remove(item.id);
      return;
    }
    try {
      final selectedPath = queue.exportDestination;
      final output = Directory(
        selectedPath != null &&
                selectedPath.isNotEmpty &&
                !selectedPath.startsWith('content://')
            ? selectedPath
            : queue.outputDirectory,
      );
      await output.create(recursive: true);
      if (generation != _generation(item.id)) {
        _inFlight.remove(item.id);
        return;
      }
      final destination = await _uniqueExportFile(
        output,
        '${item.name}-${task.id}',
        queue.outputFormat,
      );
      if (generation != _generation(item.id)) {
        _inFlight.remove(item.id);
        return;
      }
      final exportTask = task.copyWith(
        phase: StitchPhase.exporting,
        exportCheckpointPath: destination.path,
        stage: 'export',
      );
      await _saveTask(exportTask, guardItem: item.id, generation: generation);
      if (generation != _generation(item.id)) {
        _inFlight.remove(item.id);
        return;
      }
      if (!await _completedExportFitsMemoryBudget(task)) {
        await _deferCompletedExport(
          queue,
          item,
          task,
          BatchItemState.ready,
          '共享资源预算已变化，等待释放后再导出整图',
          generation,
        );
        return;
      }
      final response = await _api.export(task.nativeJobId!, destination.path);
      final found = _find(queue.id, item.id);
      if (generation != _generation(item.id) ||
          found == null ||
          found.item.state == BatchItemState.cancelled ||
          found.item.state == BatchItemState.paused) {
        _inFlight.remove(item.id);
        return;
      }
      final state = response['state'] as String? ?? 'running';
      final fingerprint = state == 'completed'
          ? await _taskRepository.fingerprintFile(destination.path)
          : null;
      if (state == 'completed' && fingerprint == null) {
        await runtimeService?.setProcessingActive(
          false,
          jobId: task.nativeJobId!,
        );
        _inFlight.remove(item.id);
        await _saveTask(
          exportTask.copyWith(
            phase: StitchPhase.completed,
            clearExportCheckpointPath: true,
            error: '核心报告导出完成，但输出文件不存在或为空；保留上次成功输出。',
          ),
          guardItem: item.id,
          generation: generation,
        );
        await _replaceState(
          queue.id,
          item.id,
          BatchItemState.failed,
          progress: 0.9,
          message: '核心报告导出完成，但输出文件不存在或为空',
        );
        return;
      }
      var exportResultTask = _mergeNativeEvents(exportTask, response).copyWith(
        phase: _taskPhaseForStatus(
          state,
          response['operation'] as String? ?? 'export',
        ),
        exportFingerprint: fingerprint,
        exportPath: state == 'completed' ? destination.path : task.exportPath,
        clearExportCheckpointPath: state == 'completed',
      );
      if (state == 'completed') {
        exportResultTask = await _publishPrivateExport(
          exportResultTask,
          guardItem: item.id,
          generation: generation,
        );
      }
      await _saveTask(
        exportResultTask,
        guardItem: item.id,
        generation: generation,
      );
      if (generation != _generation(item.id)) {
        _inFlight.remove(item.id);
        return;
      }
      if (state == 'completed') {
        await runtimeService?.setProcessingActive(
          false,
          jobId: task.nativeJobId!,
        );
        _inFlight.remove(item.id);
        await _replaceState(
          queue.id,
          item.id,
          BatchItemState.completed,
          progress: 1,
          message:
              exportResultTask.publishError ??
              exportResultTask.publishedExportPath ??
              destination.path,
        );
      } else if (state == 'failed' || state == 'cancelled') {
        await runtimeService?.setProcessingActive(
          false,
          jobId: task.nativeJobId!,
        );
        _inFlight.remove(item.id);
        await _replaceState(
          queue.id,
          item.id,
          BatchItemState.failed,
          progress: 0.9,
          message: _nativeErrorText(response['error'], '整图导出失败'),
        );
      } else {
        await _replaceState(
          queue.id,
          item.id,
          BatchItemState.exporting,
          progress: 0.9,
          message: '导出整图 ${queue.outputFormat.label}',
        );
      }
    } on NativeJobException catch (exception) {
      _inFlight.remove(item.id);
      if (generation != _generation(item.id)) {
        _inFlight.remove(item.id);
        return;
      }
      if (exception.code == 'RESOURCE_BUSY') {
        await _replaceState(
          queue.id,
          item.id,
          BatchItemState.exporting,
          progress: 0.9,
          message: '等待核心资源后自动导出',
        );
      } else {
        await _replaceState(
          queue.id,
          item.id,
          BatchItemState.failed,
          message: '整图导出失败：${exception.message}',
        );
      }
    } on Object catch (exception) {
      _inFlight.remove(item.id);
      if (generation != _generation(item.id)) return;
      await _replaceState(
        queue.id,
        item.id,
        BatchItemState.failed,
        message: '整图导出失败：$exception',
      );
    }
  }

  Future<bool> _completedExportFitsMemoryBudget(StitchTask task) async {
    final jobId = task.nativeJobId;
    if (jobId == null) return false;
    try {
      final status = await _api.status(jobId);
      final capsResponse = await _api.capabilities();
      final caps =
          capsResponse['capabilities'] as Map<String, Object?>? ?? const {};
      final requested =
          (status['memoryBudgetMiB'] as num? ?? task.memoryBudgetMiB).toInt();
      final nativeLimit = (caps['totalMemoryBudgetMiB'] as num? ?? 1024)
          .toInt();
      final effectiveLimit = desiredMemoryBudgetMiB == null
          ? nativeLimit
          : math.min(nativeLimit, desiredMemoryBudgetMiB!);
      final held = (caps['reservedMemoryMiB'] as num? ?? 0).toInt();
      final activeJobs = (caps['activeJobs'] as num? ?? 0).toInt();
      final configuredJobs = (caps['maxConcurrentJobs'] as num? ?? 1).toInt();
      final slotLimit = desiredMaxConcurrentJobs == null
          ? configuredJobs
          : math.min(configuredJobs, desiredMaxConcurrentJobs!);
      return requested <= effectiveLimit &&
          held + requested <= effectiveLimit &&
          activeJobs < slotLimit;
    } on Object {
      return false;
    }
  }

  Future<void> _deferCompletedExport(
    BatchQueue queue,
    BatchQueueItem item,
    StitchTask task,
    BatchItemState state,
    String message,
    int generation,
  ) async {
    _inFlight.remove(item.id);
    await _saveTask(
      task.copyWith(
        phase: StitchPhase.completed,
        stage: 'export-pending',
        clearExportCheckpointPath: true,
      ),
      guardItem: item.id,
      generation: generation,
    );
    if (task.nativeJobId != null) {
      await runtimeService?.setProcessingActive(
        false,
        jobId: task.nativeJobId!,
      );
    }
    await _replaceState(queue.id, item.id, state, message: message);
  }

  Future<void> _recoverExport(
    BatchQueue queue,
    BatchQueueItem item,
    StitchTask task, {
    int? expectedGeneration,
  }) async {
    final generation = expectedGeneration ?? _generation(item.id);
    try {
      final status = await _api.status(task.nativeJobId!);
      final timelineTask = _mergeNativeEvents(task, status);
      if (generation != _generation(item.id)) return;
      final operation = status['operation'] as String? ?? 'render';
      final state = status['state'] as String? ?? 'paused';
      final destination =
          status['exportDestination'] as String? ??
          timelineTask.exportCheckpointPath ??
          timelineTask.exportPath;
      if (operation != 'export' && state == 'completed') {
        await _exportCompleted(
          queue,
          item,
          timelineTask,
          expectedGeneration: generation,
        );
        return;
      }
      if (operation != 'export') {
        await _replaceState(
          queue.id,
          item.id,
          BatchItemState.failed,
          message: '原生任务的导出状态缺失',
        );
        return;
      }
      if (operation == 'export' &&
          destination != null &&
          destination != task.exportCheckpointPath) {
        await _saveTask(
          timelineTask.copyWith(
            exportCheckpointPath: destination,
            stage: 'export',
          ),
        );
        if (generation != _generation(item.id)) return;
      }
      if (state == 'completed') {
        await runtimeService?.setProcessingActive(
          false,
          jobId: task.nativeJobId!,
        );
        final file = destination == null ? null : File(destination);
        if (file != null && await file.exists() && await file.length() > 0) {
          final fingerprint = await _taskRepository.fingerprintFile(
            destination!,
          );
          final latest = _find(queue.id, item.id);
          if (latest == null || latest.item.state == BatchItemState.cancelled) {
            return;
          }
          if (fingerprint != null) {
            final completedTask = await _publishPrivateExport(
              timelineTask.copyWith(
                phase: StitchPhase.completed,
                exportPath: destination,
                exportFingerprint: fingerprint,
                clearExportCheckpointPath: true,
                progress: 1,
              ),
              guardItem: item.id,
              generation: generation,
            );
            await _saveTask(completedTask);
            await _replaceState(
              queue.id,
              item.id,
              BatchItemState.completed,
              progress: 1,
              message:
                  completedTask.publishError ??
                  completedTask.publishedExportPath ??
                  destination,
            );
          } else {
            await _saveTask(
              timelineTask.copyWith(
                phase: StitchPhase.completed,
                clearExportCheckpointPath: true,
                error: '核心报告导出完成，但输出文件不存在或为空；保留上次成功输出。',
              ),
            );
            await _replaceState(
              queue.id,
              item.id,
              BatchItemState.failed,
              message: '核心报告导出完成，但找不到非空整图文件',
            );
          }
        } else {
          await _saveTask(
            task.copyWith(
              phase: StitchPhase.completed,
              clearExportCheckpointPath: true,
              error: '核心报告导出完成，但输出文件不存在或为空；保留上次成功输出。',
            ),
          );
          await _replaceState(
            queue.id,
            item.id,
            BatchItemState.failed,
            message: '核心报告导出完成，但找不到整图文件',
          );
        }
      } else if (state == 'paused' || state == 'interrupted') {
        if (requireLargeJobApproval && runtimeService != null) {
          final protected = await runtimeService!.setProcessingActive(
            true,
            jobId: task.nativeJobId!,
          );
          if (!protected) {
            _runtimeGuardUnavailableJobs.add(task.nativeJobId!);
            await runtimeService!.setProcessingActive(
              false,
              jobId: task.nativeJobId!,
            );
            await _saveTask(
              task.copyWith(
                phase: _phaseForNative(state),
                pauseReason: '无法启动 Android 后台运行保护；导出保持暂停',
              ),
            );
            await _replaceState(
              queue.id,
              item.id,
              BatchItemState.paused,
              message: '无法启动后台运行保护；导出保持暂停',
            );
            return;
          }
        }
        await _api.resume(task.nativeJobId!);
        if (generation != _generation(item.id)) return;
        _inFlight.add(item.id);
        final current = _find(queue.id, item.id);
        if (current != null) {
          await _replaceItem(
            current.index,
            current.item.copyWith(lastTickAt: _clock(), message: '恢复整图导出'),
          );
        }
      } else if (state == 'failed' || state == 'cancelled') {
        await runtimeService?.setProcessingActive(
          false,
          jobId: task.nativeJobId!,
        );
        await _replaceState(
          queue.id,
          item.id,
          BatchItemState.failed,
          message: _nativeErrorText(status['error'], '整图导出失败'),
        );
      } else {
        if (requireLargeJobApproval && runtimeService != null) {
          final protected = await runtimeService!.setProcessingActive(
            true,
            jobId: task.nativeJobId!,
          );
          if (!protected) {
            _runtimeGuardUnavailableJobs.add(task.nativeJobId!);
            final inspected = await _requestPauseAndInspect(task.nativeJobId!);
            final actualState = inspected['state'] as String? ?? 'unknown';
            await runtimeService!.setProcessingActive(
              false,
              jobId: task.nativeJobId!,
            );
            await _saveTask(
              task.copyWith(
                phase: _phaseForNative(actualState),
                pauseReason: '无法启动 Android 后台运行保护；正在核对暂停状态',
              ),
            );
            if (actualState == 'paused') {
              await _replaceState(
                queue.id,
                item.id,
                BatchItemState.paused,
                message: '无法启动后台运行保护；任务已安全暂停',
              );
              return;
            }
          }
        }
        _inFlight.add(item.id);
        final current = _find(queue.id, item.id);
        if (current != null) {
          await _replaceItem(
            current.index,
            current.item.copyWith(lastTickAt: _clock(), message: '继续导出整图'),
          );
        }
      }
    } on NativeJobException catch (exception) {
      if (exception.code == 'RESOURCE_BUSY') return;
      final current = _find(queue.id, item.id);
      if (current != null) {
        await _replaceItem(
          current.index,
          current.item.copyWith(message: '等待原生导出状态：${exception.message}'),
        );
      }
    } on Object catch (exception) {
      final current = _find(queue.id, item.id);
      if (current != null) {
        await _replaceItem(
          current.index,
          current.item.copyWith(message: '等待原生导出状态：$exception'),
        );
      }
    }
  }

  Future<void> _startReady() async {
    if (_disposed || !_api.isAvailable) return;
    if (requireLargeJobApproval && !resourceConfigurationReady) return;
    if (requireLargeJobApproval && runtimeService != null) {
      try {
        resourceBudget = await runtimeService!.readResourceBudget();
      } on Object {
        // Retain the conservative initialization reading if a refresh fails.
      }
      if (resourceBudget?.shouldDeferNewStarts == true) return;
    }
    Map<String, Object?> caps;
    try {
      final response = await _api.capabilities();
      caps = response['capabilities'] as Map<String, Object?>? ?? const {};
    } on Object catch (exception) {
      error = '无法读取核心资源：$exception';
      if (!_disposed) notifyListeners();
      return;
    }
    final configuredMemory = (caps['totalMemoryBudgetMiB'] as num? ?? 1024)
        .toInt();
    final configuredJobs = (caps['maxConcurrentJobs'] as num? ?? 1).toInt();
    if (desiredMemoryBudgetMiB != null &&
        (configuredMemory != desiredMemoryBudgetMiB ||
            (desiredMaxConcurrentJobs != null &&
                configuredJobs != desiredMaxConcurrentJobs))) {
      try {
        final updated = await _api.configureResources(
          totalCpuWorkers: (caps['totalCpuWorkers'] as num? ?? 1).toInt(),
          totalMemoryBudgetMiB: desiredMemoryBudgetMiB!,
          maxConcurrentJobs: desiredMaxConcurrentJobs ?? configuredJobs,
        );
        caps = updated['capabilities'] as Map<String, Object?>? ?? caps;
      } on NativeJobException catch (exception) {
        if (exception.code != 'RESOURCE_BUSY') rethrow;
        // Keep active reservations. The desired cap below prevents any new
        // starts until it can be applied on a later queue tick.
      }
    }
    var reservedWorkers = (caps['reservedWorkers'] as num? ?? 0).toInt();
    final totalWorkers = (caps['totalCpuWorkers'] as num? ?? 1).toInt();
    final logical = (caps['logicalCpuCount'] as num? ?? 1).toInt();
    var reservedMemory = (caps['reservedMemoryMiB'] as num? ?? 0).toInt();
    final configuredTotalMemory = (caps['totalMemoryBudgetMiB'] as num? ?? 1024)
        .toInt();
    final totalMemory = desiredMemoryBudgetMiB == null
        ? configuredTotalMemory
        : math.min(configuredTotalMemory, desiredMemoryBudgetMiB!);
    var activeJobs = (caps['activeJobs'] as num? ?? 0).toInt();
    final configuredMaxJobs = (caps['maxConcurrentJobs'] as num? ?? 1).toInt();
    final maxJobs = desiredMaxConcurrentJobs == null
        ? configuredMaxJobs
        : math.min(configuredMaxJobs, desiredMaxConcurrentJobs!);
    final maxWorkers = (caps['maxWorkersPerJob'] as num? ?? 32).toInt();
    final candidates = [
      for (final queue in _queues)
        for (final item in queue.items)
          if (item.state == BatchItemState.ready &&
              !_inFlight.contains(item.id) &&
              (item.taskId == null || !_deletingTaskIds.contains(item.id)))
            (queue, item),
    ];
    for (final candidate in candidates) {
      if (_disposed || activeJobs >= maxJobs) break;
      final queue = candidate.$1;
      final item = candidate.$2;
      final generation = _generation(item.id);
      if (!_stillReady(queue.id, item.id, generation)) {
        continue;
      }
      var task = await _loadTask(item);
      if (!_stillReady(queue.id, item.id, generation)) {
        continue;
      }
      if (task == null) {
        await _replaceState(
          queue.id,
          item.id,
          BatchItemState.failed,
          message: '任务记录丢失',
        );
        continue;
      }
      if (requireLargeJobApproval &&
          task.needsLargeJobConfirmation &&
          !task.hasCurrentLargeJobApproval) {
        await _replaceState(
          queue.id,
          item.id,
          BatchItemState.needsApproval,
          message: '大型任务需要确认后才会开始',
        );
        continue;
      }
      if (task.exportFormat == ExportFormat.jpegXl &&
          caps['jpegXlAvailable'] != true) {
        await _replaceState(
          queue.id,
          item.id,
          BatchItemState.failed,
          message: '核心未报告可用的 JPEG XL 无损编码器；已阻止启动。',
        );
        continue;
      }
      if (task.phase == StitchPhase.completed &&
          task.stage == 'export-pending') {
        await _exportCompleted(
          queue,
          item,
          task,
          expectedGeneration: generation,
        );
        continue;
      }
      final startIntent = task.stage == 'start-intent';
      final jobState = File(p.join(task.outputDirectory, 'job-state.json'));
      final recoveredIntent = startIntent && await jobState.exists();
      if (!_stillReady(queue.id, item.id, generation)) continue;
      if (recoveredIntent) {
        final recoveredJobId = await _readRecoveredJobId(
          jobState,
          task.outputDirectory,
        );
        if (!_stillReady(queue.id, item.id, generation)) continue;
        if (recoveredJobId == null) {
          await _replaceState(
            queue.id,
            item.id,
            BatchItemState.failed,
            message: '原生任务状态路径与渲染目录不匹配',
          );
          continue;
        }
        task = task.copyWith(nativeJobId: recoveredJobId);
        await _saveTask(task, guardItem: item.id, generation: generation);
        if (!_stillReady(queue.id, item.id, generation)) continue;
      }
      final resuming =
          task.nativeJobId != null &&
          task.phase != StitchPhase.completed &&
          (!startIntent || recoveredIntent);
      var nativeOperationStatus = const <String, Object?>{};
      if (resuming) {
        try {
          nativeOperationStatus = await _api.status(task.nativeJobId!);
          if (!_stillReady(queue.id, item.id, generation)) {
            continue;
          }
        } on Object catch (exception) {
          if (_stillReady(queue.id, item.id, generation)) {
            await _replaceState(
              queue.id,
              item.id,
              BatchItemState.ready,
              message: '等待连接原生任务：$exception',
            );
          }
          continue;
        }
        if (!_stillReady(queue.id, item.id, generation)) continue;
        final nativeState =
            nativeOperationStatus['state'] as String? ?? 'paused';
        final nativeOperation =
            nativeOperationStatus['operation'] as String? ?? 'render';
        if (nativeState == 'failed' || nativeState == 'cancelled') {
          if (_stillReady(queue.id, item.id, generation)) {
            await _replaceState(
              queue.id,
              item.id,
              nativeState == 'failed'
                  ? BatchItemState.failed
                  : BatchItemState.cancelled,
              message: _nativeErrorText(
                nativeOperationStatus['error'],
                nativeState,
              ),
            );
          }
          continue;
        }
        if (nativeState == 'completed') {
          final destination =
              nativeOperationStatus['exportDestination'] as String?;
          if (!_stillReady(queue.id, item.id, generation)) continue;
          if (nativeOperation == 'export') {
            await _recoverExport(
              queue,
              item,
              task.copyWith(
                exportCheckpointPath: destination ?? task.exportCheckpointPath,
                stage: 'export',
              ),
              expectedGeneration: generation,
            );
          } else {
            final current = _find(queue.id, item.id);
            if (current != null) {
              await _replaceItem(
                current.index,
                current.item.copyWith(
                  state: BatchItemState.exporting,
                  progress: 0.85,
                  message: '合成完成，等待 ${task.exportFormat.label} 导出',
                ),
              );
              await _exportCompleted(
                queue,
                current.item.copyWith(
                  state: BatchItemState.exporting,
                  progress: 0.85,
                ),
                task,
                expectedGeneration: generation,
              );
            }
          }
          continue;
        }
        if (nativeState != 'paused' && nativeState != 'interrupted') {
          _inFlight.add(item.id);
          final current = _find(queue.id, item.id);
          if (current != null && _stillReady(queue.id, item.id, generation)) {
            await _replaceItem(
              current.index,
              current.item.copyWith(
                state: nativeOperation == 'export'
                    ? BatchItemState.exporting
                    : BatchItemState.running,
                lastTickAt: _clock(),
                message: '已连接正在运行的原生任务',
              ),
            );
          }
          continue;
        }
      }
      final requestedMemory = resuming
          ? ((nativeOperationStatus['memoryBudgetMiB'] as num?)?.toInt() ??
                task.memoryBudgetMiB)
          : task.memoryBudgetMiB.clamp(128, 128 * 1024).toInt();
      final budget = resourceBudget;
      final mobileMemory =
          !resuming && requireLargeJobApproval && budget != null
          ? math
                .min(requestedMemory, budget.recommendedTotalMemoryBudgetMiB)
                .toInt()
          : requestedMemory;
      final memory = !resuming && desiredMemoryBudgetMiB != null
          ? math.min(mobileMemory, desiredMemoryBudgetMiB!).toInt()
          : mobileMemory;
      final availableWorkers = totalWorkers - reservedWorkers;
      final requestedWorkers = resuming
          ? ((nativeOperationStatus['operationWorkers'] as num?)?.toInt() ??
                (nativeOperationStatus['workersEffective'] as num?)?.toInt() ??
                task.workers)
          : math
                .min(
                  math.min(math.min(task.photos.length, logical), maxWorkers),
                  availableWorkers,
                )
                .toInt();
      final perJobWorkerLimit = budget == null
          ? maxWorkers
          : budget.recommendedTotalCpuWorkers;
      final conservativeOneWorker =
          budget != null &&
          (budget.recommendedTotalMemoryBudgetMiB <= 512 ||
              budget.isStorageConstrained);
      final workers = requireLargeJobApproval
          ? math
                .min(
                  requestedWorkers,
                  conservativeOneWorker ? 1 : perJobWorkerLimit,
                )
                .toInt()
          : requestedWorkers;
      if (workers < 1 || reservedMemory + memory > totalMemory) continue;
      final anticipatedJobId = task.nativeJobId ?? task.outputDirectory;
      if (requireLargeJobApproval && runtimeService != null) {
        if (_runtimeGuardUnavailableJobs.contains(anticipatedJobId)) {
          continue;
        }
        final protected = await runtimeService!.setProcessingActive(
          true,
          jobId: anticipatedJobId,
        );
        if (!protected) {
          _runtimeGuardUnavailableJobs.add(anticipatedJobId);
          await runtimeService!.setProcessingActive(
            false,
            jobId: anticipatedJobId,
          );
          await _replaceState(
            queue.id,
            item.id,
            BatchItemState.ready,
            message: '无法启动 Android 后台运行保护；核心任务尚未启动',
          );
          continue;
        }
      }
      _inFlight.add(item.id);
      reservedWorkers += workers;
      reservedMemory += memory;
      activeJobs++;
      try {
        Map<String, Object?> response;
        if (resuming) {
          final nativeState =
              nativeOperationStatus['state'] as String? ?? 'paused';
          response = nativeState == 'paused' || nativeState == 'interrupted'
              ? await _api.resume(task.nativeJobId!)
              : nativeOperationStatus;
        } else {
          final output = Directory(task.outputDirectory);
          if (await _directoryHasEntries(output)) {
            throw const FileSystemException('任务渲染目录已有内容，拒绝覆盖');
          }
          if (!_stillReady(queue.id, item.id, generation)) {
            _inFlight.remove(item.id);
            continue;
          }
          await output.create(recursive: true);
          if (!_stillReady(queue.id, item.id, generation)) {
            _inFlight.remove(item.id);
            continue;
          }
          final intent = task.copyWith(
            nativeJobId: output.path,
            phase: StitchPhase.queued,
            workers: workers,
            stage: 'start-intent',
          );
          await _saveTask(intent, guardItem: item.id, generation: generation);
          if (!_stillReady(queue.id, item.id, generation)) {
            _inFlight.remove(item.id);
            continue;
          }
          response = await _api.start(
            buildSphericalRequest(task.copyWith(workers: workers)),
            output.path,
            memoryBudgetMiB: memory,
            workers: workers,
          );
        }
        final returnedJobId =
            response['jobId'] as String? ??
            task.nativeJobId ??
            task.outputDirectory;
        if (requireLargeJobApproval && runtimeService != null) {
          if (returnedJobId != anticipatedJobId) {
            await runtimeService!.setProcessingActive(
              false,
              jobId: anticipatedJobId,
            );
          }
          final guarded = await runtimeService!.setProcessingActive(
            true,
            jobId: returnedJobId,
          );
          if (!guarded) {
            _runtimeGuardUnavailableJobs.add(returnedJobId);
            final inspected = await _requestPauseAndInspect(returnedJobId);
            final actualState = inspected['state'] as String? ?? 'unknown';
            await runtimeService!.setProcessingActive(
              false,
              jobId: returnedJobId,
            );
            await _saveTask(
              task.copyWith(
                nativeJobId: returnedJobId,
                phase: _phaseForNative(actualState),
                pauseReason: actualState == 'paused'
                    ? 'Android 无法启动后台运行保护，任务已安全暂停'
                    : 'Android 无法启动后台运行保护，正在核对暂停状态',
              ),
              guardItem: item.id,
              generation: generation,
            );
            if (actualState == 'paused' ||
                actualState == 'completed' ||
                actualState == 'failed' ||
                actualState == 'cancelled') {
              _inFlight.remove(item.id);
            }
            await _replaceItem(
              _find(queue.id, item.id)!.index,
              _find(queue.id, item.id)!.item.copyWith(
                state: actualState == 'paused'
                    ? BatchItemState.paused
                    : actualState == 'completed'
                    ? BatchItemState.exporting
                    : actualState == 'failed'
                    ? BatchItemState.failed
                    : actualState == 'cancelled'
                    ? BatchItemState.cancelled
                    : BatchItemState.running,
                pauseRequested:
                    actualState != 'paused' &&
                    actualState != 'completed' &&
                    actualState != 'failed' &&
                    actualState != 'cancelled',
                lastTickAt:
                    actualState == 'paused' ||
                        actualState == 'completed' ||
                        actualState == 'failed' ||
                        actualState == 'cancelled'
                    ? null
                    : _clock(),
                clearLastTickAt:
                    actualState == 'paused' ||
                    actualState == 'completed' ||
                    actualState == 'failed' ||
                    actualState == 'cancelled',
                message: actualState == 'paused'
                    ? '无法启动后台运行保护；任务已安全暂停'
                    : '无法启动后台运行保护；正在核对核心暂停状态',
              ),
            );
            continue;
          }
        }
        if (generation != _generation(item.id)) {
          try {
            final current = _find(queue.id, item.id)?.item;
            if (current?.pauseRequested == true) {
              await _api.pause(returnedJobId);
            } else {
              await _api.cancel(returnedJobId);
            }
          } on Object {
            // The native operation may already have stopped; keep its persisted identity for recovery.
          }
          final stopped = task.copyWith(
            nativeJobId: returnedJobId,
            phase: _find(queue.id, item.id)?.item.pauseRequested == true
                ? StitchPhase.paused
                : StitchPhase.cancelled,
            stage: 'stopped-after-start',
          );
          await _saveTask(stopped);
          _inFlight.remove(item.id);
          continue;
        }
        final updated = task.copyWith(
          nativeJobId: returnedJobId,
          phase: _taskPhase(response['state'] as String? ?? 'queued'),
          workers: (response['workersEffective'] as num?)?.toInt() ?? workers,
          memoryBudgetMiB: memory,
          stage: response['stage'] as String? ?? 'queued',
          clearError: true,
        );
        await _saveTask(updated, guardItem: item.id, generation: generation);
        if (generation != _generation(item.id)) continue;
        final operation = response['operation'] as String? ?? updated.stage;
        final current = _find(queue.id, item.id);
        if (current != null && generation == _generation(item.id)) {
          await _replaceItem(
            current.index,
            current.item.copyWith(
              state: operation == 'export'
                  ? BatchItemState.exporting
                  : BatchItemState.running,
              lastTickAt: _clock(),
              message: updated.stage,
            ),
          );
        }
      } on NativeJobException catch (exception) {
        if (!_stillReady(queue.id, item.id, generation)) {
          _inFlight.remove(item.id);
          continue;
        }
        _inFlight.remove(item.id);
        if (exception.code == 'RESOURCE_BUSY') {
          if (!resuming) {
            final waiting = task.copyWith(
              clearNativeJobId: true,
              phase: StitchPhase.imported,
              stage: 'ready',
              workers: 1,
            );
            await _saveTask(waiting);
            if (!_stillReady(queue.id, item.id, generation)) continue;
          }
          await _replaceState(
            queue.id,
            item.id,
            BatchItemState.ready,
            message: '等待核心资源',
          );
          break;
        }
        await _replaceState(
          queue.id,
          item.id,
          BatchItemState.failed,
          message: '启动失败：${exception.message}',
        );
      } on Object catch (exception) {
        if (!_stillReady(queue.id, item.id, generation)) {
          _inFlight.remove(item.id);
          continue;
        }
        final hasNativeIntent = await jobState.exists();
        if (!_stillReady(queue.id, item.id, generation)) continue;
        if (hasNativeIntent) {
          await _replaceState(
            queue.id,
            item.id,
            BatchItemState.running,
            message: '原生任务已创建，正在重新连接：$exception',
          );
        } else {
          _inFlight.remove(item.id);
          await _replaceState(
            queue.id,
            item.id,
            BatchItemState.failed,
            message: '启动失败：$exception',
          );
        }
      }
    }
  }

  Future<File> _uniqueExportFile(
    Directory directory,
    String name,
    ExportFormat format,
  ) async {
    final stem = p
        .basename(name)
        .replaceFirst(RegExp(r'\.(?:png|tiff?)$', caseSensitive: false), '')
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    for (var suffix = 1; suffix < 10000; suffix++) {
      final file = File(
        p.join(
          directory.path,
          suffix == 1
              ? '$stem.${format.extension}'
              : '$stem-$suffix.${format.extension}',
        ),
      );
      if (!await FileSystemEntity.type(
        file.path,
        followLinks: false,
      ).then((type) => type != FileSystemEntityType.notFound)) {
        return file;
      }
    }
    throw const FileSystemException('无法分配不冲突的整图文件名');
  }

  Future<bool> _directoryHasEntries(Directory directory) async {
    if (!await directory.exists()) return false;
    await for (final _ in directory.list(followLinks: false)) {
      return true;
    }
    return false;
  }

  Future<String?> _readRecoveredJobId(
    File stateFile,
    String expectedOutput,
  ) async {
    try {
      final decoded = jsonDecode(await stateFile.readAsString());
      if (decoded is! Map<String, Object?>) return null;
      final value = decoded['job_id'];
      if (value is! String || !_sameNativePath(value, expectedOutput)) {
        return null;
      }
      return value;
    } on Object {
      return null;
    }
  }

  bool _sameNativePath(String left, String right) =>
      nativeJobPathsMatch(left, right);

  List<ProgressSample> _appendSample(
    List<ProgressSample> current,
    double progress,
  ) {
    final now = _clock();
    if (current.isNotEmpty &&
        now.difference(current.last.at) < const Duration(seconds: 2)) {
      return current;
    }
    return [
      ...current.where(
        (sample) => now.difference(sample.at) <= const Duration(minutes: 10),
      ),
      ProgressSample(now, progress),
    ];
  }

  int? _estimateEta(List<ProgressSample> samples) {
    if (samples.length < 3 ||
        samples.last.at.difference(samples.first.at) <
            const Duration(seconds: 5)) {
      return null;
    }
    final elapsed =
        samples.last.at.difference(samples.first.at).inMilliseconds / 1000;
    final rate = (samples.last.progress - samples.first.progress) / elapsed;
    if (rate <= 0 || !rate.isFinite) return null;
    return ((1 - samples.last.progress) / rate).ceil();
  }

  int _elapsed(BatchQueueItem item) {
    final since = item.lastTickAt;
    if (since == null) return item.elapsedSeconds;
    return item.elapsedSeconds +
        _clock().difference(since).inSeconds.clamp(0, 3600 * 24 * 30).toInt();
  }

  StitchPhase _taskPhase(String state) => switch (state) {
    'queued' => StitchPhase.queued,
    'running' => StitchPhase.running,
    'pausing' => StitchPhase.pausing,
    'paused' => StitchPhase.paused,
    'exporting' => StitchPhase.exporting,
    'completed' => StitchPhase.completed,
    'cancelled' => StitchPhase.cancelled,
    'failed' => StitchPhase.failed,
    _ => StitchPhase.interrupted,
  };

  StitchPhase _taskPhaseForStatus(String state, String operation) {
    if (operation == 'export' &&
        const {'queued', 'running', 'pausing'}.contains(state)) {
      return StitchPhase.exporting;
    }
    return _taskPhase(state);
  }

  Future<StitchTask?> _loadTask(BatchQueueItem item) async {
    if (item.taskId == null) return null;
    final cached = _taskCache[item.taskId];
    if (cached != null) {
      final durableInput = item.durableInputDirectory;
      if (durableInput != null &&
          p.normalize(durableInput) != p.normalize(cached.sourceDirectory)) {
        return null;
      }
      return cached;
    }
    final task = await _taskRepository.loadById(item.taskId!);
    if (task != null) {
      final durableInput = item.durableInputDirectory;
      if (durableInput != null &&
          p.normalize(durableInput) != p.normalize(task.sourceDirectory)) {
        return null;
      }
      _taskCache[task.id] = task;
    }
    return task;
  }

  Future<StitchTask?> taskForItem(BatchQueueItem item) => _loadTask(item);

  Future<TaskRecordSnapshot?> taskRecordFor(String taskId) =>
      TaskRecordService(_taskRepository).loadRecord(taskId);

  ({int index, BatchQueue queue, BatchQueueItem item})? _find(
    String queueId,
    String itemId,
  ) {
    final index = _queues.indexWhere((queue) => queue.id == queueId);
    if (index < 0) return null;
    final queue = _queues[index];
    final item = queue.items.firstWhere(
      (value) => value.id == itemId,
      orElse: () => const BatchQueueItem(
        id: '',
        name: '',
        sourceDirectory: '',
        state: BatchItemState.failed,
      ),
    );
    if (item.id.isEmpty) return null;
    return (index: index, queue: queue, item: item);
  }

  Future<void> _replaceState(
    String queueId,
    String itemId,
    BatchItemState state, {
    String? message,
    double? progress,
  }) async {
    final found = _find(queueId, itemId);
    if (found == null) return;
    await _replaceItem(
      found.index,
      found.item.copyWith(state: state, message: message, progress: progress),
    );
  }

  Future<void> _replaceItem(int queueIndex, BatchQueueItem item) async {
    final queue = _queues[queueIndex];
    final items = queue.items
        .map((value) => value.id == item.id ? item : value)
        .toList();
    final updated = queue.copyWith(items: items);
    _queues[queueIndex] = updated;
    await _save(updated);
    if (!_disposed) notifyListeners();
  }

  Future<void> _save(BatchQueue queue) {
    final write = _queueWriteTail.then((_) => _queueRepository.save(queue));
    _queueWriteTail = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  Future<void> _persistAll() async {
    for (final queue in _queues) {
      await _save(queue);
    }
  }

  /// Waits for the active scheduler pass and all queued persistence writes.
  /// Call after [dispose] when the owner must release the queue's storage files.
  Future<void> drain() async {
    _timer?.cancel();
    while (true) {
      final tickWork = _tickWork;
      final taskWrites = _taskWriteTail;
      final queueWrites = _queueWriteTail;
      await Future.wait<void>([tickWork, taskWrites, queueWrites]);
      if (identical(tickWork, _tickWork) &&
          identical(taskWrites, _taskWriteTail) &&
          identical(queueWrites, _queueWriteTail) &&
          !_ticking &&
          !_loading &&
          !_importing) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

bool nativeJobPathsMatch(String left, String right) {
  String normalize(String value) {
    final lower = value.toLowerCase();
    final unprefixed = lower.startsWith(r'\\?\unc\')
        ? '\\\\${value.substring(8)}'
        : value.startsWith(r'\\?\')
        ? value.substring(4)
        : value;
    return p
        .normalize(p.absolute(unprefixed))
        .replaceAll('/', '\\')
        .toLowerCase();
  }

  return normalize(left) == normalize(right);
}
