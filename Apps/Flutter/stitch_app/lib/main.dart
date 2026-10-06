import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models/grid_options.dart';
import 'batch_queue_page.dart';
import 'models/batch_queue.dart';
import 'models/imported_photo.dart';
import 'models/performance_options.dart';
import 'models/stitch_task.dart';
import 'models/stitch_quality.dart';
import 'services/native_job_api.dart';
import 'services/batch_queue_controller.dart';
import 'services/photo_importer.dart';
import 'services/power_service.dart';
import 'services/mobile_storage_service.dart';
import 'services/mobile_runtime_service.dart';
import 'services/spherical_request.dart';
import 'services/serial_task_write_queue.dart';
import 'services/task_repository.dart';
import 'widgets/exported_image_viewer.dart';
import 'l10n/stitch_localizations.dart';
import 'l10n/localized_text.dart';
import 'models/app_settings.dart';
import 'services/settings_controller.dart';
import 'settings_page.dart';
import 'models/stitch_timeline.dart';
import 'widgets/stitching_log.dart';

void main() => runApp(const LumiaStitchApp());

class LumiaStitchApp extends StatefulWidget {
  const LumiaStitchApp({
    super.key,
    this.locale,
    this.home,
    this.settingsController,
  });
  final Locale? locale;
  final Widget? home;
  final SettingsController? settingsController;
  @override
  State<LumiaStitchApp> createState() => _LumiaStitchAppState();
}

class _LumiaStitchAppState extends State<LumiaStitchApp> {
  late final SettingsController _settings =
      widget.settingsController ??
      SettingsController(
        initial: widget.home != null
            ? AppSettings.defaults(
                mobile: Platform.isAndroid || Platform.isIOS,
                android: Platform.isAndroid,
              )
            : null,
        defaults: AppSettings.defaults(
          mobile: Platform.isAndroid || Platform.isIOS,
          android: Platform.isAndroid,
        ),
      );
  @override
  void dispose() {
    if (widget.settingsController == null) _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _settings,
    builder: (context, _) {
      final s = _settings.settings;
      final locale =
          widget.locale ??
          (s.language == AppLanguage.system ? null : Locale(s.language.name));
      final brightness = switch (s.themeMode) {
        AppThemeMode.light => Brightness.light,
        AppThemeMode.dark => Brightness.dark,
        _ => null,
      };
      final seed = switch (s.accent) {
        AppAccent.blue => const Color(0xff2868b2),
        AppAccent.purple => const Color(0xff7651a6),
        AppAccent.orange => const Color(0xffc66a22),
        _ => const Color(0xff246b72),
      };
      final theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: brightness ?? Brightness.light,
        ),
        brightness: brightness,
        useMaterial3: true,
      );
      return MaterialApp(
        title: 'PocketGigaScan',
        locale: locale,
        themeMode: s.themeMode == AppThemeMode.system
            ? ThemeMode.system
            : s.themeMode == AppThemeMode.dark
            ? ThemeMode.dark
            : ThemeMode.light,
        supportedLocales: StitchLocalizations.supportedLocales,
        localizationsDelegates: const [
          StitchLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        localeResolutionCallback: (deviceLocale, supportedLocales) {
          if (widget.locale != null) return widget.locale;
          if (s.language != AppLanguage.system) return Locale(s.language.name);
          if (deviceLocale?.languageCode.toLowerCase() == 'zh') {
            return const Locale('zh');
          }
          return const Locale('en');
        },
        theme: theme,
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: seed,
            brightness: Brightness.dark,
          ),
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: widget.home ?? StitchHomePage(settingsController: _settings),
      );
    },
  );
}

/// Keeps the existing Text call sites intact while resolving their copy from
/// the active system/app locale, including updates when the system locale changes.

class StitchHomePage extends StatefulWidget {
  const StitchHomePage({
    super.key,
    this.jobApi,
    this.powerGate,
    this.repository,
    this.foregroundWorkLock,
    this.batchQueueController,
    this.initialTask,
    this.initialManifest,
    this.mobileOverride,
    this.androidOverride,
    this.mobileStorageService,
    this.mobileRuntimeService,
    this.settingsController,
  });
  final JobApi? jobApi;
  final PowerGate? powerGate;
  final TaskRepository? repository;
  final ForegroundWorkLock? foregroundWorkLock;
  final BatchQueueController? batchQueueController;
  final StitchTask? initialTask;
  final Map<String, Object?>? initialManifest;
  final bool? mobileOverride;
  final bool? androidOverride;
  final MobileStorageService? mobileStorageService;
  final MobileRuntimeService? mobileRuntimeService;
  final SettingsController? settingsController;
  @override
  State<StitchHomePage> createState() => _StitchHomePageState();
}

class _StitchHomePageState extends State<StitchHomePage>
    with WidgetsBindingObserver {
  late final _repository = widget.repository ?? TaskRepository();
  late final bool _android = widget.androidOverride ?? Platform.isAndroid;
  late final MobileStorageService _storage =
      widget.mobileStorageService ?? const MobileStorageService();
  late final MobileRuntimeService? _runtime = _android
      ? widget.mobileRuntimeService ?? MobileRuntimeService()
      : null;
  final _importer = PhotoImporter();
  late final JobApi _api = widget.jobApi ?? NativeJobApi();
  late final BatchQueueController? _batchController = (_mobile && !_android)
      ? null
      : widget.batchQueueController ??
            BatchQueueController(
              api: _api,
              requireLargeJobApproval: _android,
              runtimeService: _runtime,
              storageService: _android ? _storage : null,
            );
  late final PowerGate _power = widget.powerGate ?? PlatformPowerGate();
  late final ForegroundWorkLock _lock =
      widget.foregroundWorkLock ?? PlatformForegroundWorkLock();
  StitchTask? _task;
  List<StitchTask> _tasks = [];
  Timer? _poll;
  String? _message;
  bool _busy = false;
  bool _background = false;
  bool _pollInFlight = false;
  bool _controlInFlight = false;
  bool _exportInFlight = false;
  bool _pauseRequested = false;
  bool _batchOwnershipReady = false;
  final Completer<void> _batchOwnershipReadySignal = Completer<void>();
  int _controlGeneration = 0;
  final _performanceSaveQueue = SerialTaskWriteQueue();
  final _rows = TextEditingController(text: '1');
  final _columns = TextEditingController(text: '1');
  final _fov = TextEditingController(text: '45');
  final _fx = TextEditingController(text: '');
  final _horizontalOverlap = TextEditingController(text: '30');
  final _verticalOverlap = TextEditingController(text: '30');
  final _memory = TextEditingController(
    text: Platform.isAndroid || Platform.isIOS ? '128' : '512',
  );
  final _workers = TextEditingController(
    text: Platform.isAndroid || Platform.isIOS ? '1' : '4',
  );
  GridOptions _grid = const GridOptions();
  bool _forceGridFallback = false;
  bool _autoGridOverlap = true;
  bool _cameraCalibrationTouched = false;
  PerformanceOptions _performanceOptions = const PerformanceOptions();
  ExportFormat _exportFormat = Platform.isAndroid || Platform.isIOS
      ? ExportFormat.png
      : ExportFormat.tiff;
  bool _refineGridNeighbors = !(Platform.isAndroid || Platform.isIOS);
  SeamBlendMode _seamBlendMode = Platform.isAndroid || Platform.isIOS
      ? SeamBlendMode.feather
      : SeamBlendMode.deghost;
  bool _localTextureWarp = true;
  List<GridCell> _mappingCells = const [];
  Map<String, Object?>? _manifest;
  int? _viewerLevel;
  double _viewerScale = 1;
  bool _jpegXlAvailable = false;
  final TransformationController _tileTransform = TransformationController();
  int _diagnosticsPanelGeneration = 0;
  StreamSubscription<List<String>>? _runtimeTimeoutSubscription;
  final Set<String> _runtimeGuardedJobs = {};
  final Set<String> _runtimeGuardUnavailableJobs = {};
  final Set<String> _pendingRuntimeTimeoutJobIds = {};
  final Set<String> _confirmedRuntimeTimeoutJobIds = {};
  final Set<String> _failedRuntimeTimeoutAckJobIds = {};
  final Set<String> _runtimeTimeoutJobIdsReceivedWhileProcessing = {};
  Future<bool>? _runtimeTimeoutAckInFlight;
  bool _processingRuntimeTimeouts = false;
  bool _androidTimeoutSnapshotReady = false;
  bool _batchControllerInitialized = false;
  late final Future<bool> _androidResourcesReady = _configureAndroidResources();
  MobileResourceBudget? _resourceBudget;

  bool get _mobile =>
      widget.mobileOverride ?? (Platform.isAndroid || Platform.isIOS);
  AppSettings get _appSettings =>
      widget.settingsController?.settings ??
      AppSettings(
        exportFormat: _mobile ? ExportFormat.png : ExportFormat.tiff,
        refineGridNeighbors: _android,
        seamBlendMode: _mobile ? SeamBlendMode.feather : SeamBlendMode.deghost,
        performance: _performanceOptions,
      );
  bool get _hasActiveJob =>
      _task?.nativeJobId != null &&
      {
        StitchPhase.queued,
        StitchPhase.running,
        StitchPhase.pausing,
        StitchPhase.paused,
        StitchPhase.interrupted,
        StitchPhase.exporting,
      }.contains(_task!.phase);
  bool _isActivelyBatchOwned(StitchTask? task) {
    if (task == null) return false;
    if (!_batchOwnershipReady) return true;
    const activeStates = {
      BatchItemState.pending,
      BatchItemState.ready,
      BatchItemState.running,
      BatchItemState.exporting,
      BatchItemState.paused,
    };
    return _batchController?.queues.any(
          (queue) => queue.items.any(
            (item) =>
                item.taskId == task.id &&
                (item.pauseRequested || activeStates.contains(item.state)),
          ),
        ) ??
        false;
  }

  void _onBatchQueueChanged() {
    if (mounted) setState(() {});
    unawaited(_acknowledgeConfirmedQueueTimeouts());
  }

  Future<void> _acknowledgeConfirmedQueueTimeouts() async {
    final controller = _batchController;
    final runtime = _runtime;
    if (!_android ||
        !_androidTimeoutSnapshotReady ||
        controller == null ||
        runtime == null) {
      return;
    }
    final confirmed = _pendingRuntimeTimeoutJobIds
        .where((id) => !controller.pendingRuntimePauseJobIds.contains(id))
        .toList(growable: false);
    if (confirmed.isEmpty) return;
    _confirmedRuntimeTimeoutJobIds.addAll(confirmed);
    await _acknowledgeConfirmedRuntimeTimeouts();
  }

  Future<bool> _acknowledgeConfirmedRuntimeTimeouts({
    bool retryFailed = false,
  }) async {
    final runtime = _runtime;
    if (runtime == null) return false;
    final inFlight = _runtimeTimeoutAckInFlight;
    if (inFlight != null) {
      if (!await inFlight) return false;
      if (_confirmedRuntimeTimeoutJobIds.isEmpty &&
          _failedRuntimeTimeoutAckJobIds.isEmpty) {
        return true;
      }
      return _acknowledgeConfirmedRuntimeTimeouts(retryFailed: retryFailed);
    }

    final candidates = _confirmedRuntimeTimeoutJobIds
        .where(
          (id) => retryFailed || !_failedRuntimeTimeoutAckJobIds.contains(id),
        )
        .toList(growable: false);
    if (candidates.isEmpty) {
      return _confirmedRuntimeTimeoutJobIds.isEmpty &&
          _failedRuntimeTimeoutAckJobIds.isEmpty;
    }

    late final Future<bool> operation;
    operation = () async {
      var saved = false;
      try {
        saved = await runtime.acknowledgeTimeoutJobs(candidates);
      } on Object {
        saved = false;
      }
      if (saved) {
        _confirmedRuntimeTimeoutJobIds.removeAll(candidates);
        _failedRuntimeTimeoutAckJobIds.removeAll(candidates);
        _pendingRuntimeTimeoutJobIds.removeAll(candidates);
        _batchController?.pendingRuntimePauseJobIds.removeAll(candidates);
      } else {
        _failedRuntimeTimeoutAckJobIds.addAll(candidates);
        if (mounted) {
          setState(
            () => _message = StitchLocalizations.of(
              context,
            ).text('无法保存 Android 后台暂停记录；请重试后再启动或恢复。'),
          );
        }
      }
      if (identical(_runtimeTimeoutAckInFlight, operation)) {
        _runtimeTimeoutAckInFlight = null;
      }
      final newlyConfirmed = _confirmedRuntimeTimeoutJobIds
          .where((id) => !_failedRuntimeTimeoutAckJobIds.contains(id))
          .toList(growable: false);
      if (newlyConfirmed.isNotEmpty &&
          !await _acknowledgeConfirmedRuntimeTimeouts()) {
        return false;
      }
      return saved &&
          _confirmedRuntimeTimeoutJobIds.isEmpty &&
          _failedRuntimeTimeoutAckJobIds.isEmpty;
    }();
    _runtimeTimeoutAckInFlight = operation;
    return operation;
  }

  bool get _canStart =>
      _task?.phase == StitchPhase.imported ||
      _task?.phase == StitchPhase.paused ||
      _task?.phase == StitchPhase.interrupted ||
      _task?.phase == StitchPhase.completed ||
      _task?.phase == StitchPhase.failed ||
      _task?.phase == StitchPhase.cancelled;
  bool get _editable {
    final task = _task;
    if (task == null) return true;
    if (_isActivelyBatchOwned(task)) return false;
    return task.phase == StitchPhase.completed ||
        (task.nativeJobId == null &&
            !{
              StitchPhase.queued,
              StitchPhase.running,
              StitchPhase.pausing,
              StitchPhase.paused,
              StitchPhase.interrupted,
              StitchPhase.exporting,
            }.contains(task.phase));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.settingsController?.addListener(_applySettingsDefaults);
    if (widget.settingsController != null) {
      unawaited(
        widget.settingsController!.ready.then((_) => _applySettingsDefaults()),
      );
    }
    if (_mobile && widget.initialTask == null) {
      _exportFormat = _android ? ExportFormat.tiff : ExportFormat.png;
      _refineGridNeighbors = _android;
      _seamBlendMode = _android ? SeamBlendMode.deghost : SeamBlendMode.feather;
      _localTextureWarp = true;
    }
    if (widget.initialTask != null) {
      _task = widget.initialTask;
      _manifest = widget.initialManifest;
      _grid = _task!.grid;
      _mappingCells = _makeMapping(_grid);
      _rows.text = '${_grid.rows}';
      _columns.text = '${_grid.columns}';
      _fov.text = '${_task!.horizontalFovDegrees}';
      _memory.text = '${_task!.memoryBudgetMiB}';
      _workers.text = '${_task!.workers}';
      _forceGridFallback = _task!.forceGridFallback;
      _autoGridOverlap = _task!.autoGridOverlap;
      _cameraCalibrationTouched = _task!.cameraCalibrationOverridden;
      _performanceOptions = _task!.performanceOptions;
      _exportFormat = _task!.exportFormat;
      _refineGridNeighbors = _task!.refineGridNeighbors;
      _seamBlendMode = _task!.seamBlendMode;
      _localTextureWarp = _task!.localTextureWarp;
      _horizontalOverlap.text =
          '${(_task!.gridHorizontalOverlap * 100).round()}';
      _verticalOverlap.text = '${(_task!.gridVerticalOverlap * 100).round()}';
      if (_hasActiveJob) _beginPolling();
    }
    final batchController = _batchController;
    if (batchController != null) {
      batchController.requireLargeJobApproval = _android;
      if (_android) batchController.resourceConfigurationReady = false;
      batchController.addListener(_onBatchQueueChanged);
      unawaited(_initializeBatchOwnership(batchController));
    } else {
      _batchOwnershipReady = true;
      _batchOwnershipReadySignal.complete();
    }
    if (!_mobile || _android) unawaited(_loadFormatCapabilities());
    _runtimeTimeoutSubscription = _runtime?.timeoutRequests.listen(
      _handleRuntimeTimeout,
    );
    _refreshTasks();
  }

  void _applySettingsDefaults({bool force = false}) {
    if (!mounted ||
        (!force && _task != null) ||
        widget.settingsController == null) {
      return;
    }
    final s = _appSettings;
    setState(() {
      _performanceOptions = s.performance;
      _exportFormat = s.exportFormat;
      _refineGridNeighbors = s.refineGridNeighbors;
      _seamBlendMode = s.seamBlendMode;
      _localTextureWarp = s.localTextureWarp;
    });
  }

  Future<void> _initializeBatchOwnership(
    BatchQueueController controller,
  ) async {
    var startupTimeoutJobIds = <String>[];
    try {
      if (_android) {
        final configured = await _androidResourcesReady;
        controller.resourceConfigurationReady = configured;
        controller.resourceBudget = _resourceBudget;
        try {
          startupTimeoutJobIds = await _runtime!.readPendingTimeoutJobs();
        } on Object catch (error) {
          controller.resourceConfigurationReady = false;
          if (mounted) {
            setState(() => _message = '无法读取 Android 后台超时记录；批处理任务保持待核对：$error');
          }
          return;
        }
        _androidTimeoutSnapshotReady = true;
        _pendingRuntimeTimeoutJobIds.addAll(startupTimeoutJobIds);
        controller.pendingRuntimePauseJobIds.addAll(startupTimeoutJobIds);
        controller.pendingRuntimePauseJobIds.addAll(
          _pendingRuntimeTimeoutJobIds,
        );
      }
      await controller.initialize();
      _batchControllerInitialized = true;
    } finally {
      _batchOwnershipReady = true;
      if (!_batchOwnershipReadySignal.isCompleted) {
        _batchOwnershipReadySignal.complete();
      }
      if (mounted) setState(() {});
    }
    if (_android && _pendingRuntimeTimeoutJobIds.isNotEmpty) {
      await _processRuntimeTimeouts({
        ...startupTimeoutJobIds,
        ..._pendingRuntimeTimeoutJobIds,
      }, queueInitializationHandled: true);
    }
  }

  Future<bool> _configureAndroidResources() async {
    if (!_android) return true;
    final runtime = _runtime;
    MobileResourceBudget budget;
    try {
      budget = await runtime!.readResourceBudget();
    } on Object {
      budget = const MobileResourceBudget(
        totalMemoryMiB: 128,
        availableMemoryMiB: 128,
        cpuCount: 1,
        availableStorageMiB: 0,
        thermalStatus: 'unknown',
        readingsValid: false,
      );
    }
    _resourceBudget = budget;
    try {
      await _api.configureResources(
        totalCpuWorkers: budget.recommendedTotalCpuWorkers,
        totalMemoryBudgetMiB: budget.recommendedTotalMemoryBudgetMiB,
        maxConcurrentJobs: budget.recommendedMaxConcurrentJobs,
      );
      return true;
    } on Object {
      return false;
    }
  }

  Future<bool> _androidCanStart() async {
    if (!_android) return true;
    if (!_androidTimeoutSnapshotReady) {
      try {
        final pending = await _runtime!.readPendingTimeoutJobs();
        _pendingRuntimeTimeoutJobIds.addAll(pending);
        final controller = _batchController;
        controller?.pendingRuntimePauseJobIds.addAll(pending);
        _androidTimeoutSnapshotReady = true;
        if (controller != null && !_batchControllerInitialized) {
          controller.resourceConfigurationReady = await _androidResourcesReady;
          controller.resourceBudget = _resourceBudget;
          await controller.initialize();
          _batchControllerInitialized = true;
        }
        if (_pendingRuntimeTimeoutJobIds.isNotEmpty) {
          await _processRuntimeTimeouts(
            _pendingRuntimeTimeoutJobIds.toList(growable: false),
            queueInitializationHandled: _batchControllerInitialized,
          );
        }
      } on Object catch (error) {
        if (mounted) {
          setState(() => _message = '无法读取 Android 后台超时记录；启动、恢复与导出已暂缓：$error');
        }
        return false;
      }
    }
    if (_confirmedRuntimeTimeoutJobIds.isNotEmpty &&
        !await _acknowledgeConfirmedRuntimeTimeouts(
          retryFailed: _failedRuntimeTimeoutAckJobIds.isNotEmpty,
        )) {
      if (mounted) {
        setState(
          () => _message = StitchLocalizations.of(
            context,
          ).text('无法保存 Android 后台暂停记录；请重试后再启动或恢复。'),
        );
      }
      return false;
    }
    if (!await _androidResourcesReady) {
      if (mounted) setState(() => _message = '无法设置 Android 渲染资源预算，已暂缓启动。');
      return false;
    }
    try {
      _resourceBudget = await _runtime!.readResourceBudget();
    } on Object {
      // Keep the last validated initialization reading if a live refresh fails.
    }
    if (_resourceBudget?.shouldDeferNewStarts == true) {
      if (mounted) setState(() => _message = '设备温度较高，待温度降低后再启动新任务。');
      return false;
    }
    return true;
  }

  Future<void> _loadFormatCapabilities() async {
    try {
      final response = await _api.capabilities();
      final capabilities =
          response['capabilities'] as Map<String, Object?>? ?? const {};
      if (mounted) {
        setState(
          () => _jpegXlAvailable = capabilities['jpegXlAvailable'] == true,
        );
      }
    } on Object {
      if (mounted) setState(() => _jpegXlAvailable = false);
    }
  }

  Future<void> _handleRuntimeTimeout(List<String> jobIds) async {
    final received = jobIds.where((id) => id.isNotEmpty).toSet();
    _pendingRuntimeTimeoutJobIds.addAll(received);
    _batchController?.pendingRuntimePauseJobIds.addAll(received);
    if (_processingRuntimeTimeouts) {
      _runtimeTimeoutJobIdsReceivedWhileProcessing.addAll(received);
      return;
    }
    if (!_batchOwnershipReady || !_androidTimeoutSnapshotReady) return;
    await _processRuntimeTimeouts(received.toList(growable: false));
  }

  Future<void> _processRuntimeTimeouts(
    Iterable<String> jobIds, {
    bool queueInitializationHandled = false,
  }) async {
    if (!_android || _processingRuntimeTimeouts) return;
    final requested = jobIds.where((id) => id.isNotEmpty).toSet();
    _processingRuntimeTimeouts = true;
    try {
      _pendingRuntimeTimeoutJobIds.addAll(requested);
      if (requested.isEmpty || _runtime == null) return;

      final controller = _batchController;
      final tasks = await _repository.loadAll();
      final queuedTaskIds =
          controller?.queues
              .expand((queue) => queue.items)
              .map((item) => item.taskId)
              .whereType<String>()
              .toSet() ??
          const <String>{};
      final acknowledged = <String>[];

      for (final jobId in requested) {
        if (_confirmedRuntimeTimeoutJobIds.contains(jobId)) continue;
        _runtimeGuardUnavailableJobs.add(jobId);
        _runtimeGuardedJobs.remove(jobId);
        final queuedTask = tasks.where(
          (task) =>
              task.nativeJobId == jobId && queuedTaskIds.contains(task.id),
        );
        if (queuedTask.isNotEmpty) {
          if (queueInitializationHandled) {
            if (controller != null &&
                !controller.pendingRuntimePauseJobIds.contains(jobId)) {
              acknowledged.add(jobId);
            } else if (controller != null &&
                await controller.pauseJobByNativeId(jobId)) {
              controller.pendingRuntimePauseJobIds.remove(jobId);
              acknowledged.add(jobId);
            }
          } else if (controller != null &&
              await controller.pauseJobByNativeId(jobId)) {
            controller.pendingRuntimePauseJobIds.remove(jobId);
            acknowledged.add(jobId);
          }
          continue;
        }

        final taskMatches = tasks.where((task) => task.nativeJobId == jobId);
        if (taskMatches.length != 1) continue;
        if (await _pauseAndConfirmTimedOutTask(taskMatches.single)) {
          acknowledged.add(jobId);
        }
      }

      if (acknowledged.isNotEmpty) {
        final acknowledgedSet = acknowledged.toSet();
        _confirmedRuntimeTimeoutJobIds.addAll(acknowledgedSet);
        controller?.pendingRuntimePauseJobIds.removeAll(acknowledgedSet);
        await _acknowledgeConfirmedRuntimeTimeouts();
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _message = 'Android 后台超时任务仍待安全核对：$error');
      }
    } finally {
      _processingRuntimeTimeouts = false;
      final newlyReceived = _runtimeTimeoutJobIdsReceivedWhileProcessing
          .toSet();
      _runtimeTimeoutJobIdsReceivedWhileProcessing.clear();
      final toReplay = newlyReceived.difference(requested);
      if (_batchOwnershipReady && toReplay.isNotEmpty) {
        unawaited(_processRuntimeTimeouts(toReplay));
      }
    }
  }

  Future<bool> _pauseAndConfirmTimedOutTask(StitchTask task) async {
    final jobId = task.nativeJobId;
    if (jobId == null) return false;
    final generation = _controlGeneration;
    const quiescentStates = {
      'paused',
      'completed',
      'failed',
      'cancelled',
      'interrupted',
    };
    Map<String, Object?>? observed;
    try {
      observed = await _api.status(jobId);
    } on Object {
      // A timeout remains pending when native state cannot be verified.
    }
    if (observed == null ||
        !quiescentStates.contains(observed['state'] as String?)) {
      try {
        await _api.pause(jobId);
      } on Object {
        // Verify status below even if the pause request itself failed.
      }
      try {
        observed = await _api.status(jobId);
      } on Object {
        observed = null;
      }
    }
    final state = observed?['state'] as String?;
    if (state == null || !quiescentStates.contains(state)) {
      if (observed != null) {
        final operation = observed['operation'] as String? ?? 'render';
        final phase = _phase(state);
        await _persist(
          task.copyWith(
            phase: phase,
            stage: observed['stage'] as String? ?? task.stage,
            autoExportOnCompletion: false,
            pauseReason: 'Android 后台运行时限已到，原生任务仍在停止；等待确认安全暂停。',
          ),
          expectedGeneration: generation,
          expectedTaskId: task.id,
        );
        if (operation == 'export' &&
            {StitchPhase.failed, StitchPhase.cancelled}.contains(phase)) {
          await _persist(
            task.copyWith(
              phase: StitchPhase.completed,
              stage: 'export-failed',
              autoExportOnCompletion: false,
              pauseReason: 'Android 后台运行时限已到；保留此前成功的导出结果。',
            ),
            expectedGeneration: generation,
            expectedTaskId: task.id,
          );
        }
      }
      if (_task?.nativeJobId == jobId && _hasActiveJob) _beginPolling();
      return false;
    }

    final operation = observed?['operation'] as String? ?? 'render';
    var phase = _phase(state);
    var stage = observed?['stage'] as String? ?? task.stage;
    if (operation == 'export' &&
        {StitchPhase.failed, StitchPhase.cancelled}.contains(phase)) {
      phase = StitchPhase.completed;
      stage = 'export-failed';
    }
    await _persist(
      task.copyWith(
        phase: phase,
        stage: stage,
        autoExportOnCompletion: false,
        pauseReason: phase == StitchPhase.paused
            ? 'Android 后台运行时限已到，任务已安全暂停。'
            : 'Android 后台运行时限已到；已记录原生任务的终止状态。',
      ),
      expectedGeneration: generation,
      expectedTaskId: task.id,
    );
    return true;
  }

  Future<bool> _confirmLargeJob(StitchTask task) async {
    if (!_android ||
        !task.needsLargeJobConfirmation ||
        task.hasCurrentLargeJobApproval) {
      return true;
    }
    final power = await _power.readState();
    if (!mounted) return false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认大型合成任务'),
        content: Text(
          StitchLocalizations.of(context).largeJobConfirmation(
            rows: task.grid.rows,
            columns: task.grid.columns,
            photoCount: task.photos.length,
            onBattery: power != PowerState.externalPower,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (accepted != true) return false;
    final approved = task.copyWith(
      largeJobApprovalScope: task.currentLargeJobApprovalScope,
    );
    await _persist(approved);
    return true;
  }

  Future<StitchPhase?> _enableMobileRuntime(String jobId) async {
    if (!_android) return null;
    final runtime = _runtime;
    final ready =
        runtime != null &&
        await runtime.setProcessingActive(true, jobId: jobId);
    if (ready) {
      _runtimeGuardUnavailableJobs.remove(jobId);
      _runtimeGuardedJobs.add(jobId);
      return null;
    }
    _runtimeGuardUnavailableJobs.add(jobId);
    var state = 'unknown';
    try {
      final response = await _api.pause(jobId);
      state = response['state'] as String? ?? 'pausing';
    } on Object {
      try {
        final response = await _api.status(jobId);
        state = response['state'] as String? ?? 'unknown';
      } on Object {
        // Unknown remains interrupted and is reconciled by normal status polling.
      }
    }
    if (runtime != null) {
      await runtime.setProcessingActive(false, jobId: jobId);
    }
    if (state == 'paused' ||
        state == 'completed' ||
        state == 'failed' ||
        state == 'cancelled') {
      _runtimeGuardedJobs.remove(jobId);
    }
    return _phase(state);
  }

  Future<bool> _enableMobileRuntimeBeforeStart(String jobId) async {
    if (!_android) return true;
    final ready =
        _runtime != null &&
        await _runtime.setProcessingActive(true, jobId: jobId);
    if (ready) {
      _runtimeGuardUnavailableJobs.remove(jobId);
      _runtimeGuardedJobs.add(jobId);
      return true;
    }
    _runtimeGuardUnavailableJobs.add(jobId);
    await _runtime?.setProcessingActive(false, jobId: jobId);
    if (mounted) {
      setState(() => _message = '无法启动 Android 后台运行保护；核心任务尚未启动');
    }
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _background = _mobile && state != AppLifecycleState.resumed;
    if (_background &&
        _hasActiveJob &&
        _task!.phase != StitchPhase.paused &&
        (!_android ||
            _runtime == null ||
            !_runtimeGuardedJobs.contains(_task!.nativeJobId))) {
      unawaited(_requestPause('应用进入后台，已请求暂停；等待核心确认'));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.settingsController?.removeListener(_applySettingsDefaults);
    unawaited(_runtimeTimeoutSubscription?.cancel());
    if (widget.mobileRuntimeService == null) {
      unawaited(_runtime?.dispose());
    }
    _poll?.cancel();
    _tileTransform.dispose();
    if (widget.batchQueueController == null) {
      _batchController
        ?..removeListener(_onBatchQueueChanged)
        ..dispose();
    } else {
      _batchController?.removeListener(_onBatchQueueChanged);
    }
    _rows.dispose();
    _columns.dispose();
    _fov.dispose();
    _fx.dispose();
    _horizontalOverlap.dispose();
    _verticalOverlap.dispose();
    _memory.dispose();
    _workers.dispose();
    unawaited(_lock.disable());
    super.dispose();
  }

  Future<void> _refreshTasks() async {
    final selectionGeneration = _controlGeneration;
    try {
      var loaded = await _repository.loadAll();
      await _performanceSaveQueue.enqueue(() async {});
      if (selectionGeneration != _controlGeneration) {
        if (mounted) setState(() => _tasks = loaded);
        return;
      }
      final current = _task;
      StitchTask? selected;
      if (current == null) {
        if (loaded.isNotEmpty) selected = loaded.first;
      } else {
        for (final task in loaded) {
          if (task.id == current.id) {
            selected = task;
            break;
          }
        }
      }
      if (selected != null) {
        final enriched = await _enrichLegacyPhotoMetadata(selected);
        if (!identical(selected, enriched) &&
            selectionGeneration == _controlGeneration) {
          loaded = [
            for (final task in loaded)
              if (task.id == enriched.id) enriched else task,
          ];
        }
      }
      if (mounted) {
        setState(() {
          _tasks = loaded;
          final matching = selected == null
              ? const <StitchTask>[]
              : loaded.where((task) => task.id == selected!.id).toList();
          final selectedTask = matching.isEmpty ? null : matching.first;
          if (selectedTask != null &&
              selectionGeneration == _controlGeneration &&
              _task?.id == selectedTask.id) {
            _task = selectedTask;
            _fov.text = '${selectedTask.horizontalFovDegrees}';
          }
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _message = '无法读取本地任务：$error');
    }
  }

  Future<StitchTask> _enrichLegacyPhotoMetadata(StitchTask task) async {
    if (task.nativeJobId != null ||
        task.phase != StitchPhase.imported ||
        task.photos.isEmpty ||
        task.photos.any(
          (photo) =>
              photo.exifMake != null ||
              photo.exifModel != null ||
              photo.exifLensModel != null ||
              photo.exifFocalLengthMm != null,
        )) {
      return task;
    }
    final photos = <ImportedPhoto>[];
    try {
      for (final photo in task.photos) {
        final file = File(photo.storedPath);
        if (!await file.exists()) return task;
        final metadata = await readJpegMetadata(file);
        photos.add(
          ImportedPhoto(
            originalName: photo.originalName,
            storedPath: photo.storedPath,
            sha256: photo.sha256,
            width: photo.width,
            height: photo.height,
            originalOrder: photo.originalOrder,
            exifMake: metadata.make,
            exifModel: metadata.model,
            exifLensModel: metadata.lensModel,
            exifFocalLengthMm: metadata.focalLengthMm,
          ),
        );
      }
    } on Object {
      return task;
    }
    if (!photos.any(
      (photo) =>
          photo.exifMake != null ||
          photo.exifModel != null ||
          photo.exifLensModel != null ||
          photo.exifFocalLengthMm != null,
    )) {
      return task;
    }
    final hasUniformVerifiedProfile = photos.every(
      (photo) => photo.isVerifiedDwarf3Tele,
    );
    final applyNominalProfile =
        hasUniformVerifiedProfile &&
        task.horizontalFovDegrees == 45 &&
        !task.cameraCalibrationOverridden &&
        task.cameraProfileId == null;
    const profileFxAt3840 = 75000.0;
    final fx = profileFxAt3840 * photos.first.width / 3840;
    final profileFov =
        2 * math.atan(photos.first.width / (2 * fx)) * 180 / math.pi;
    final enriched = task.copyWith(
      photos: List.unmodifiable(photos),
      horizontalFovDegrees: applyNominalProfile
          ? profileFov
          : task.horizontalFovDegrees,
      cameraProfileId: applyNominalProfile
          ? 'dwarf3-tele-nominal-150mm'
          : task.cameraProfileId,
    );
    await _performanceSaveQueue.enqueue(() => _repository.save(enriched));
    return enriched;
  }

  void _setGrid(GridOptions next, {bool resize = false}) {
    final rearranged =
        next.mode != _grid.mode ||
        next.rows != _grid.rows ||
        next.columns != _grid.columns ||
        next.axis != _grid.axis ||
        next.startCorner != _grid.startCorner ||
        next.serpentine != _grid.serpentine;
    if (rearranged && _grid.forceGridCells.isNotEmpty) {
      final task = _task;
      final oldMapping = task == null ? null : _mappingFor(task, _grid);
      final newMapping = task == null ? null : _mappingFor(task, next);
      final retained =
          oldMapping?.isValid == true && newMapping?.isValid == true
          ? remapForcedCellsByPhoto(
              photos: task!.photos,
              oldMapping: oldMapping!.cells,
              oldForced: _grid.forceGridCells,
              newMapping: newMapping!.cells,
            )
          : const <GridCell>{};
      next = next.copyWith(forceGridCells: retained);
      _message = retained.isEmpty
          ? '排列已改变；修正网格后请重新标记异常照片。'
          : '排列已改变；强制网格标记已随原片保留。';
    }
    setState(() {
      _grid = next;
      if (resize) {
        _rows.text = '${next.rows}';
        _columns.text = '${next.columns}';
      }
      _mappingCells = _makeMapping(next);
    });
  }

  List<GridCell> _makeMapping(GridOptions options) {
    final task = _task;
    if (task == null || task.photos.isEmpty) return const [];
    final mapping = _mappingFor(task, options);
    if (mapping.isValid && options.mode == GridMode.filename) {
      _rows.text = '${mapping.rows}';
      _columns.text = '${mapping.columns}';
    }
    return mapping.isValid ? mapping.cells : const [];
  }

  GridMapping _mappingFor(StitchTask task, GridOptions options) {
    if (options.mode == GridMode.filename) {
      final mapping = GridMapping.fromFilenames(task.photos);
      return mapping;
    }
    final mapping = GridMapping.sequence(task.photos, options);
    return mapping;
  }

  String? _mappingError() {
    if (_task == null) return '导入照片后即可设置网格。';
    if (_grid.mode == GridMode.filename) {
      return GridMapping.fromFilenames(_task!.photos).error;
    }
    return GridMapping.sequence(_task!.photos, _grid).error;
  }

  Future<void> _importPhotos() async {
    if (_busy || !_editable) return;
    await widget.settingsController?.ready;
    if (!mounted) return;
    // When a task is selected, its controls hold the user's current choices.
    // Keep those as the new task's starting options instead of resetting them
    // to global defaults during import.
    _applySettingsDefaults();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final picked = await _importer.pickJpegs();
      if (picked == null || picked.isEmpty) return;
      final base = await _repository.root();
      final id = _repository.createId();
      final dir = Directory(p.join(base.path, id));
      await dir.create(recursive: true);
      final batch = await _importer.copyIntoTask(picked, dir.path);
      final options = _grid;
      final useDwarfNominalProfile =
          !_cameraCalibrationTouched &&
          _fx.text.trim().isEmpty &&
          batch.photos.isNotEmpty &&
          batch.photos.every((photo) => photo.isVerifiedDwarf3Tele);
      const profileFxAt3840 = 75000.0;
      final profileFx = profileFxAt3840 * batch.dimensions.$1 / 3840;
      final profileFov =
          2 * math.atan(batch.dimensions.$1 / (2 * profileFx)) * 180 / math.pi;
      final task = StitchTask(
        id: id,
        createdAt: DateTime.now(),
        sourceDirectory: batch.inputDirectory,
        outputDirectory: p.join(dir.path, 'output'),
        photos: batch.photos,
        grid: options,
        horizontalFovDegrees: useDwarfNominalProfile
            ? profileFov
            : double.tryParse(_fov.text) ?? 45,
        memoryBudgetMiB: int.tryParse(_memory.text) ?? (_mobile ? 128 : 512),
        workers: int.tryParse(_workers.text) ?? (_mobile ? 1 : 4),
        phase: StitchPhase.imported,
        forceGridFallback: _forceGridFallback,
        autoGridOverlap: _autoGridOverlap,
        cameraProfileId: useDwarfNominalProfile
            ? 'dwarf3-tele-nominal-150mm'
            : null,
        cameraCalibrationOverridden: _cameraCalibrationTouched,
        performanceOptions: _performanceOptions,
        exportFormat: _exportFormat,
        exportDirectory: _appSettings.outputDirectory,
        autoExportOnCompletion: true,
        refineGridNeighbors: _refineGridNeighbors,
        seamBlendMode: _seamBlendMode,
        localTextureWarp: _localTextureWarp,
        gridHorizontalOverlap:
            (double.tryParse(_horizontalOverlap.text) ?? 30) / 100,
        gridVerticalOverlap:
            (double.tryParse(_verticalOverlap.text) ?? 30) / 100,
      );
      await _repository.save(task);
      setState(() {
        _task = task;
        if (useDwarfNominalProfile) _fov.text = profileFov.toStringAsFixed(4);
        _mappingCells = _makeMapping(options);
        _message = batch.hasUniformDimensions
            ? '已复制并校验 ${batch.photos.length} 张原片（${batch.dimensions.$1}×${batch.dimensions.$2}）。'
            : '原片尺寸不一致；请统一尺寸后重新导入。照片均已保留。';
      });
      await _refreshTasks();
    } on Object catch (error) {
      setState(() => _message = '导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
      if (_pauseRequested && mounted) {
        _pauseRequested = false;
        unawaited(_requestPause('操作完成后已提交暂停请求'));
      }
    }
  }

  Future<bool> _saveOptions() async {
    final wasBusy = _busy;
    if (!wasBusy) setState(() => _busy = true);
    try {
      return await _saveOptionsImpl();
    } finally {
      if (!wasBusy && mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _saveOptionsImpl() async {
    final old = _task;
    if (old == null || !_editable) return false;
    final rows = int.tryParse(_rows.text),
        columns = int.tryParse(_columns.text);
    if (rows == null || columns == null) {
      setState(() => _message = '行列必须是有效整数。');
      return false;
    }
    final rearranged = rows != _grid.rows || columns != _grid.columns;
    final candidate = _grid.copyWith(rows: rows, columns: columns);
    final oldMapping = _mappingFor(old, _grid),
        newMapping = _mappingFor(old, candidate);
    final forced = rearranged
        ? remapForcedCellsByPhoto(
            photos: old.photos,
            oldMapping: oldMapping.cells,
            oldForced: _grid.forceGridCells,
            newMapping: newMapping.cells,
          )
        : _grid.forceGridCells;
    final next = candidate.copyWith(forceGridCells: forced);
    if (rearranged && _grid.forceGridCells.isNotEmpty) {
      _message = forced.isEmpty
          ? '排列已改变；修正网格后请重新标记异常照片。'
          : '排列已改变；强制网格标记已随原片保留。';
    }
    if (next.validationError != null) {
      setState(() => _message = next.validationError);
      return false;
    }
    final fov = double.tryParse(_fov.text);
    if (fov == null || !fov.isFinite || fov <= 1 || fov >= 179) {
      setState(() => _message = '水平视角需介于 1° 与 179°。');
      return false;
    }
    final memory = int.tryParse(_memory.text);
    final workers = int.tryParse(_workers.text);
    if (memory == null || memory < 128 || memory > 4096) {
      setState(() => _message = '渲染内存预算需为 128–4096 MiB。');
      return false;
    }
    if (workers == null || workers < 1 || workers > 32) {
      setState(() => _message = '配准并行数需为 1–32。');
      return false;
    }
    final horizontalOverlap = double.tryParse(_horizontalOverlap.text);
    final verticalOverlap = double.tryParse(_verticalOverlap.text);
    if (!_autoGridOverlap &&
        (horizontalOverlap == null ||
            !horizontalOverlap.isFinite ||
            horizontalOverlap < 15 ||
            horizontalOverlap > 80 ||
            verticalOverlap == null ||
            !verticalOverlap.isFinite ||
            verticalOverlap < 15 ||
            verticalOverlap > 80)) {
      setState(() => _message = '水平与垂直重叠率需分别为 15%–80%。');
      return false;
    }
    if (_fx.text.trim().isNotEmpty &&
        (double.tryParse(_fx.text) == null ||
            !double.parse(_fx.text).isFinite ||
            double.parse(_fx.text) <= 0)) {
      setState(() => _message = '焦距像素值必须大于零。');
      return false;
    }
    final requestedFx = double.tryParse(_fx.text.trim());
    final effectiveFov = requestedFx == null
        ? fov
        : 2 *
              math.atan(old.photos.first.width / (2 * requestedFx)) *
              180 /
              math.pi;
    final updated = old.copyWith(
      grid: next,
      horizontalFovDegrees: effectiveFov,
      memoryBudgetMiB: memory,
      workers: workers,
      forceGridFallback: _forceGridFallback,
      autoGridOverlap: _autoGridOverlap,
      cameraProfileId: _cameraCalibrationTouched ? null : old.cameraProfileId,
      clearCameraProfileId: _cameraCalibrationTouched,
      cameraCalibrationOverridden: _cameraCalibrationTouched,
      performanceOptions: _performanceOptions,
      exportFormat: _exportFormat,
      refineGridNeighbors: _refineGridNeighbors,
      seamBlendMode: _seamBlendMode,
      localTextureWarp: _localTextureWarp,
      gridHorizontalOverlap: horizontalOverlap == null
          ? old.gridHorizontalOverlap
          : horizontalOverlap / 100,
      gridVerticalOverlap: verticalOverlap == null
          ? old.gridVerticalOverlap
          : verticalOverlap / 100,
    );
    final persisted = updated.copyWith(performanceOptions: _performanceOptions);
    if (!await _enqueueTaskSave(persisted)) return false;
    final latest = _task?.id == persisted.id
        ? _task!.performanceOptions
        : persisted.performanceOptions;
    final visible = persisted.copyWith(performanceOptions: latest);
    setState(() {
      _task = visible;
      _grid = next;
      final index = _tasks.indexWhere((item) => item.id == visible.id);
      if (index >= 0) {
        final nextTasks = [..._tasks];
        nextTasks[index] = visible;
        _tasks = nextTasks;
      }
      _mappingCells = _makeMapping(next);
      _message = null;
    });
    return true;
  }

  Future<bool> _enqueueTaskSave(StitchTask task) async {
    final pending = _performanceSaveQueue.enqueue(() => _repository.save(task));
    try {
      await pending;
      return true;
    } on Object catch (error) {
      if (mounted && _task?.id == task.id) {
        setState(() => _message = '保存提速测试选项失败：$error');
      }
      return false;
    }
  }

  Future<void> _startOrResume({required bool resume}) async {
    final task = _task;
    if (task == null || _busy) return;
    if (_isActivelyBatchOwned(task)) {
      setState(() => _message = '此任务由批处理队列管理，请在批处理队列中控制。');
      return;
    }
    if (task.exportFormat == ExportFormat.jpegXl && !_jpegXlAvailable) {
      setState(() => _message = '此原生核心未报告内置 JPEG XL 编码器，已阻止启动。');
      return;
    }
    if (_mappingError() != null) {
      setState(() => _message = _mappingError());
      return;
    }
    if (!task.photos.every(
      (photo) =>
          photo.width == task.photos.first.width &&
          photo.height == task.photos.first.height,
    )) {
      setState(() => _message = '原片尺寸不一致，核心无法共用相机内参。');
      return;
    }
    if (!_api.isAvailable) {
      setState(() => _message = _api.unavailableReason);
      return;
    }
    if (!await _androidCanStart()) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      StitchTask active = task;
      if (resume) {
        active = task.copyWith(autoExportOnCompletion: true);
        if (!await _confirmLargeJob(active)) return;
        if (active.needsLargeJobConfirmation) {
          active = active.copyWith(
            largeJobApprovalScope: active.currentLargeJobApprovalScope,
          );
        }
        await _persist(active);
        _runtimeGuardUnavailableJobs.remove(task.nativeJobId!);
        final guardedPhase = await _enableMobileRuntime(task.nativeJobId!);
        if (guardedPhase != null) {
          active = active.copyWith(
            phase: guardedPhase,
            pauseReason: guardedPhase == StitchPhase.paused
                ? 'Android 无法启动后台运行保护，任务已安全暂停'
                : 'Android 无法确认后台安全暂停，正在核对原生任务状态',
          );
          await _persist(active);
          if (guardedPhase != StitchPhase.paused) _beginPolling();
          setState(() => _message = active.pauseReason);
          return;
        }
        final response = await _api.resume(task.nativeJobId!);
        active = active.copyWith(
          phase: _phase(response['state']),
          stage: response['stage'] as String? ?? task.stage,
          progress: (response['progress'] as num? ?? task.progress).toDouble(),
          timeline: _mergeResponseTimeline(active, response, task.nativeJobId!),
          clearError: true,
          clearPauseReason: true,
        );
      } else {
        if (!await _saveOptions()) return;
        active = _task!;
        if (active.phase != StitchPhase.imported) {
          active = await _repository.duplicateForNewRun(active);
          setState(() {
            _task = active;
            _grid = active.grid;
          });
        }
        active = active.copyWith(autoExportOnCompletion: true);
        if (!await _confirmLargeJob(active)) return;
        if (active.needsLargeJobConfirmation) {
          active = active.copyWith(
            largeJobApprovalScope: active.currentLargeJobApprovalScope,
          );
        }
        await _persist(active);
        _runtimeGuardUnavailableJobs.remove(
          active.nativeJobId ?? active.outputDirectory,
        );
        final out = await _repository.prepareOutput(active);
        final budget = _resourceBudget;
        final effectiveMemory = _android && budget != null
            ? math
                  .min(
                    active.memoryBudgetMiB,
                    budget.recommendedTotalMemoryBudgetMiB,
                  )
                  .toInt()
            : active.memoryBudgetMiB;
        final effectiveWorkers = _android && budget != null
            ? math
                  .min(
                    active.workers,
                    budget.recommendedTotalMemoryBudgetMiB <= 512 ||
                            budget.isStorageConstrained
                        ? 1
                        : budget.recommendedTotalCpuWorkers,
                  )
                  .toInt()
            : active.workers;
        final anticipatedJobId = active.nativeJobId ?? out.path;
        if (!await _enableMobileRuntimeBeforeStart(anticipatedJobId)) return;
        final response = await _api.start(
          buildSphericalRequest(active),
          out.path,
          memoryBudgetMiB: effectiveMemory,
          workers: effectiveWorkers,
        );
        final jobId = response['jobId'] as String? ?? active.outputDirectory;
        final guardedPhase = jobId == anticipatedJobId
            ? null
            : await _enableMobileRuntime(jobId);
        if (guardedPhase != null) {
          if (jobId != anticipatedJobId) {
            _runtimeGuardedJobs.remove(anticipatedJobId);
            await _runtime?.setProcessingActive(false, jobId: anticipatedJobId);
          }
          active = active.copyWith(
            nativeJobId: jobId,
            phase: guardedPhase,
            pauseReason: guardedPhase == StitchPhase.paused
                ? 'Android 无法启动后台运行保护，任务已安全暂停'
                : 'Android 无法确认后台安全暂停，正在核对原生任务状态',
          );
          await _persist(active);
          if (guardedPhase != StitchPhase.paused) _beginPolling();
          if (mounted) {
            setState(() => _message = active.pauseReason);
          }
          return;
        }
        active = active.copyWith(
          nativeJobId: jobId,
          phase: _phase(response['state']),
          stage: response['stage'] as String? ?? 'queued',
          progress: 0,
          timeline: _mergeResponseTimeline(active, response, jobId),
        );
      }
      await _persist(active);
      try {
        await _lock.enable();
      } on Object catch (error) {
        if (_mobile) {
          _pauseRequested = true;
          if (mounted) setState(() => _message = '前台任务锁不可用，正在请求暂停：$error');
        } else if (mounted) {
          setState(() => _message = '无法启用前台任务锁：$error');
        }
      }
      _beginPolling();
    } on Object catch (error) {
      final pendingJobId = _task?.nativeJobId ?? _task?.outputDirectory;
      if (_android && pendingJobId != null) {
        _runtimeGuardedJobs.remove(pendingJobId);
        await _runtime?.setProcessingActive(false, jobId: pendingJobId);
      }
      final text = error.toString();
      var failed = _task;
      if (failed != null &&
          (text.contains('STALE') ||
              text.contains('SOURCE') ||
              text.contains('FINGERPRINT'))) {
        failed = failed.copyWith(
          phase: StitchPhase.failed,
          clearNativeJobId: true,
          error: '原片或参数已变化；请重新预览并重新开始。',
        );
      } else if (failed != null &&
          error is NativeJobException &&
          error.code == 'RESOURCE_BUSY') {
        failed = failed.copyWith(error: '核心资源暂时繁忙，任务保留供稍后继续。');
      } else if (failed != null) {
        failed = failed.copyWith(error: text, phase: StitchPhase.failed);
      }
      if (failed != null) await _persist(failed);
      setState(() => _message = '无法启动：$text');
    } finally {
      if (mounted) setState(() => _busy = false);
      if (_pauseRequested && mounted) {
        _pauseRequested = false;
        unawaited(_requestPause('操作完成后已提交暂停请求'));
      }
    }
  }

  Future<void> _requestPause(String reason) async {
    final task = _task;
    if (task?.nativeJobId == null ||
        task!.phase == StitchPhase.paused ||
        _isActivelyBatchOwned(task)) {
      return;
    }
    if (_busy) {
      _pauseRequested = true;
      setState(() => _message = '$reason（等待当前操作完成）');
      return;
    }
    if (_controlInFlight) return;
    _controlInFlight = true;
    final generation = ++_controlGeneration;
    try {
      final response = await _api.pause(task.nativeJobId!);
      if (!_isCurrentSelection(generation, task.id) ||
          !identical(task, _task)) {
        return;
      }
      final updated = task.copyWith(
        phase: _phase(response['state']),
        pauseReason: reason,
        autoExportOnCompletion: false,
        timeline: _mergeResponseTimeline(task, response, task.nativeJobId!),
      );
      await _persist(
        updated,
        expectedGeneration: generation,
        expectedTaskId: task.id,
      );
      if (!_isCurrentSelection(generation, task.id)) return;
      if (updated.phase == StitchPhase.paused && _android) {
        _runtimeGuardedJobs.remove(task.nativeJobId!);
        await _runtime!.setProcessingActive(false, jobId: task.nativeJobId!);
      }
      if (updated.phase == StitchPhase.paused) await _lock.disable();
      setState(() => _message = reason);
      _beginPolling();
    } on Object catch (error) {
      if (_isCurrentSelection(generation, task.id)) {
        setState(() => _message = '暂停请求失败：$error');
      }
    } finally {
      _controlInFlight = false;
    }
  }

  Future<void> _cancel() async {
    final task = _task;
    if (task == null ||
        task.nativeJobId == null ||
        _busy ||
        _isActivelyBatchOwned(task)) {
      return;
    }
    final generation = ++_controlGeneration;
    _controlInFlight = true;
    setState(() => _busy = true);
    try {
      final response = await _api.cancel(task.nativeJobId!);
      if (!_isCurrentSelection(generation, task.id) ||
          !identical(task, _task)) {
        return;
      }
      final updated = task.copyWith(
        phase: _phase(response['state']),
        pauseReason: '已请求取消；等待核心确认',
        autoExportOnCompletion: false,
        timeline: _mergeResponseTimeline(task, response, task.nativeJobId!),
      );
      if (updated.phase == StitchPhase.cancelled && _android) {
        _runtimeGuardedJobs.remove(task.nativeJobId!);
        await _runtime!.setProcessingActive(false, jobId: task.nativeJobId!);
      }
      await _persist(
        updated,
        expectedGeneration: generation,
        expectedTaskId: task.id,
      );
      if (!_isCurrentSelection(generation, task.id)) return;
      _beginPolling();
    } on Object catch (error) {
      if (_isCurrentSelection(generation, task.id)) {
        setState(() => _message = '取消请求失败：$error');
      }
    } finally {
      _controlInFlight = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    final task = _task;
    if (task == null || task.nativeJobId == null || _busy || _exportInFlight) {
      return;
    }
    if (_isActivelyBatchOwned(task)) return;
    _exportInFlight = true;
    if (mounted) {
      setState(() {
        _busy = true;
        _message = null;
      });
    }
    try {
      await _exportTask(task);
    } on Object catch (error) {
      final current = _task;
      if (current?.id == task.id) {
        await _persist(
          current!.copyWith(
            phase: StitchPhase.completed,
            stage: 'export-failed',
            autoExportOnCompletion: false,
            clearExportCheckpointPath: true,
            error: '整图导出失败：$error',
          ),
        );
      }
      if (mounted) setState(() => _message = '整图导出失败：$error');
    } finally {
      _exportInFlight = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportTask(StitchTask task) async {
    if (task.exportFormat == ExportFormat.jpegXl && !_jpegXlAvailable) {
      setState(() => _message = '此原生核心未报告内置 JPEG XL 编码器，已阻止导出。');
      return;
    }
    if (!await _androidCanStart()) {
      if (_android && task.autoExportOnCompletion && task.nativeJobId != null) {
        await _persist(
          task.copyWith(
            phase: StitchPhase.completed,
            stage: 'auto-export-deferred',
            clearExportCheckpointPath: true,
          ),
        );
        _beginPolling();
      } else if (task.phase == StitchPhase.exporting) {
        await _persist(
          task.copyWith(
            phase: StitchPhase.completed,
            stage: 'export-deferred',
            clearExportCheckpointPath: true,
          ),
        );
      }
      return;
    }
    if (!await _confirmLargeJob(task)) {
      if (task.phase == StitchPhase.exporting) {
        await _persist(
          task.copyWith(
            phase: StitchPhase.completed,
            stage: 'done',
            autoExportOnCompletion: false,
            clearExportCheckpointPath: true,
          ),
        );
      }
      return;
    }
    final guardFailurePhase =
        _android && _runtimeGuardedJobs.contains(task.nativeJobId)
        ? null
        : await _enableMobileRuntime(task.nativeJobId!);
    if (guardFailurePhase != null) {
      await _persist(
        task.copyWith(
          phase: guardFailurePhase,
          stage: 'export-deferred',
          clearExportCheckpointPath: true,
          error: guardFailurePhase == StitchPhase.completed
              ? 'Android 无法启动后台运行保护；未开始导出。'
              : 'Android 无法确认安全暂停；正在核对原生任务状态。',
        ),
      );
      if (guardFailurePhase != StitchPhase.paused &&
          guardFailurePhase != StitchPhase.completed &&
          guardFailurePhase != StitchPhase.failed &&
          guardFailurePhase != StitchPhase.cancelled) {
        _beginPolling();
      }
      setState(
        () => _message = guardFailurePhase == StitchPhase.completed
            ? '无法启动后台运行保护；整图导出未开始。'
            : 'Android 无法确认安全暂停，正在核对原生任务状态。',
      );
      return;
    }
    var exportTask = task;
    if (task.needsLargeJobConfirmation) {
      exportTask = task.copyWith(
        largeJobApprovalScope: task.currentLargeJobApprovalScope,
      );
    }
    final directory = _mobile
        ? await getApplicationSupportDirectory()
        : await getApplicationDocumentsDirectory();
    final exportDirectory = Directory(p.join(directory.path, 'LumiaStitch'));
    await exportDirectory.create(recursive: true);
    final privateDestination =
        exportTask.exportCheckpointPath ??
        p.join(
          exportDirectory.path,
          '${task.id}-${DateTime.now().toUtc().microsecondsSinceEpoch}.${task.exportFormat.extension}',
        );
    final destination = Platform.isWindows && exportTask.exportDirectory != null
        ? p.join(exportTask.exportDirectory!, p.basename(privateDestination))
        : privateDestination;
    if (Platform.isWindows && exportTask.exportDirectory != null) {
      await Directory(exportTask.exportDirectory!).create(recursive: true);
    }
    final exportIntentTask = exportTask.autoExportOnCompletion
        ? exportTask
        : exportTask.copyWith(autoExportOnCompletion: true);
    setState(() {
      _busy = true;
      _message = null;
    });
    _controlGeneration++;
    final controlGeneration = _controlGeneration;
    try {
      await _persist(
        exportIntentTask.copyWith(
          phase: StitchPhase.exporting,
          stage: 'export',
          exportCheckpointPath: destination,
        ),
      );
      final response = await _api.export(task.nativeJobId!, destination);
      final state = response['state'] as String? ?? 'running';
      if (state == 'completed') {
        final fingerprint = await _repository.fingerprintFile(destination);
        if (fingerprint == null) {
          throw StateError('核心报告导出完成，但输出文件不存在或为空。');
        }
        var completed = exportIntentTask.copyWith(
          phase: StitchPhase.completed,
          stage: 'done',
          autoExportOnCompletion: false,
          exportPath: destination,
          exportFingerprint: fingerprint,
          clearExportCheckpointPath: true,
          timeline: _mergeResponseTimeline(
            exportIntentTask,
            response,
            task.nativeJobId!,
          ),
        );
        if (completed.exportDirectory != null) {
          completed = await _publishExport(
            completed,
            expectedGeneration: controlGeneration,
          );
        }
        await _persist(
          completed,
          expectedGeneration: controlGeneration,
          expectedTaskId: task.id,
        );
      } else if (state == 'failed' || state == 'cancelled') {
        await _persist(
          exportIntentTask.copyWith(
            phase: StitchPhase.completed,
            stage: 'export-failed',
            autoExportOnCompletion: false,
            clearExportCheckpointPath: true,
            error: task.exportPath == null
                ? '整图导出$state。'
                : '新整图导出$state；保留了此前成功的导出文件。',
            timeline: _mergeResponseTimeline(
              exportIntentTask,
              response,
              task.nativeJobId!,
            ),
          ),
        );
      } else {
        await _persist(
          exportIntentTask.copyWith(
            phase: _phase(state),
            stage: 'export',
            exportCheckpointPath: destination,
            clearError: true,
            timeline: _mergeResponseTimeline(
              exportIntentTask,
              response,
              task.nativeJobId!,
            ),
          ),
        );
      }
      try {
        await _lock.enable();
      } on Object catch (error) {
        if (_mobile) {
          _pauseRequested = true;
          if (mounted) setState(() => _message = '前台任务锁不可用，正在请求暂停：$error');
        } else if (mounted) {
          setState(() => _message = '无法启用前台任务锁：$error');
        }
      }
      _beginPolling();
    } on Object catch (error) {
      await _lock.disable();
      await _persist(
        exportIntentTask.copyWith(
          phase: StitchPhase.completed,
          stage: 'export-failed',
          autoExportOnCompletion: false,
          clearExportCheckpointPath: true,
          error: '整图导出失败：$error',
        ),
      );
      setState(() => _message = '整图导出失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
      if (_pauseRequested && mounted) {
        _pauseRequested = false;
        unawaited(_requestPause('操作完成后已提交暂停请求'));
      }
    }
  }

  Future<void> _shareExport() async {
    final exportTask = _task;
    final path = exportTask?.exportPath;
    if (_mobile &&
        !_android &&
        exportTask != null &&
        !exportTask.exportFormat.supportedOnMobile) {
      setState(() => _message = '此移动版目前仅支持已验证的 PNG 导出。');
      return;
    }
    if (path == null || !await File(path).exists()) {
      setState(() => _message = '完整${_task?.exportFormat.label ?? '图像'}尚未生成。');
      return;
    }
    try {
      if (_android) {
        await _storage.shareExport(
          path,
          mimeType: _mimeType(exportTask!.exportFormat),
        );
      } else if (_mobile) {
        await const MethodChannel(
          'com.lumiaiq.pocketgigascan/files',
        ).invokeMethod<bool>('shareExport', {'path': path});
      } else {
        final directory = p.dirname(path);
        final command = Platform.isWindows
            ? 'explorer.exe'
            : Platform.isMacOS
            ? 'open'
            : 'xdg-open';
        await Process.start(command, [
          directory,
        ], mode: ProcessStartMode.detached);
        setState(() => _message = '已在文件管理器中打开导出文件夹。');
      }
    } on Object catch (error) {
      setState(() => _message = '无法分享导出文件：$error');
    }
  }

  Future<void> _openExportViewer(StitchTask task) async {
    final path = task.exportPath;
    if (_mobile && !_android) {
      if (mounted) setState(() => _message = '本期大图查看器仅在 Windows 桌面版提供。');
      return;
    }
    if (path == null || !await File(path).exists()) {
      if (mounted) setState(() => _message = '此任务没有可打开的已成功导出照片。');
      return;
    }
    final legacyAssociationPresent =
        task.exportFingerprint != null || task.exportCheckpointPath != path;
    var nativeVerified = false;
    if (task.exportFingerprint == null && task.nativeJobId != null) {
      try {
        final snapshot = await _api.status(task.nativeJobId!);
        nativeVerified =
            snapshot['state'] == 'completed' &&
            snapshot['operation'] == 'export' &&
            snapshot['exportDestination'] is String &&
            nativeJobPathsMatch(snapshot['exportDestination']! as String, path);
      } on Object {
        // Legacy task metadata remains an explicit, unverified association.
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ExportedImageViewer(
          exportFilePath: path,
          pyramidDirectory: task.outputDirectory,
          expectedExportFingerprint: task.exportFingerprint,
          legacyTaskAssociationPresent: legacyAssociationPresent,
          legacyTaskBindingVerified: nativeVerified,
          mobileStorageService: _android ? _storage : null,
          exportMimeType: _mimeType(task.exportFormat),
        ),
      ),
    );
  }

  String _mimeType(ExportFormat format) => switch (format) {
    ExportFormat.png => 'image/png',
    ExportFormat.tiff => 'image/tiff',
    ExportFormat.jpegXl => 'image/jxl',
  };

  Future<void> _deleteTask(StitchTask task) async {
    if (_busy || !_batchOwnershipReady || _isActivelyBatchOwned(task)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本地任务？'),
        content: const Text('只删除任务记录和队列引用。已导入原片、渲染瓦片及导出照片都会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除任务记录'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        !_batchOwnershipReady ||
        _isActivelyBatchOwned(task)) {
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    _controlGeneration++;
    _poll?.cancel();
    try {
      await _performanceSaveQueue.enqueue(() async {});
      final batchController = _batchController;
      if (batchController != null) {
        await batchController.removeTask(task.id);
      } else {
        await _stopNativeTask(task);
        await _repository.removeTaskRecord(task.id);
      }
      if (!mounted) return;
      setState(() {
        _tasks = [
          for (final value in _tasks)
            if (value.id != task.id) value,
        ];
        if (_task?.id == task.id) {
          _task = null;
          _manifest = null;
          _mappingCells = const [];
        }
        _message = '任务记录已删除；原片、瓦片和已导出照片已保留。';
      });
      await _refreshTasks();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _message = '未删除任务，原生停止未能确认：$error';
        });
      }
      if (_hasRunningJob) _beginPolling();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopNativeTask(StitchTask task) async {
    final jobId = task.nativeJobId;
    if (jobId == null) {
      if (const {
        StitchPhase.queued,
        StitchPhase.running,
        StitchPhase.pausing,
        StitchPhase.exporting,
      }.contains(task.phase)) {
        throw StateError('任务缺少原生作业编号');
      }
      return;
    }
    var state = (await _api.status(jobId))['state'] as String? ?? 'unknown';
    bool active(String value) =>
        const {'queued', 'running', 'pausing', 'exporting'}.contains(value);
    if (active(state)) {
      await _api.cancel(jobId);
      for (var attempt = 0; attempt < 120; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        state = (await _api.status(jobId))['state'] as String? ?? 'unknown';
        if (!active(state)) break;
      }
    }
    if (active(state) ||
        !const {'completed', 'failed', 'cancelled', 'paused'}.contains(state)) {
      throw StateError('原生任务状态为 $state');
    }
  }

  StitchPhase _phase(Object? value) => switch (value) {
    'queued' => StitchPhase.queued,
    'running' => StitchPhase.running,
    'pausing' => StitchPhase.pausing,
    'paused' => StitchPhase.paused,
    'completed' => StitchPhase.completed,
    'cancelled' => StitchPhase.cancelled,
    'failed' => StitchPhase.failed,
    _ => StitchPhase.interrupted,
  };

  Future<void> _persist(
    StitchTask updated, {
    int? expectedGeneration,
    String? expectedTaskId,
  }) async {
    final previous = _task?.id == updated.id ? _task : null;
    var mergedTimeline = (previous?.timeline ?? const StitchTimeline()).merge(
      updated.timeline,
    );
    final priorEventIds =
        previous?.timeline.events.map((event) => event.id).toSet() ??
        const <String>{};
    final jobId = updated.nativeJobId ?? previous?.nativeJobId;
    final nativeTransitionObserved =
        jobId != null &&
        mergedTimeline.events.any(
          (event) =>
              event.id.startsWith('native:$jobId:') &&
              !priorEventIds.contains(event.id) &&
              event.state == updated.phase.name,
        );
    if (previous != null &&
        !nativeTransitionObserved &&
        (previous.phase != updated.phase || previous.stage != updated.stage)) {
      final sequence =
          mergedTimeline.events
              .where((event) => event.id.startsWith('ui:${updated.id}:'))
              .length +
          1;
      mergedTimeline = mergedTimeline.mergeUiEvent(
        id: 'ui:${updated.id}:$sequence',
        kind: 'lifecycle',
        stage: updated.stage,
        state: updated.phase.name,
        operation:
            updated.phase == StitchPhase.exporting ||
                previous.phase == StitchPhase.exporting ||
                updated.stage.contains('export') ||
                previous.stage.contains('export')
            ? 'export'
            : 'render',
      );
    }
    updated = updated.copyWith(timeline: mergedTimeline);
    await _repository.save(updated);
    if (!mounted) return;
    final selectionStillMatches =
        expectedGeneration == null ||
        (expectedGeneration == _controlGeneration &&
            _task?.id == expectedTaskId);
    setState(() {
      if (selectionStillMatches) {
        _task = updated;
        _grid = updated.grid;
      }
      final index = _tasks.indexWhere((item) => item.id == updated.id);
      if (index < 0) {
        _tasks = [updated, ..._tasks];
      } else {
        final next = [..._tasks];
        next[index] = updated;
        _tasks = next;
      }
    });
  }

  bool _isCurrentSelection(int generation, String taskId) =>
      mounted && generation == _controlGeneration && _task?.id == taskId;

  void _beginPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    if (_pollInFlight || _controlInFlight) return;
    final task = _task;
    if (task == null || task.nativeJobId == null) {
      _poll?.cancel();
      return;
    }
    _pollInFlight = true;
    final controlGeneration = _controlGeneration;
    var shouldAutoExport = false;
    try {
      final state = await _api.status(task.nativeJobId!);
      if (!_isCurrentSelection(controlGeneration, task.id) ||
          !identical(task, _task)) {
        return;
      }
      var phase = _phase(state['state']);
      final operation = state['operation'] as String? ?? 'render';
      if (operation == 'export' &&
          (phase == StitchPhase.failed || phase == StitchPhase.cancelled)) {
        phase = StitchPhase.completed;
      }
      final stage = state['stage'] as String? ?? task.stage;
      var timeline = task.timeline;
      final rawEvents = state['events'];
      if (rawEvents is List) {
        timeline = timeline.mergeNativeBatch(
          rawEvents
              .whereType<Map>()
              .map((event) => Map<String, Object?>.from(event))
              .toList(),
          jobId: task.nativeJobId!,
        );
      }
      final progress = (state['progress'] as num? ?? task.progress)
          .toDouble()
          .clamp(0, 1);
      if (_android &&
          {
            StitchPhase.queued,
            StitchPhase.running,
            StitchPhase.exporting,
            StitchPhase.pausing,
          }.contains(phase) &&
          !_runtimeGuardedJobs.contains(task.nativeJobId) &&
          !_runtimeGuardUnavailableJobs.contains(task.nativeJobId)) {
        final guardedPhase = await _enableMobileRuntime(task.nativeJobId!);
        if (guardedPhase != null) {
          await _persist(
            task.copyWith(
              phase: guardedPhase,
              pauseReason: guardedPhase == StitchPhase.paused
                  ? 'Android 无法启动后台运行保护，任务已安全暂停'
                  : 'Android 无法确认后台安全暂停，正在核对原生任务状态',
            ),
          );
          if (guardedPhase != StitchPhase.paused) _beginPolling();
          return;
        }
      }
      if (_background &&
          (!_android ||
              _runtime == null ||
              !_runtimeGuardedJobs.contains(task.nativeJobId)) &&
          {StitchPhase.running, StitchPhase.exporting}.contains(phase) &&
          phase != StitchPhase.pausing) {
        await _requestPause('应用在后台，暂停请求已提交');
        return;
      }
      final reportedExportPath = state['exportDestination'] as String?;
      final pendingPath = reportedExportPath ?? task.exportCheckpointPath;
      final reportedSuccessfulExport =
          phase == StitchPhase.completed && operation == 'export';
      final failedExport =
          operation == 'export' &&
          {
            StitchPhase.failed,
            StitchPhase.cancelled,
          }.contains(_phase(state['state']));
      final reportedPath = reportedSuccessfulExport
          ? pendingPath ?? task.exportPath
          : task.exportPath;
      var exportFingerprint = task.exportFingerprint;
      if (reportedSuccessfulExport && reportedPath != null) {
        exportFingerprint = await _repository.fingerprintFile(reportedPath);
        if (!_isCurrentSelection(controlGeneration, task.id) ||
            !identical(task, _task)) {
          return;
        }
      }
      final successfulExport =
          reportedSuccessfulExport &&
          (reportedPath == task.exportPath || exportFingerprint != null);
      shouldAutoExport =
          operation == 'render' &&
          phase == StitchPhase.completed &&
          state['error'] == null &&
          task.autoExportOnCompletion;
      final exportPath = successfulExport ? reportedPath : task.exportPath;
      final checkpointPath = successfulExport
          ? null
          : operation == 'export'
          ? pendingPath
          : task.exportCheckpointPath;
      final updated = task.copyWith(
        timeline: timeline,
        phase: shouldAutoExport
            ? StitchPhase.exporting
            : reportedSuccessfulExport
            ? StitchPhase.completed
            : phase,
        stage: shouldAutoExport
            ? 'auto-export'
            : failedExport
            ? 'export-failed'
            : stage,
        autoExportOnCompletion: operation == 'export'
            ? false
            : task.autoExportOnCompletion,
        progress: progress.toDouble(),
        exportPath: exportPath,
        exportFingerprint: exportFingerprint,
        exportCheckpointPath: checkpointPath,
        clearExportCheckpointPath: reportedSuccessfulExport,
        clearExportFingerprint:
            reportedSuccessfulExport &&
            exportPath != task.exportPath &&
            exportFingerprint == null,
        error: reportedSuccessfulExport && !successfulExport
            ? '核心报告导出完成，但输出文件不存在或为空；保留上次成功输出。'
            : failedExport
            ? task.exportPath == null
                  ? '整图导出失败。'
                  : '新整图导出失败；保留了此前成功的导出文件。'
            : state['error'] is Map
            ? '${(state['error'] as Map)['code'] ?? 'ERROR'}: ${(state['error'] as Map)['message'] ?? '未知错误'}'
            : state['error'] is String
            ? state['error'] as String
            : null,
        resultStats: state['resultStats'] is Map
            ? {
                ...Map<String, Object?>.from(state['resultStats'] as Map),
                if (state['exportFormat'] is String)
                  'exportFormat': state['exportFormat'],
                if (state['tiffVariant'] is String)
                  'tiffVariant': state['tiffVariant'],
              }
            : task.resultStats,
        clearError: state['error'] == null && successfulExport,
      );
      final withPublication =
          reportedSuccessfulExport &&
              successfulExport &&
              task.exportDirectory != null &&
              (task.publishedExportPath == null ||
                  task.publishError != null ||
                  task.phase == StitchPhase.exporting ||
                  task.stage == 'auto-export' ||
                  task.stage == 'export' ||
                  task.exportPath != reportedPath)
          ? await _publishExport(updated, expectedGeneration: controlGeneration)
          : updated;
      if (_android &&
          {
            StitchPhase.paused,
            StitchPhase.completed,
            StitchPhase.failed,
            StitchPhase.cancelled,
          }.contains(updated.phase)) {
        _runtimeGuardedJobs.remove(task.nativeJobId!);
        await _runtime!.setProcessingActive(false, jobId: task.nativeJobId!);
      }
      if (!_isCurrentSelection(controlGeneration, task.id) ||
          !identical(task, _task)) {
        return;
      }
      await _persist(
        withPublication,
        expectedGeneration: controlGeneration,
        expectedTaskId: task.id,
      );
      if (!_isCurrentSelection(controlGeneration, task.id)) return;
      if (phase == StitchPhase.paused ||
          phase == StitchPhase.completed ||
          phase == StitchPhase.cancelled ||
          phase == StitchPhase.failed) {
        _poll?.cancel();
        await _lock.disable();
        if (phase == StitchPhase.completed) {
          await _loadManifest(
            updated,
            expectedGeneration: controlGeneration,
            expectedTaskId: task.id,
          );
          if (!_isCurrentSelection(controlGeneration, task.id)) return;
        }
      }
    } on Object catch (error) {
      if (_isCurrentSelection(controlGeneration, task.id)) {
        setState(() => _message = '读取进度失败：$error');
      }
    } finally {
      _pollInFlight = false;
    }
    if (shouldAutoExport) await _batchOwnershipReadySignal.future;
    if (shouldAutoExport && _isCurrentSelection(controlGeneration, task.id)) {
      await _export();
    }
  }

  Future<StitchTask> _publishExport(
    StitchTask task, {
    int? expectedGeneration,
  }) async {
    final destination = task.exportDirectory;
    final source = task.exportPath;
    if (destination == null || source == null) return task;
    if (_task?.id == task.id &&
        !_isCurrentSelection(
          expectedGeneration ?? _controlGeneration,
          task.id,
        )) {
      return task;
    }
    final started = _withPublicationEvent(task, 'running');
    await _repository.save(started);
    try {
      final name = p.basename(source);
      final mime = switch (task.exportFormat) {
        ExportFormat.png => 'image/png',
        ExportFormat.tiff => 'image/tiff',
        ExportFormat.jpegXl => 'image/jxl',
      };
      if (_android) {
        final published = await _storage.publishExport(
          source,
          destinationUri: destination,
          mimeType: mime,
          suggestedName: name,
        );
        return _withPublicationEvent(
          started.copyWith(
            publishedExportPath: published.uri,
            clearPublishError: true,
          ),
          'completed',
        );
      }
      final directory = Directory(destination);
      await directory.create(recursive: true);
      if (Platform.isWindows &&
          p.equals(
            p.normalize(p.absolute(p.dirname(source))),
            p.normalize(p.absolute(destination)),
          )) {
        return _withPublicationEvent(
          started.copyWith(
            publishedExportPath: source,
            clearPublishError: true,
          ),
          'completed',
        );
      }
      final output = await File(source).copy(p.join(directory.path, name));
      return _withPublicationEvent(
        started.copyWith(
          publishedExportPath: output.path,
          clearPublishError: true,
        ),
        'completed',
      );
    } catch (error) {
      return _withPublicationEvent(
        started.copyWith(publishError: error.toString()),
        'failed',
      );
    }
  }

  StitchTimeline _mergeResponseTimeline(
    StitchTask task,
    Map<String, Object?> response,
    String jobId,
  ) {
    final events = response['events'];
    if (events is! List) return task.timeline;
    return task.timeline.mergeNativeBatch(
      events
          .whereType<Map>()
          .map((event) => Map<String, Object?>.from(event))
          .toList(),
      jobId: jobId,
    );
  }

  StitchTask _withPublicationEvent(StitchTask task, String state) {
    final prefix = 'ui:${task.id}:';
    final sequence =
        task.timeline.events
            .where((event) => event.id.startsWith(prefix))
            .length +
        1;
    return task.copyWith(
      timeline: task.timeline.mergeUiEvent(
        id: '$prefix$sequence',
        kind: 'publication',
        stage: switch (state) {
          'running' => 'publishing',
          'completed' => 'published',
          _ => 'publish-failed',
        },
        state: state,
        operation: 'publish',
      ),
    );
  }

  Future<void> _retryPublish(StitchTask task) async {
    if (_busy || _task?.id != task.id) return;
    final generation = _controlGeneration;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await _publishExport(
        task.copyWith(clearPublishError: true),
        expectedGeneration: generation,
      );
      if (_isCurrentSelection(generation, task.id)) {
        await _persist(
          result,
          expectedGeneration: generation,
          expectedTaskId: task.id,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadManifest(
    StitchTask task, {
    int? expectedGeneration,
    String? expectedTaskId,
  }) async {
    final manifestFile = File(p.join(task.outputDirectory, 'manifest.json'));
    if (!await manifestFile.exists()) return;
    try {
      final decoded = jsonDecode(await manifestFile.readAsString());
      final selectionMatches =
          expectedGeneration == null ||
          _isCurrentSelection(expectedGeneration, expectedTaskId!);
      if (decoded is Map<String, Object?> && mounted && selectionMatches) {
        setState(() {
          _manifest = decoded;
          _viewerLevel = null;
          _viewerScale = 1;
          _tileTransform.value = Matrix4.identity();
        });
      }
    } on Object catch (error) {
      final selectionMatches =
          expectedGeneration == null ||
          _isCurrentSelection(expectedGeneration, expectedTaskId!);
      if (mounted && selectionMatches) {
        setState(() => _message = '金字塔清单无效：$error');
      }
    }
  }

  Future<void> _selectTask(StitchTask task) async {
    final wasBusy = _busy;
    final selectionGeneration = _controlGeneration;
    final taskId = task.id;
    if (!wasBusy) setState(() => _busy = true);
    var shouldAutoExport = false;
    try {
      await _batchOwnershipReadySignal.future;
      if (!mounted ||
          selectionGeneration != _controlGeneration ||
          task.id != taskId) {
        return;
      }
      shouldAutoExport = await _selectTaskImpl(task);
    } finally {
      if (!wasBusy && mounted) setState(() => _busy = false);
    }
    if (shouldAutoExport && !wasBusy && mounted && _task?.id == task.id) {
      await _export();
    }
  }

  Future<bool> _selectTaskImpl(StitchTask task) async {
    final selectionGeneration = ++_controlGeneration;
    _poll?.cancel();
    await _performanceSaveQueue.enqueue(() async {});
    if (!mounted || selectionGeneration != _controlGeneration) return false;
    task = await _enrichLegacyPhotoMetadata(task);
    if (!mounted || selectionGeneration != _controlGeneration) return false;
    _grid = task.grid;
    _rows.text = '${task.grid.rows}';
    _columns.text = '${task.grid.columns}';
    _fov.text = '${task.horizontalFovDegrees}';
    _memory.text = '${task.memoryBudgetMiB}';
    _workers.text = '${task.workers}';
    _forceGridFallback = task.forceGridFallback;
    _autoGridOverlap = task.autoGridOverlap;
    _cameraCalibrationTouched = task.cameraCalibrationOverridden;
    _performanceOptions = task.performanceOptions;
    _horizontalOverlap.text = '${(task.gridHorizontalOverlap * 100).round()}';
    _verticalOverlap.text = '${(task.gridVerticalOverlap * 100).round()}';
    _fx.clear();
    setState(() {
      _task = task;
      _exportFormat = task.exportFormat;
      _mappingCells = _makeMapping(task.grid);
      _manifest = null;
      _message = null;
      _diagnosticsPanelGeneration++;
    });
    if (task.phase == StitchPhase.completed) {
      await _loadManifest(
        task,
        expectedGeneration: selectionGeneration,
        expectedTaskId: task.id,
      );
      if (!_isCurrentSelection(selectionGeneration, task.id)) return false;
      return task.autoExportOnCompletion;
    } else if (task.nativeJobId != null &&
        {
          StitchPhase.interrupted,
          StitchPhase.queued,
          StitchPhase.running,
          StitchPhase.pausing,
          StitchPhase.exporting,
        }.contains(task.phase)) {
      try {
        final snapshot = await _api.status(task.nativeJobId!);
        if (!_isCurrentSelection(selectionGeneration, task.id) ||
            !identical(task, _task)) {
          return false;
        }
        final phase = _phase(snapshot['state']);
        final operation = snapshot['operation'] as String? ?? 'render';
        final nativeDestination = snapshot['exportDestination'] as String?;
        final pendingExportCompleted =
            phase == StitchPhase.completed &&
            operation == 'export' &&
            nativeDestination != null &&
            (nativeDestination == task.exportCheckpointPath ||
                nativeDestination == task.exportPath);
        final recoveredFingerprint = pendingExportCompleted
            ? await _repository.fingerprintFile(nativeDestination)
            : task.exportFingerprint;
        if (!_isCurrentSelection(selectionGeneration, task.id) ||
            !identical(task, _task)) {
          return false;
        }
        final recoveredExportValid =
            pendingExportCompleted && recoveredFingerprint != null;
        final error = snapshot['error'] is Map
            ? '${(snapshot['error'] as Map)['code'] ?? 'ERROR'}: ${(snapshot['error'] as Map)['message'] ?? '未知错误'}'
            : snapshot['error'] is String
            ? snapshot['error'] as String
            : null;
        final reconciled = task.copyWith(
          phase: phase,
          autoExportOnCompletion: operation == 'export'
              ? false
              : task.autoExportOnCompletion,
          stage: snapshot['stage'] as String? ?? task.stage,
          progress: (snapshot['progress'] as num? ?? task.progress).toDouble(),
          exportPath: recoveredExportValid
              ? nativeDestination
              : task.exportPath,
          exportFingerprint: recoveredFingerprint,
          clearExportCheckpointPath: pendingExportCompleted,
          error: pendingExportCompleted && !recoveredExportValid
              ? '核心报告导出完成，但输出文件不存在或为空；保留上次成功输出。'
              : error,
          clearError:
              error == null &&
              (!pendingExportCompleted || recoveredExportValid),
        );
        await _persist(
          reconciled,
          expectedGeneration: selectionGeneration,
          expectedTaskId: task.id,
        );
        if (!_isCurrentSelection(selectionGeneration, task.id)) return false;
        if (phase == StitchPhase.completed) {
          await _loadManifest(
            reconciled,
            expectedGeneration: selectionGeneration,
            expectedTaskId: task.id,
          );
          if (!_isCurrentSelection(selectionGeneration, task.id)) return false;
        } else if ({
          StitchPhase.queued,
          StitchPhase.running,
          StitchPhase.pausing,
          StitchPhase.exporting,
        }.contains(phase)) {
          _beginPolling();
        }
        return phase == StitchPhase.completed &&
            operation == 'render' &&
            error == null &&
            task.autoExportOnCompletion;
      } on Object catch (error) {
        if (_isCurrentSelection(selectionGeneration, task.id)) {
          setState(() => _message = '恢复任务状态失败：$error');
        }
      }
    }
    return false;
  }

  Future<void> _newRunCopy() async {
    await _createRunCopy(forceGridFallback: false);
  }

  Future<void> _forceGridRetry() async {
    await _createRunCopy(forceGridFallback: true);
  }

  Future<void> _createRunCopy({required bool forceGridFallback}) async {
    final old = _task;
    if (old == null ||
        _busy ||
        !_batchOwnershipReady ||
        _isActivelyBatchOwned(old)) {
      return;
    }
    setState(() => _busy = true);
    try {
      var copy = await _repository.duplicateForNewRun(old);
      if (forceGridFallback) {
        copy = copy.copyWith(forceGridFallback: true, autoGridOverlap: false);
        await _repository.save(copy);
      }
      setState(() {
        _task = copy;
        _grid = copy.grid;
        _forceGridFallback = copy.forceGridFallback;
        _autoGridOverlap = copy.autoGridOverlap;
        _cameraCalibrationTouched = copy.cameraCalibrationOverridden;
        _performanceOptions = copy.performanceOptions;
        _exportFormat = copy.exportFormat;
        _refineGridNeighbors = copy.refineGridNeighbors;
        _seamBlendMode = copy.seamBlendMode;
        _localTextureWarp = copy.localTextureWarp;
        _horizontalOverlap.text =
            '${(copy.gridHorizontalOverlap * 100).round()}';
        _verticalOverlap.text = '${(copy.gridVerticalOverlap * 100).round()}';
        _fov.text = '${copy.horizontalFovDegrees}';
        _memory.text = '${copy.memoryBudgetMiB}';
        _workers.text = '${copy.workers}';
        _mappingCells = _makeMapping(copy.grid);
        _manifest = null;
        _diagnosticsPanelGeneration++;
      });
      await _refreshTasks();
    } on Object catch (error) {
      setState(() => _message = '无法创建新任务副本：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = _task;
    final mappingError = task == null ? null : _mappingError();
    return Scaffold(
      drawer: Drawer(child: SafeArea(child: _taskRail())),
      appBar: AppBar(
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            tooltip: StitchLocalizations.of(context).text('本地任务'),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: const Text('PocketGigaScan'),
        actions: [
          if (widget.settingsController != null)
            IconButton(
              tooltip: StitchLocalizations.of(context).settingsTitle,
              icon: const Icon(Icons.settings),
              onPressed: _openSettings,
            ),
          IconButton(
            tooltip: StitchLocalizations.of(
              context,
            ).text(_mobile && !_android ? '批处理仅限 Windows 桌面版' : '批处理队列'),
            onPressed: _mobile && !_android
                ? null
                : () async {
                    final navigator = Navigator.of(context);
                    await widget.settingsController?.ready;
                    if (!mounted) return;
                    await navigator.push(
                      MaterialPageRoute<void>(
                        builder: (_) => BatchQueuePage(
                          api: _api,
                          controller: _batchController,
                          mobileOverride: _mobile,
                          androidOverride: _android,
                          mobileStorageService: _storage,
                          runtimeService: _runtime,
                          resourceBudget: _resourceBudget,
                          settingsController: widget.settingsController,
                        ),
                      ),
                    );
                  },
            icon: const Icon(Icons.queue),
          ),
          if (_task != null)
            IconButton(
              tooltip: StitchLocalizations.of(context).text('删除本地任务记录'),
              onPressed: _busy || _isActivelyBatchOwned(_task)
                  ? null
                  : () => _deleteTask(_task!),
              icon: const Icon(Icons.delete_outline),
            ),
          IconButton(
            tooltip: StitchLocalizations.of(context).text('导入照片'),
            onPressed: _busy || !_editable ? null : _importPhotos,
            icon: const Icon(Icons.add_photo_alternate_outlined),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 760;
          return Row(
            children: [
              if (!narrow && constraints.maxWidth > 900)
                SizedBox(width: 230, child: _taskRail()),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _statusCard(task),
                    const SizedBox(height: 12),
                    if ((!_mobile || _android) &&
                        _canChooseOutputFormat(task)) ...[
                      _exportFormatCard(task),
                      const SizedBox(height: 12),
                    ],
                    if (task == null || task.photos.isEmpty)
                      _emptyCard()
                    else ...[
                      if (task.phase != StitchPhase.completed) ...[
                        _optionsCard(task, mappingError),
                        const SizedBox(height: 12),
                        _photoGrid(task, mappingError),
                        const SizedBox(height: 12),
                      ],
                      if (_manifest != null) _tilePyramid(task),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: task == null || task.photos.isEmpty
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : _importPhotos,
              icon: const Icon(Icons.add_photo_alternate),
              label: const Text('导入原片'),
            )
          : null,
    );
  }

  Future<void> _openSettings() async {
    final controller = widget.settingsController;
    if (controller == null) return;
    await controller.ready;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          controller: controller,
          android: _android,
          mobileStorageService: _storage,
        ),
      ),
    );
  }

  Widget _taskRail() => ListView(
    padding: const EdgeInsets.all(8),
    children: [
      const ListTile(title: Text('本地任务'), leading: Icon(Icons.folder_open)),
      for (final task in _tasks)
        ListTile(
          key: Key('task-row-${task.id}'),
          selected: task.id == _task?.id,
          title: Text(task.createdAt.toLocal().toString().substring(0, 16)),
          subtitle: Text(
            StitchLocalizations.of(context).taskSummary(
              photoCount: task.photos.length,
              phase: task.phase.name,
              format: task.exportFormat.shortLabel,
            ),
          ),
          enabled:
              _batchOwnershipReady &&
              !_busy &&
              (!_hasRunningJob || task.id == _task?.id),
          onTap:
              _batchOwnershipReady &&
                  !_busy &&
                  (!_hasRunningJob || task.id == _task?.id)
              ? () {
                  Navigator.of(context).maybePop();
                  _selectTask(task);
                }
              : null,
          trailing: IconButton(
            tooltip: StitchLocalizations.of(context).text('删除任务记录'),
            onPressed: _busy || _isActivelyBatchOwned(task)
                ? null
                : () => _deleteTask(task),
            icon: const Icon(Icons.delete_outline),
          ),
        ),
    ],
  );

  bool get _hasRunningJob =>
      _task?.nativeJobId != null &&
      const {
        StitchPhase.queued,
        StitchPhase.running,
        StitchPhase.pausing,
        StitchPhase.paused,
        StitchPhase.interrupted,
        StitchPhase.exporting,
      }.contains(_task!.phase);

  Widget _statusCard(StitchTask? task) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task == null
                ? '导入照片，创建本地全景任务'
                : '${task.photos.length} 张原片 · ${task.photos.isEmpty ? '' : '${task.photos.first.width}×${task.photos.first.height}'}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          if (task == null)
            Text(
              _api.isAvailable
                  ? '原生合成核心已加载'
                  : _api.unavailableReason ?? '原生核心不可用',
              style: TextStyle(
                color: _api.isAvailable
                    ? Colors.green.shade800
                    : Colors.deepOrange.shade800,
              ),
            ),
          if (task != null) ...[
            if (!_api.isAvailable)
              Text(
                _api.unavailableReason ?? '原生核心不可用',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (task.phase != StitchPhase.completed) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: task.progress == 0 ? null : task.progress,
              ),
              const SizedBox(height: 6),
              Text(
                '${_stageLabel(task.stage)} · ${(task.progress * 100).round()}% · ${_phaseLabel(task.phase)}',
              ),
            ],
            if (task.error != null)
              Text(
                task.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (task.publishError != null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    StitchLocalizations.of(
                      context,
                    ).outputCopyFailed(task.publishError!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : () => _retryPublish(task),
                    icon: const Icon(Icons.refresh),
                    label: Text(
                      StitchLocalizations.of(context).retryOutputCopy,
                    ),
                  ),
                ],
              ),
            if (task.pauseReason != null && task.phase == StitchPhase.pausing)
              Text(
                task.pauseReason!,
                style: const TextStyle(color: Colors.deepOrange),
              ),
            ExpansionTile(
              key: ValueKey(
                'task-diagnostics-${task.id}-$_diagnosticsPanelGeneration',
              ),
              tilePadding: EdgeInsets.zero,
              expandedAlignment: Alignment.centerLeft,
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              title: Text(StitchLocalizations.of(context).stitchDetails),
              children: [
                if (_api.isAvailable)
                  Text(
                    '原生合成核心已加载',
                    style: TextStyle(color: Colors.green.shade800),
                  ),
                if (task.phase == StitchPhase.completed &&
                    task.stage == 'export-failed')
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('整图导出失败，可重试'),
                  ),
                if ((task.autoExportOnCompletion &&
                        task.phase == StitchPhase.completed) ||
                    (task.phase == StitchPhase.exporting &&
                        task.stage == 'auto-export'))
                  Text('合成完成，正在导出 ${task.exportFormat.shortLabel}'),
                if (task.phase != StitchPhase.completed)
                  Text('完成后自动导出：${task.exportFormat.shortLabel}'),
                if (task.resultStats case final stats?)
                  ..._performanceStatsLines(stats),
                const Text('水平参考：以网格中心照片为准'),
              ],
            ),
            ExpansionTile(
              key: ValueKey(
                'task-stitch-log-${task.id}-$_diagnosticsPanelGeneration',
              ),
              tilePadding: EdgeInsets.zero,
              expandedAlignment: Alignment.centerLeft,
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              title: Text(StitchLocalizations.of(context).stitchingLog),
              children: [
                StitchingLog(
                  timeline: task.timeline,
                  eventLabel: _timelineEventLabel,
                  totalLabel: _timelineTotal(task),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (task.phase != StitchPhase.completed)
                  FilledButton.icon(
                    onPressed:
                        _busy ||
                            _isActivelyBatchOwned(task) ||
                            !_canStart ||
                            mappingErrorIsInvalid(task)
                        ? null
                        : () => _startOrResume(
                            resume:
                                task.phase == StitchPhase.interrupted ||
                                task.phase == StitchPhase.paused,
                          ),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(
                      task.phase == StitchPhase.paused ||
                              task.phase == StitchPhase.interrupted
                          ? '恢复'
                          : task.phase == StitchPhase.imported
                          ? '开始合成'
                          : '新建合成任务',
                    ),
                  ),
                if (task.phase != StitchPhase.completed)
                  OutlinedButton.icon(
                    key: const Key('pause-task-action'),
                    onPressed:
                        _busy ||
                            _isActivelyBatchOwned(task) ||
                            task.nativeJobId == null ||
                            !_hasRunningJob
                        ? null
                        : () => _requestPause('已请求暂停；等待核心确认'),
                    icon: const Icon(Icons.pause),
                    label: const Text('暂停'),
                  ),
                if (task.phase != StitchPhase.completed)
                  OutlinedButton.icon(
                    key: const Key('cancel-task-action'),
                    onPressed:
                        _busy ||
                            _isActivelyBatchOwned(task) ||
                            task.nativeJobId == null ||
                            !_hasRunningJob
                        ? null
                        : _cancel,
                    icon: const Icon(Icons.stop),
                    label: const Text('取消'),
                  ),
                if (task.phase != StitchPhase.completed ||
                    task.stage == 'export-failed' ||
                    task.exportPath == null)
                  OutlinedButton.icon(
                    key: const Key('export-task-action'),
                    onPressed:
                        _busy ||
                            _isActivelyBatchOwned(task) ||
                            task.nativeJobId == null ||
                            task.phase != StitchPhase.completed ||
                            (_mobile &&
                                !_android &&
                                !task.exportFormat.supportedOnMobile) ||
                            (task.exportFormat == ExportFormat.jpegXl &&
                                !_jpegXlAvailable)
                        ? null
                        : _export,
                    icon: const Icon(Icons.save_alt),
                    label: Text(
                      '${task.stage == 'export-failed' ? '重试' : '导出'}完整 ${task.exportFormat.shortLabel}',
                    ),
                  ),
                if (task.exportPath != null && (!_mobile || _android))
                  OutlinedButton.icon(
                    key: const Key('open-exported-image'),
                    onPressed: _busy ? null : () => _openExportViewer(task),
                    icon: const Icon(Icons.zoom_in),
                    label: Text(
                      task.phase == StitchPhase.completed
                          ? '打开全景查看器'
                          : '查看上次成功输出',
                    ),
                  ),
                if ((task.phase == StitchPhase.completed || !_editable) &&
                    !_hasRunningJob)
                  TextButton.icon(
                    key: const Key('new-run-copy-action'),
                    onPressed: _busy || _isActivelyBatchOwned(task)
                        ? null
                        : _newRunCopy,
                    icon: const Icon(Icons.copy),
                    label: const Text('新建副本重新合成'),
                  ),
                if (task.phase == StitchPhase.completed)
                  Text(
                    StitchLocalizations.of(
                      context,
                    ).duplicateBeforeEditingSettings,
                  ),
                if (task.phase == StitchPhase.failed)
                  FilledButton.tonalIcon(
                    onPressed: _busy || _isActivelyBatchOwned(task)
                        ? null
                        : _forceGridRetry,
                    icon: const Icon(Icons.grid_on),
                    label: const Text('按手动参数强制网格重试'),
                  ),
              ],
            ),
            if (task.exportPath != null) ...[
              Text(
                '上次成功整图 ${ExportFormat.fromPath(task.exportPath!).shortLabel}：${task.exportPath}',
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _shareExport,
                icon: const Icon(Icons.ios_share),
                label: Text(_mobile ? '分享 / 保存图像' : '在文件夹中显示图像'),
              ),
            ],
          ],
          if (_message != null) ...[
            const SizedBox(height: 8),
            StitchStatusMessage(
              message: _message!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _exportFormatCard(StitchTask? task) {
    final enabled =
        _batchOwnershipReady && !_busy && (task == null || _editable);
    final format = task?.exportFormat ?? _exportFormat;
    return Card(
      key: const Key('export-format-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('整图输出', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            DropdownButtonFormField<ExportFormat>(
              key: const Key('export-format-option'),
              initialValue: format,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: StitchLocalizations.of(
                  context,
                ).text(task == null ? '默认输出格式' : '完成后自动导出格式'),
                helperText: StitchLocalizations.of(
                  context,
                ).text('单任务合成完成后自动导出全分辨率整图。'),
              ),
              items: ExportFormat.values
                  .map(
                    (item) => DropdownMenuItem<ExportFormat>(
                      enabled: item != ExportFormat.jpegXl || _jpegXlAvailable,
                      value: item,
                      child: Text(
                        item == ExportFormat.jpegXl && !_jpegXlAvailable
                            ? 'JPEG XL（编码器未加载）'
                            : item.label,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: enabled ? _updateExportFormat : null,
            ),
          ],
        ),
      ),
    );
  }

  bool _canChooseOutputFormat(StitchTask? task) =>
      task == null ||
      (task.phase == StitchPhase.imported && task.nativeJobId == null);

  bool mappingErrorIsInvalid(StitchTask task) =>
      _mappingError() != null ||
      !task.photos.every(
        (photo) =>
            photo.width == task.photos.first.width &&
            photo.height == task.photos.first.height,
      );

  String _phaseLabel(StitchPhase phase) =>
      StitchLocalizations.of(context).phaseLabel(phase.name);

  String _stageLabel(String stage) => switch (stage) {
    'register' => '图像配准',
    'render-level-0' => '生成全分辨率瓦片',
    'pyramid' => '生成缩放金字塔',
    'manifest' => '写入预览清单',
    'auto-export' => '合成完成，自动导出整图',
    'export' => '导出完整图像',
    'export-failed' => '整图导出失败，可重试',
    'done' => '完成',
    _ => stage,
  };

  String _timelineEventLabel(StitchTimelineEvent event) {
    final l = StitchLocalizations.of(context);
    final subject = event.stage != null
        ? l.timelineStage(event.stage!)
        : event.kind;
    if (event.state != null) {
      final state = event.operation == 'export' && event.state == 'running'
          ? 'exporting'
          : event.state!;
      return l.timelineTransition(subject, l.phaseLabel(state));
    }
    return l.text(switch (event.kind) {
      'started' => '合成已开始',
      'finished' => '合成已完成',
      'export-started' => '整图导出已开始',
      'export-finished' => '整图导出已完成',
      _ => subject,
    });
  }

  String _timelineTotal(StitchTask task) {
    final summary = task.timeline.summary(
      autoExportExpected: task.autoExportOnCompletion,
    );
    final duration = summary.wallClockDuration;
    final l = StitchLocalizations.of(context);
    final started = summary.startedAtUtc == null
        ? l.timelineTimeUnknown
        : _timelineDate(summary.startedAtUtc!);
    final finished = summary.finishedAtUtc == null
        ? (summary.isInProgress ? l.timelineInProgress : l.timelineTimeUnknown)
        : _timelineDate(summary.finishedAtUtc!);
    if (duration == null) {
      return l.timelineBounds(started, finished, l.timelineDurationUnknown);
    }
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    final seconds = duration.inSeconds % 60;
    String two(int value) => value.toString().padLeft(2, '0');
    final elapsed = '${two(hours)}:${two(minutes)}:${two(seconds)}';
    return l.timelineBounds(
      started,
      finished,
      l.timelineTotal(
        elapsed,
        pausedIncluded: task.timeline.events.any((e) => e.state == 'paused'),
      ),
    );
  }

  String _timelineDate(DateTime value) {
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  List<Widget> _performanceStatsLines(Map<String, Object?> stats) {
    final lines = <Widget>[];
    if (stats['exportFormat'] is String) {
      lines.add(Text('整图格式：${stats['exportFormat']}'));
    }
    if (stats['tiffVariant'] is String) {
      lines.add(Text('TIFF 类型：${stats['tiffVariant']}'));
    }
    final phaseTimes = stats['phaseTimesMs'] ?? stats['phaseTimes'];
    if (phaseTimes is Map) {
      const labels = {
        'registration': '配准',
        'registrationMs': '配准',
        'render': '分块渲染',
        'renderMs': '分块渲染',
        'pyramid': '缩放金字塔',
        'pyramidMs': '缩放金字塔',
        'total': '总耗时',
        'totalMs': '总耗时',
        'validationAndHash': '输入校验',
        'validationAndHashMs': '输入校验',
        'sourceDecode': '原片解码',
        'sourceDecodeMs': '原片解码',
        'tileEncode': '瓦片写入',
        'tileEncodeMs': '瓦片写入',
      };
      for (final entry in phaseTimes.entries) {
        final ms = entry.value;
        final label = labels[entry.key];
        if (label != null && ms is num) {
          lines.add(Text('核心计时 · $label：${(ms / 1000).toStringAsFixed(1)} 秒'));
        }
      }
    }
    final renderer = stats['renderer'];
    if (renderer is Map) {
      final workers = renderer['workersEffective'] ?? renderer['workers'];
      if (workers is num) lines.add(Text('实际渲染工作线程：$workers'));
      final cacheHits = renderer['sourceCacheHits'];
      if (cacheHits is num) lines.add(Text('原片纹理缓存命中：$cacheHits'));
    }
    final alignmentStats = stats['alignmentStats'];
    final cacheHit =
        stats['alignmentCacheHit'] ??
        (alignmentStats is Map ? alignmentStats['cached'] : null);
    if (cacheHit == true) {
      lines.add(const Text('配准缓存：命中（沿用已保存的配准结果）'));
    } else if (cacheHit == false) {
      lines.add(const Text('配准缓存：未命中'));
    }
    final alignment = stats['alignment'];
    if (alignment is Map && alignment['qualityStatus'] is String) {
      lines.add(Text('配准质量状态：${alignment['qualityStatus']}'));
    }
    final edgeDiagnostics = alignment is Map
        ? alignment['edgeDiagnostics']
        : null;
    if (edgeDiagnostics is List && edgeDiagnostics.isNotEmpty) {
      var adjustedEdges = 0;
      var ambiguousEdges = 0;
      for (final edge in edgeDiagnostics) {
        if (edge is! Map) continue;
        final weight = edge['reliabilityWeightScale'];
        if (edge['disposition'] == 'accepted' &&
            weight is num &&
            weight < 0.999) {
          adjustedEdges++;
        }
        if (edge['loopConflictAmbiguous'] == true) ambiguousEdges++;
      }
      lines.add(
        Text(
          StitchLocalizations.of(context).neighborReliabilitySummary(
            adjustedEdges: adjustedEdges,
            ambiguousEdges: ambiguousEdges,
          ),
        ),
      );
    }
    final overlapEstimate = alignment is Map
        ? alignment['gridOverlapEstimate']
        : stats['gridOverlapEstimate'];
    if (overlapEstimate is Map) {
      final horizontalStats = overlapEstimate['horizontal'];
      final verticalStats = overlapEstimate['vertical'];
      String? percent(Object? value) {
        if (value is! num || !value.isFinite) return null;
        final normalized = value <= 1 ? value * 100 : value;
        return '${normalized.toStringAsFixed(1)}%';
      }

      final horizontal = percent(
        overlapEstimate['horizontalOverlap'] ??
            (horizontalStats is Map
                ? horizontalStats['overlap'] ??
                      horizontalStats['horizontalOverlap']
                : null),
      );
      final vertical = percent(
        overlapEstimate['verticalOverlap'] ??
            (verticalStats is Map
                ? verticalStats['overlap'] ?? verticalStats['verticalOverlap']
                : null),
      );
      if (horizontal != null && vertical != null) {
        lines.add(Text('中间相邻照片估算重叠：水平 $horizontal · 垂直 $vertical'));
      }
      final horizontalStep =
          overlapEstimate['horizontalStepPixels'] ??
          (horizontalStats is Map ? horizontalStats['stepPixels'] : null);
      final verticalStep =
          overlapEstimate['verticalStepPixels'] ??
          (verticalStats is Map ? verticalStats['stepPixels'] : null);
      if (horizontalStep is num && verticalStep is num) {
        lines.add(
          Text(
            '估算网格步长：水平 ${horizontalStep.abs().round()} px · 垂直 ${verticalStep.abs().round()} px',
          ),
        );
      }
      final pairs = overlapEstimate['pairs'];
      final pairList = pairs is List
          ? pairs
          : [
              if (horizontalStats is Map && horizontalStats['pairs'] is List)
                ...(horizontalStats['pairs'] as List),
              if (verticalStats is Map && verticalStats['pairs'] is List)
                ...(verticalStats['pairs'] as List),
            ];
      final pairCount = pairs is num ? pairs.round() : pairList.length;
      if (pairCount > 0) {
        lines.add(Text('估算证据：$pairCount 组相邻照片配对'));
        final examples = pairList.take(3).map((pair) {
          if (pair is Map) {
            final first =
                pair['first'] ?? pair['source'] ?? pair['a'] ?? pair['left'];
            final second =
                pair['second'] ?? pair['target'] ?? pair['b'] ?? pair['right'];
            if (first != null && second != null) return '$first ↔ $second';
          }
          return pair.toString();
        }).toList();
        if (examples.isNotEmpty) {
          lines.add(Text('样本配对：${examples.join('；')}'));
        }
      }
      final method = overlapEstimate['method'];
      final confidence = overlapEstimate['confidence'];
      final provenance = overlapEstimate['provenance'];
      final details = <String>[
        if (method is String) '方法 $method',
        if (confidence is num) '置信度 ${confidence.toStringAsFixed(2)}',
        if (provenance is String) provenance,
      ];
      lines.add(Text('网格为估算值，尚未校准；${details.join(' · ')}'));
    }
    return lines;
  }

  Widget _emptyCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          const Icon(Icons.panorama_outlined, size: 52),
          const SizedBox(height: 8),
          const Text('原片仅复制到本机任务目录，不上传。'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _importPhotos,
            icon: const Icon(Icons.photo_library),
            label: const Text('选择多张 JPEG 原片'),
          ),
        ],
      ),
    ),
  );

  Widget _optionsCard(StitchTask task, String? error) {
    final enabled = _editable && !_busy;
    final dimensions = task.photos.isEmpty
        ? null
        : '${task.photos.first.width}×${task.photos.first.height}';
    return Card(
      key: const Key('stitch-options-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('排列与相机', style: Theme.of(context).textTheme.titleMedium),
            Text('全部 ${task.photos.length} 张照片保留；尺寸 $dimensions。无法映射时不会丢弃原片。'),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('自动读取文件名行列'),
                  selected: _grid.mode == GridMode.filename,
                  onSelected: enabled
                      ? (_) => _setGrid(_grid.copyWith(mode: GridMode.filename))
                      : null,
                ),
                ChoiceChip(
                  label: const Text('按选择顺序排列'),
                  selected: _grid.mode == GridMode.sequence,
                  onSelected: enabled
                      ? (_) => _setGrid(_grid.copyWith(mode: GridMode.sequence))
                      : null,
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SizedBox(
                  width: 92,
                  child: TextField(
                    controller: _rows,
                    enabled: enabled && _grid.mode == GridMode.sequence,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: StitchLocalizations.of(context).text('行'),
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(
                  width: 92,
                  child: TextField(
                    controller: _columns,
                    enabled: enabled && _grid.mode == GridMode.sequence,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: StitchLocalizations.of(context).text('列'),
                      isDense: true,
                    ),
                  ),
                ),
                DropdownButton<TraversalAxis>(
                  value: _grid.axis,
                  onChanged: enabled && _grid.mode == GridMode.sequence
                      ? (value) => _changeTraversal(axis: value)
                      : null,
                  items: const [
                    DropdownMenuItem(
                      value: TraversalAxis.row,
                      child: Text('逐行拍摄'),
                    ),
                    DropdownMenuItem(
                      value: TraversalAxis.column,
                      child: Text('逐列拍摄'),
                    ),
                  ],
                ),
                DropdownButton<StartCorner>(
                  value: _grid.startCorner,
                  onChanged: enabled && _grid.mode == GridMode.sequence
                      ? (value) => _changeTraversal(corner: value)
                      : null,
                  items: const [
                    DropdownMenuItem(
                      value: StartCorner.topLeft,
                      child: Text('左上起拍'),
                    ),
                    DropdownMenuItem(
                      value: StartCorner.topRight,
                      child: Text('右上起拍'),
                    ),
                    DropdownMenuItem(
                      value: StartCorner.bottomLeft,
                      child: Text('左下起拍'),
                    ),
                    DropdownMenuItem(
                      value: StartCorner.bottomRight,
                      child: Text('右下起拍'),
                    ),
                  ],
                ),
                FilterChip(
                  label: const Text('蛇形'),
                  selected: _grid.serpentine,
                  onSelected: enabled && _grid.mode == GridMode.sequence
                      ? (value) => _changeTraversal(serpentine: value)
                      : null,
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _fov,
                    enabled: enabled,
                    onChanged: (_) => _cameraCalibrationTouched = true,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: StitchLocalizations.of(context).text('水平视角 °'),
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(
                  width: 145,
                  child: TextField(
                    controller: _fx,
                    enabled: enabled,
                    onChanged: (_) => _cameraCalibrationTouched = true,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: StitchLocalizations.of(
                        context,
                      ).text('焦距像素（可选）'),
                      isDense: true,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed:
                      enabled &&
                          task.photos.isNotEmpty &&
                          task.photos.first.width == 3840 &&
                          task.photos.first.height == 2160
                      ? () {
                          final width = task.photos.first.width;
                          const nominalFx = 75000.0;
                          final nominalFov =
                              2 *
                              math.atan(width / (2 * nominalFx)) *
                              180 /
                              math.pi;
                          setState(() {
                            _fx.text = '$nominalFx';
                            _fov.text = nominalFov.toStringAsFixed(4);
                            _cameraCalibrationTouched = true;
                          });
                        }
                      : null,
                  icon: const Icon(Icons.center_focus_strong),
                  label: const Text('DWARF 固定视角（名义值）'),
                ),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _memory,
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: StitchLocalizations.of(
                        context,
                      ).text('渲染内存 MiB'),
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _workers,
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: StitchLocalizations.of(context).text('工作线程数'),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const Text(
              'DWARF 固定视角快捷项使用名义 fx=75000 px，尚未校准；cx/cy 根据照片尺寸计算。',
              style: TextStyle(fontSize: 12),
            ),
            if (task.cameraProfileId == 'dwarf3-tele-nominal-150mm')
              Text(
                '已按照片 EXIF 识别 DWARFLAB / DWARF3 / TELE；使用名义 150 mm 配置 fx=${(75000 * task.photos.first.width / 3840).round()} px（随图像宽度缩放），未校准。实际 EXIF 焦距：${task.photos.first.exifFocalLengthMm?.toStringAsFixed(1) ?? '未记录'} mm。',
                style: const TextStyle(fontSize: 12),
              ),
            SwitchListTile.adaptive(
              key: const Key('force-grid-option'),
              contentPadding: EdgeInsets.zero,
              title: const Text('强制网格合成'),
              subtitle: const Text('自动重叠关闭时，无法可靠匹配的方向才会按焦距/视角和手动重叠率估算网格位置。'),
              value: _forceGridFallback,
              onChanged: enabled && !_autoGridOverlap
                  ? (value) => setState(() => _forceGridFallback = value)
                  : null,
            ),
            CheckboxListTile(
              key: const Key('auto-grid-overlap-option'),
              contentPadding: EdgeInsets.zero,
              title: const Text('从中间照片估算水平/垂直重叠并按网格合成'),
              subtitle: Text(
                _cameraCalibrationTouched ||
                        task.cameraProfileId == 'dwarf3-tele-nominal-150mm'
                    ? '最多检查 24 组中心相邻照片；结果是网格估算值，尚未校准，仍需目视检查接缝。'
                    : '重叠率由照片实测；未知镜头的视角仍需填写。当前视角用于球面投影，默认 45° 不是照片测量值。最多检查 24 组中心相邻照片，结果仍需目视检查接缝。',
              ),
              value: _autoGridOverlap,
              onChanged: enabled
                  ? (value) => _updateAutoGridOverlap(value ?? true)
                  : null,
            ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                SizedBox(
                  width: 145,
                  child: TextField(
                    key: const Key('horizontal-overlap-field'),
                    controller: _horizontalOverlap,
                    enabled: enabled && !_autoGridOverlap,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: StitchLocalizations.of(
                        context,
                      ).text('手动水平重叠率 %'),
                      helperText: StitchLocalizations.of(
                        context,
                      ).text('15–80；自动模式忽略此值，实测结果见报告'),
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(
                  width: 145,
                  child: TextField(
                    key: const Key('vertical-overlap-field'),
                    controller: _verticalOverlap,
                    enabled: enabled && !_autoGridOverlap,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: StitchLocalizations.of(
                        context,
                      ).text('手动垂直重叠率 %'),
                      helperText: StitchLocalizations.of(
                        context,
                      ).text('15–80；自动模式忽略此值，实测结果见报告'),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const Text(
              '渲染内存预算用于缓存和活动图像/瓦片估算；配准阶段 OpenCV 与进程其他内存另计。',
              style: TextStyle(fontSize: 12),
            ),
            if (!_mobile || _android)
              ExpansionTile(
                key: const Key('stitch-quality-expansion'),
                tilePadding: EdgeInsets.zero,
                title: const Text('输出与画质'),
                children: [
                  CheckboxListTile(
                    key: const Key('refine-grid-neighbors-option'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('精细校正相邻照片位置'),
                    subtitle: const Text(
                      '结合四邻照片的可靠匹配校正位置；匹配不可靠时会降低其影响，可能需要更长时间。',
                    ),
                    value: _refineGridNeighbors,
                    onChanged: enabled ? _updateRefineGridNeighbors : null,
                  ),
                  CheckboxListTile(
                    key: const Key('deghost-blending-option'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('抑制接缝重影'),
                    subtitle: const Text(
                      '重叠区域优先采用更清晰的照片来源以减少重影；没有更清晰的邻图时仍会保留原片。关闭可与传统羽化结果对照。',
                    ),
                    value: _seamBlendMode == SeamBlendMode.deghost,
                    onChanged: enabled
                        ? (value) => _updateSeamBlendMode(
                            value == true
                                ? SeamBlendMode.deghost
                                : SeamBlendMode.feather,
                          )
                        : null,
                  ),
                  CheckboxListTile(
                    key: const Key('local-texture-warp-option'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('局部纹理校正'),
                    secondary: const Tooltip(
                      message: '在相邻重叠区域限制局部变形，减少纹理错位',
                      child: Icon(Icons.info_outline),
                    ),
                    value: _localTextureWarp,
                    onChanged: enabled ? _updateLocalTextureWarp : null,
                  ),
                ],
              ),
            Text('提速测试选项', style: Theme.of(context).textTheme.titleMedium),
            const Text(
              '选项会随任务保存；正在处理或等待恢复的任务使用已提交参数。最终整图仍使用全部原片和完整分辨率。',
              style: TextStyle(fontSize: 12),
            ),
            CheckboxListTile(
              key: const Key('parallel-matching-option'),
              contentPadding: EdgeInsets.zero,
              title: const Text('并行图像匹配'),
              subtitle: _autoGridOverlap && _refineGridNeighbors
                  ? const Text('中心照片提供水平/垂直估算；启用精细校正后，此项用于四邻照片配准。')
                  : _autoGridOverlap
                  ? const Text('自动网格只估算中心相邻照片；启用精细校正后可并行四邻照片配准。')
                  : null,
              value: _performanceOptions.parallelMatching,
              onChanged: enabled && (!_autoGridOverlap || _refineGridNeighbors)
                  ? (value) => _updatePerformanceOptions(
                      _performanceOptions.copyWith(parallelMatching: value),
                    )
                  : null,
            ),
            CheckboxListTile(
              key: const Key('parallel-rendering-option'),
              contentPadding: EdgeInsets.zero,
              title: const Text('并行分块渲染'),
              value: _performanceOptions.parallelRendering,
              onChanged: enabled
                  ? (value) => _updatePerformanceOptions(
                      _performanceOptions.copyWith(parallelRendering: value),
                    )
                  : null,
            ),
            CheckboxListTile(
              key: const Key('source-cache-option'),
              contentPadding: EdgeInsets.zero,
              title: const Text('启用原片纹理缓存'),
              value: _performanceOptions.useSourceCache,
              onChanged: enabled
                  ? (value) => _updatePerformanceOptions(
                      _performanceOptions.copyWith(useSourceCache: value),
                    )
                  : null,
            ),
            CheckboxListTile(
              key: const Key('alignment-cache-option'),
              contentPadding: EdgeInsets.zero,
              title: const Text('缓存图像配准结果'),
              subtitle: const Text('缓存保存在任务输入目录旁的应用任务目录中。'),
              value: _performanceOptions.useAlignmentCache,
              onChanged: enabled
                  ? (value) => _updatePerformanceOptions(
                      _performanceOptions.copyWith(useAlignmentCache: value),
                    )
                  : null,
            ),
            CheckboxListTile(
              key: const Key('four-neighbor-option'),
              contentPadding: EdgeInsets.zero,
              title: const Text('优先尝试四邻方向（自适应）'),
              subtitle: _refineGridNeighbors
                  ? const Text('精细校正会固定检查四个方向的相邻照片；关闭精细校正后可恢复此项设置。')
                  : _autoGridOverlap
                  ? const Text('自动网格使用固定的中心相邻照片估算；此项在自动模式下暂停使用。')
                  : null,
              value: _performanceOptions.fourNeighborFirst,
              onChanged: enabled && !_autoGridOverlap && !_refineGridNeighbors
                  ? (value) => _updatePerformanceOptions(
                      _performanceOptions.copyWith(fourNeighborFirst: value),
                    )
                  : null,
            ),
            CheckboxListTile(
              key: const Key('fast-registration-option'),
              contentPadding: EdgeInsets.zero,
              title: const Text('快速配准'),
              subtitle: const Text('使用 0.6 MP 配准图；关闭时使用 2.0 MP。最终渲染仍为全分辨率。'),
              value: _performanceOptions.fastRegistration,
              onChanged: enabled
                  ? (value) => _updatePerformanceOptions(
                      _performanceOptions.copyWith(fastRegistration: value),
                    )
                  : null,
            ),
            CheckboxListTile(
              key: const Key('orb-features-option'),
              contentPadding: EdgeInsets.zero,
              title: const Text('ORB 快速特征'),
              subtitle: Text(
                _autoGridOverlap && _refineGridNeighbors
                    ? '中心重叠估算固定使用 SIFT/BF；此项用于启用中的四邻照片配准。'
                    : _autoGridOverlap
                    ? '自动网格估算固定使用 SIFT/BF；启用精细校正后可测试四邻照片配准。'
                    : _performanceOptions.orbFeatures
                    ? 'ORB 使用 BF 匹配；FLANN 已关闭。'
                    : '默认使用 SIFT 特征。',
              ),
              value: _performanceOptions.orbFeatures,
              onChanged: enabled && (!_autoGridOverlap || _refineGridNeighbors)
                  ? (value) => _updatePerformanceOptions(
                      _performanceOptions.copyWith(
                        orbFeatures: value,
                        flannMatching: value == true
                            ? false
                            : _performanceOptions.flannMatching,
                      ),
                    )
                  : null,
            ),
            CheckboxListTile(
              key: const Key('flann-matching-option'),
              contentPadding: EdgeInsets.zero,
              title: const Text('FLANN 近似匹配'),
              subtitle: Text(
                _autoGridOverlap && _refineGridNeighbors
                    ? '中心重叠估算固定使用 SIFT/BF；此项用于启用中的四邻照片配准。'
                    : _autoGridOverlap
                    ? '自动网格估算固定使用 SIFT/BF；启用精细校正后可测试四邻配准。'
                    : _performanceOptions.orbFeatures
                    ? 'ORB 模式不可用；请先切回 SIFT。'
                    : '默认使用 BF 精确匹配。',
              ),
              value: _performanceOptions.effectiveFlannMatching,
              onChanged:
                  enabled &&
                      (!_autoGridOverlap || _refineGridNeighbors) &&
                      !_performanceOptions.orbFeatures
                  ? (value) => _updatePerformanceOptions(
                      _performanceOptions.copyWith(flannMatching: value),
                    )
                  : null,
            ),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('GPU 加速'),
              subtitle: Text('当前 CPU 原生包未提供 GPU 后端。'),
              trailing: Checkbox(value: false, onChanged: null),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error,
                  style: const TextStyle(color: Colors.deepOrange),
                ),
              ),
            if (enabled)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _saveOptions,
                  icon: const Icon(Icons.check),
                  label: const Text('保存任务设置'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _updatePerformanceOptions(PerformanceOptions options) {
    final task = _task;
    if (task == null) {
      setState(() => _performanceOptions = options);
      return;
    }
    if (!_editable) return;
    final normalizedOptions = options.normalized;
    final updated = task.copyWith(performanceOptions: normalizedOptions);
    setState(() {
      _performanceOptions = normalizedOptions;
      _task = updated;
      final index = _tasks.indexWhere((item) => item.id == updated.id);
      if (index < 0) {
        _tasks = [updated, ..._tasks];
      } else {
        final next = [..._tasks];
        next[index] = updated;
        _tasks = next;
      }
      _message = null;
    });
    unawaited(_enqueueTaskSave(updated));
  }

  void _updateAutoGridOverlap(bool value) {
    final task = _task;
    if (task != null && !_editable) return;
    setState(() => _autoGridOverlap = value);
    if (task == null) return;
    final updated = task.copyWith(autoGridOverlap: value);
    setState(() {
      _task = updated;
      final index = _tasks.indexWhere((item) => item.id == updated.id);
      if (index < 0) {
        _tasks = [updated, ..._tasks];
      } else {
        final next = [..._tasks];
        next[index] = updated;
        _tasks = next;
      }
      _message = null;
    });
    unawaited(_enqueueTaskSave(updated));
  }

  void _updateExportFormat(ExportFormat? value) {
    if (value == null || !_editable) return;
    if (value == ExportFormat.jpegXl && !_jpegXlAvailable) return;
    final task = _task;
    setState(() => _exportFormat = value);
    if (task != null) _persistQuality(task.copyWith(exportFormat: value));
  }

  void _updateRefineGridNeighbors(bool? value) {
    if (value == null || !_editable) return;
    final task = _task;
    setState(() => _refineGridNeighbors = value);
    if (task != null) {
      _persistQuality(task.copyWith(refineGridNeighbors: value));
    }
  }

  void _updateSeamBlendMode(SeamBlendMode mode) {
    if (!_editable) return;
    final task = _task;
    setState(() => _seamBlendMode = mode);
    if (task != null) _persistQuality(task.copyWith(seamBlendMode: mode));
  }

  void _updateLocalTextureWarp(bool? value) {
    if (value == null || !_editable) return;
    final task = _task;
    setState(() => _localTextureWarp = value);
    if (task != null) {
      _persistQuality(task.copyWith(localTextureWarp: value));
    }
  }

  void _persistQuality(StitchTask updated) {
    setState(() {
      _task = updated;
      final index = _tasks.indexWhere((item) => item.id == updated.id);
      if (index >= 0) {
        final next = [..._tasks];
        next[index] = updated;
        _tasks = next;
      }
    });
    unawaited(_enqueueTaskSave(updated));
  }

  void _changeTraversal({
    TraversalAxis? axis,
    StartCorner? corner,
    bool? serpentine,
  }) {
    _setGrid(
      _grid.copyWith(axis: axis, startCorner: corner, serpentine: serpentine),
      resize: false,
    );
  }

  Widget _photoGrid(StitchTask task, String? error) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '照片与网格映射（${_mappingCells.length}/${task.photos.length}）',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text('照片不可从网格移除；点按照片切换“强制按网格放置”。完整文件名可长按查看。'),
            if (error != null)
              Text(error, style: const TextStyle(color: Colors.deepOrange)),
            if (_mappingCells.isEmpty)
              const Text('修正排列方式后查看网格预览。')
            else
              LayoutBuilder(
                builder: (context, box) {
                  final columns =
                      _grid.mode == GridMode.filename && error == null
                      ? GridMapping.fromFilenames(task.photos).columns
                      : _grid.columns;
                  final rows = (task.photos.length / columns).ceil();
                  final minimumCellWidth = box.maxWidth >= 800 ? 28.0 : 72.0;
                  final cellWidth = math.max(
                    minimumCellWidth,
                    math.min(160.0, box.maxWidth / columns),
                  );
                  final gridWidth = cellWidth * columns;
                  final cellHeight = cellWidth * 10 / 16;
                  final byCell = <GridCell, int>{
                    for (var i = 0; i < _mappingCells.length; i++)
                      _mappingCells[i]: i,
                  };
                  final viewportHeight = math.min(rows * cellHeight, 520.0);
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: gridWidth,
                      height: viewportHeight,
                      child: GridView.builder(
                        shrinkWrap: false,
                        physics: const ClampingScrollPhysics(),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 4,
                          mainAxisSpacing: 4,
                          childAspectRatio: 16 / 10,
                        ),
                        itemCount: _mappingCells.length,
                        itemBuilder: (context, index) {
                          final cell = GridCell(
                            index ~/ columns,
                            index % columns,
                          );
                          final photo = task.photos[byCell[cell]!];
                          final forced = task.grid.forceGridCells.contains(
                            cell,
                          );
                          final label =
                              '${photo.originalName} · ${cell.row + 1},${cell.column + 1}';
                          return Tooltip(
                            message: '$label${forced ? ' · 强制按网格放置' : ''}',
                            child: InkWell(
                              onTap: _editable
                                  ? () async {
                                      final updated = task.copyWith(
                                        grid: task.grid.toggleForced(cell),
                                      );
                                      await _persist(updated);
                                      _setGrid(updated.grid);
                                    }
                                  : null,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Container(
                                    color: Colors.black12,
                                    alignment: Alignment.center,
                                    child: Image.file(
                                      File(photo.storedPath),
                                      fit: BoxFit.contain,
                                      cacheWidth: 256,
                                      errorBuilder: (_, _, _) =>
                                          const Icon(Icons.broken_image),
                                    ),
                                  ),
                                  Positioned(
                                    left: 2,
                                    bottom: 2,
                                    child: Container(
                                      color: Colors.black54,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 3,
                                      ),
                                      child: Text(
                                        '${cell.row + 1},${cell.column + 1}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 9,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (forced)
                                    Positioned.fill(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: Colors.amber,
                                            width: 3,
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (forced)
                                    const Positioned(
                                      right: 2,
                                      top: 2,
                                      child: Icon(
                                        Icons.push_pin,
                                        color: Colors.amber,
                                        size: 16,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _tilePyramid(StitchTask task) {
    final levels = _manifest?['levels'];
    if (levels is! List || levels.isEmpty) {
      return const Card(child: ListTile(title: Text('金字塔中暂无瓦片')));
    }
    final available = levels.cast<Map<String, Object?>>();
    final viewportWidth = MediaQuery.sizeOf(context).width;
    const viewportHeight = 520.0;
    final chosen = _chooseTileLevel(
      available,
      viewportWidth,
      viewportHeight,
      _viewerScale,
    );
    final level = _viewerLevel == null
        ? chosen
        : available.firstWhere(
            (item) => item['level'] == _viewerLevel,
            orElse: () => chosen,
          );
    final occupied = (level['occupied'] as List<Object?>? ?? const [])
        .cast<Map<String, Object?>>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '分块全景 · ${level['width']}×${level['height']} · level ${level['level']}',
            ),
            InteractiveViewer(
              transformationController: _tileTransform,
              onInteractionUpdate: (_) =>
                  _syncTileLevel(available, viewportWidth, viewportHeight),
              minScale: .25,
              maxScale: 8,
              constrained: false,
              child: SizedBox(
                width: (level['width'] as int).toDouble(),
                height: (level['height'] as int).toDouble(),
                child: Stack(
                  children: [
                    for (final tile in occupied)
                      Positioned(
                        left: (tile['column'] as int) * 512.0,
                        top: (tile['row'] as int) * 512.0,
                        child: Image.file(
                          File(
                            p.join(
                              task.outputDirectory,
                              tile['path'] as String,
                            ),
                          ),
                          width: (tile['width'] as int? ?? 512).toDouble(),
                          height: (tile['height'] as int? ?? 512).toDouble(),
                          fit: BoxFit.fill,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.broken_image),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Text(
              StitchLocalizations.of(
                context,
              ).fullResolutionOutputUsesTaskFormat,
            ),
          ],
        ),
      ),
    );
  }

  Map<String, Object?> _chooseTileLevel(
    List<Map<String, Object?>> levels,
    double width,
    double height,
    double scale,
  ) {
    final targetWidth = width * scale, targetHeight = height * scale;
    final matching =
        levels
            .where(
              (item) =>
                  (item['width'] as int) <= targetWidth &&
                  (item['height'] as int) <= targetHeight,
            )
            .toList()
          ..sort(
            (a, b) => ((b['width'] as int) * (b['height'] as int)).compareTo(
              (a['width'] as int) * (a['height'] as int),
            ),
          );
    if (matching.isNotEmpty) return matching.first;
    final coarse = [...levels]
      ..sort(
        (a, b) => ((a['width'] as int) * (a['height'] as int)).compareTo(
          (b['width'] as int) * (b['height'] as int),
        ),
      );
    return coarse.first;
  }

  void _syncTileLevel(
    List<Map<String, Object?>> levels,
    double width,
    double height,
  ) {
    final scale = _tileTransform.value.getMaxScaleOnAxis();
    _viewerScale = scale;
    final level =
        _chooseTileLevel(levels, width, height, scale)['level'] as int;
    if (level != _viewerLevel) setState(() => _viewerLevel = level);
  }
}
