import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/main.dart';
import 'package:stitch_app/models/app_settings.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/memory_budget_policy.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/services/settings_controller.dart';
import 'package:stitch_app/services/settings_repository.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'support/empty_batch_queue_controller.dart';

const _gib = 1024;

class _MemorySettingsRepository extends SettingsRepository {
  _MemorySettingsRepository() : super();

  AppSettings value = const AppSettings();

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async {
    value = settings;
  }
}

class _ResourceApi implements JobApi {
  _ResourceApi({
    this.reservedMemoryMiB = 0,
    this.nativeConcurrentJobs = 2,
    this.activeJobsOverride,
    this.configureGate,
    this.laterConfigureGate,
  });

  int reservedMemoryMiB;
  final int nativeConcurrentJobs;
  final int? activeJobsOverride;
  final Completer<void>? configureGate;
  final Completer<void>? laterConfigureGate;
  final Completer<void> configureEntered = Completer<void>();
  final Completer<void> laterConfigureEntered = Completer<void>();
  final List<(int memory, int jobs, int cpu)> configurations = [];
  final List<int> startedBudgets = [];
  int configureCalls = 0;
  int resumes = 0;
  int exports = 0;
  final Map<String, String> states = {};

  @override
  bool get isAvailable => true;
  @override
  String? get unavailableReason => null;

  @override
  Future<Map<String, Object?>> capabilities() async => {
    'ok': true,
    'capabilities': {
      // Windows native capability shape: memory contains only memory fields.
      'systemMemory': {
        'totalMemoryMiB': 128 * _gib,
        'availableMemoryMiB': 64 * _gib,
      },
      'logicalCpuCount': 12,
      'totalCpuWorkers': 12,
      'maxConcurrentJobs': nativeConcurrentJobs,
      'maxConcurrentJobsLimit': 8,
      'maxWorkersPerJob': 32,
      'reservedMemoryMiB': reservedMemoryMiB,
      'reservedWorkers': 0,
      'activeJobs': activeJobsOverride ?? (reservedMemoryMiB == 0 ? 0 : 1),
      'jpegXlAvailable': true,
      'exportFormats': {'png': true, 'tiff': true, 'jxl': true},
    },
  };

  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) async {
    final call = configureCalls++;
    if (!configureEntered.isCompleted) configureEntered.complete();
    if (call == 0) await configureGate?.future;
    if (call == 1 && laterConfigureGate != null) {
      if (!laterConfigureEntered.isCompleted) laterConfigureEntered.complete();
      await laterConfigureGate!.future;
    }
    configurations.add((
      totalMemoryBudgetMiB,
      maxConcurrentJobs,
      totalCpuWorkers,
    ));
    return capabilities();
  }

  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async {
    startedBudgets.add(memoryBudgetMiB);
    states[outputDirectory] = 'running';
    reservedMemoryMiB += memoryBudgetMiB;
    return {
      'ok': true,
      'jobId': outputDirectory,
      'state': 'running',
      'operation': 'render',
    };
  }

  @override
  Future<Map<String, Object?>> status(String jobId) async => {
    'ok': true,
    'jobId': jobId,
    'state': states[jobId] ?? 'paused',
    'operation': 'render',
    'stage': 'register',
    'progress': 0.1,
    'workersEffective': 4,
    'operationWorkers': 4,
    'memoryBudgetMiB': 16 * _gib,
    'events': const [],
  };

  @override
  Future<Map<String, Object?>> pause(String jobId) async => {
    'ok': true,
    'jobId': jobId,
    'state': 'paused',
  };

  @override
  Future<Map<String, Object?>> resume(String jobId) async {
    resumes++;
    states[jobId] = 'running';
    return {'ok': true, 'jobId': jobId, 'state': 'running'};
  }

  @override
  Future<Map<String, Object?>> cancel(String jobId) async => {
    'ok': true,
    'jobId': jobId,
    'state': 'cancelled',
  };

  @override
  Future<Map<String, Object?>> export(String jobId, String destination) async {
    exports++;
    return {
      'ok': true,
      'jobId': jobId,
      'state': 'completed',
      'operation': 'export',
      'exportDestination': destination,
    };
  }
}

class _Repository extends TaskRepository {
  _Repository(this.rootPath, this.values);

  final String rootPath;
  final List<StitchTask> values;
  final List<StitchTask> saved = [];

  @override
  Future<List<StitchTask>> loadAll() async => [...values];

  @override
  Future<StitchTask?> loadById(String id) async =>
      [...saved, ...values].lastWhere((task) => task.id == id);

  @override
  Future<void> save(StitchTask task) async {
    saved.add(task);
    final index = values.indexWhere((value) => value.id == task.id);
    if (index >= 0) values[index] = task;
  }

  @override
  Future<Directory> directoryFor(String id) async => Directory('$rootPath/$id');
}

class _NoopLock implements ForegroundWorkLock {
  @override
  Future<void> enable() async {}
  @override
  Future<void> disable() async {}
}

class _ExternalPower implements PowerGate {
  @override
  Future<PowerState> readState() async => PowerState.externalPower;
}

StitchTask _task(
  String outputPath, {
  StitchPhase phase = StitchPhase.imported,
}) => StitchTask(
  id: '019b1234-5678-7abc-8def-0123456789ab',
  createdAt: DateTime.utc(2026, 10, 6),
  sourceDirectory: File(outputPath).parent.path,
  outputDirectory: outputPath,
  photos: const [
    ImportedPhoto(
      originalName: 'tile.jpg',
      storedPath: 'missing-source.jpg',
      sha256: 'fixture',
      width: 3840,
      height: 2160,
      originalOrder: 0,
    ),
  ],
  grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
  horizontalFovDegrees: 45,
  memoryBudgetMiB: 16 * _gib,
  workers: 4,
  phase: phase,
  nativeJobId: phase == StitchPhase.paused ? 'saved-job' : null,
  exportFormat: ExportFormat.tiff,
);

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
  String reason,
) async {
  final deadline = Stopwatch()..start();
  while (!condition() && deadline.elapsed < const Duration(seconds: 5)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  final visibleTexts = tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data)
      .whereType<String>()
      .toList(growable: false);
  expect(
    condition(),
    isTrue,
    reason: '$reason Visible UI text: ${visibleTexts.join(' | ')}',
  );
}

Future<void> _waitForEnabledStart(
  WidgetTester tester, {
  String label = '开始合成',
}) async {
  final button = find.widgetWithText(FilledButton, label);
  await _pumpUntil(
    tester,
    () =>
        button.evaluate().isNotEmpty &&
        tester.widget<FilledButton>(button).onPressed != null,
    'Direct-start button did not become enabled.',
  );
}

void main() {
  test('large desktop memory readings and job allocations remain shared', () {
    final windowsReading = MemoryResourceReading.fromMap({
      'totalMemoryMiB': 128 * _gib,
      'availableMemoryMiB': 64 * _gib,
    }, source: 'native-system');
    expect(windowsReading.valid, isTrue);
    expect(windowsReading.totalMemoryMiB, 128 * _gib);

    final automatic = MemoryBudgetPolicy.evaluate(
      const AppSettings(),
      windowsReading,
      mobile: false,
    );
    expect(automatic.selectedMiB, 48 * _gib);
    expect(MemoryBudgetPolicy.allocatedJobBudgetMiB(32 * _gib, 2), 16 * _gib);
    expect(
      MemoryBudgetPolicy.allocatedJobBudgetMiB(128 * _gib, 99),
      16 * _gib,
      reason:
          'Per-job allocation must divide the shared budget over at most eight slots.',
    );
  });

  testWidgets(
    'desktop capabilities configure high shared budgets and direct jobs above 4GiB',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'memory-resource-direct-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final api = _ResourceApi(nativeConcurrentJobs: 2);
      final task = _task('${temp.path}/render');
      final repository = _Repository(temp.path, [task]);
      final batch = EmptyBatchQueueController(
        api: api,
        taskRepository: repository,
      );
      final settings = SettingsController(
        repository: _MemorySettingsRepository(),
        initial: const AppSettings(
          memoryBudgetMode: MemoryBudgetMode.manual,
          totalMemoryBudgetMiB: 64 * _gib,
        ),
      );
      await tester.pumpWidget(
        LumiaStitchApp(
          locale: const Locale('zh'),
          settingsController: settings,
          home: StitchHomePage(
            settingsController: settings,
            jobApi: api,
            repository: repository,
            batchQueueController: batch,
            powerGate: _ExternalPower(),
            foregroundWorkLock: _NoopLock(),
            initialTask: task,
            mobileOverride: false,
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => api.configurations.isNotEmpty,
        'Desktop resource sync did not configure the core.',
      );

      expect(api.configurations.last, (48 * _gib, 2, 12));
      expect(batch.newTaskMemoryBudgetMiB, 24 * _gib);
      expect(api.startedBudgets, isEmpty);
      final start = find.text('开始合成');
      await _waitForEnabledStart(tester);
      await tester.ensureVisible(start);
      await tester.tap(start);
      await _pumpUntil(
        tester,
        () => api.startedBudgets.isNotEmpty,
        'Direct render did not start.',
      );
      expect(api.startedBudgets.single, 16 * _gib);
      expect(repository.saved.last.memoryBudgetMiB, 16 * _gib);

      await tester.pumpWidget(const SizedBox.shrink());
      batch.dispose();
      settings.dispose();
    },
  );

  testWidgets(
    'direct start observes a lowered desired slot cap despite stale native eight-slot configuration',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'memory-resource-stale-slots-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final api = _ResourceApi(
        nativeConcurrentJobs: 8,
        activeJobsOverride: 3,
        reservedMemoryMiB: 384,
      );
      final task = _task('${temp.path}/render');
      final repository = _Repository(temp.path, [task]);
      final batch = EmptyBatchQueueController(
        api: api,
        taskRepository: repository,
      );
      final settings = SettingsController(
        repository: _MemorySettingsRepository(),
        initial: const AppSettings(
          memoryBudgetMode: MemoryBudgetMode.manual,
          totalMemoryBudgetMiB: 512,
        ),
      );
      await tester.pumpWidget(
        LumiaStitchApp(
          locale: const Locale('en'),
          settingsController: settings,
          home: StitchHomePage(
            settingsController: settings,
            jobApi: api,
            repository: repository,
            batchQueueController: batch,
            powerGate: _ExternalPower(),
            foregroundWorkLock: _NoopLock(),
            initialTask: task,
            mobileOverride: false,
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => api.configurations.isNotEmpty,
        'A manual 512 MiB budget did not configure the desktop core.',
      );
      expect(api.configurations.last.$2, 1);

      final start = find.text('Start stitching');
      await _waitForEnabledStart(tester, label: 'Start stitching');
      if (start.evaluate().isEmpty) {
        final localizedStart = find.text('开始合成');
        await tester.ensureVisible(localizedStart);
        await tester.tap(localizedStart);
      } else {
        await tester.ensureVisible(start);
        await tester.tap(start);
      }
      await _pumpUntil(
        tester,
        () =>
            find.textContaining('concurrency limit is 1').evaluate().isNotEmpty,
        'Direct-start admission did not report the lowered slot cap.',
      );
      expect(api.startedBudgets, isEmpty);
      expect(find.textContaining('concurrency limit is 1'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      batch.dispose();
      settings.dispose();
    },
  );

  testWidgets(
    'oversized capability slot hints still clamp the global pool to eight',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'memory-resource-slots-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final api = _ResourceApi(nativeConcurrentJobs: 32);
      final repository = _Repository(temp.path, []);
      final batch = EmptyBatchQueueController(
        api: api,
        taskRepository: repository,
      );
      final settings = SettingsController(
        repository: _MemorySettingsRepository(),
        initial: const AppSettings(),
      );
      await tester.pumpWidget(
        LumiaStitchApp(
          locale: const Locale('zh'),
          settingsController: settings,
          home: StitchHomePage(
            settingsController: settings,
            jobApi: api,
            repository: repository,
            batchQueueController: batch,
            powerGate: _ExternalPower(),
            foregroundWorkLock: _NoopLock(),
            mobileOverride: false,
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => api.configurations.isNotEmpty,
        'Desktop resource sync did not configure the core.',
      );
      expect(api.configurations.last, (48 * _gib, 8, 12));
      expect(batch.newTaskMemoryBudgetMiB, 6 * _gib);

      await tester.pumpWidget(const SizedBox.shrink());
      batch.dispose();
      settings.dispose();
    },
  );

  testWidgets(
    'latest settings update configures last and a lowered cap blocks another direct job',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'memory-resource-latest-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final releaseConfigure = Completer<void>();
      final releaseLatestConfigure = Completer<void>();
      final api = _ResourceApi(
        reservedMemoryMiB: 16 * _gib,
        nativeConcurrentJobs: 2,
        configureGate: releaseConfigure,
        laterConfigureGate: releaseLatestConfigure,
      );
      final task = _task('${temp.path}/render');
      final repository = _Repository(temp.path, [task]);
      final batch = EmptyBatchQueueController(
        api: api,
        taskRepository: repository,
      );
      final settings = SettingsController(
        repository: _MemorySettingsRepository(),
        initial: const AppSettings(
          memoryBudgetMode: MemoryBudgetMode.manual,
          totalMemoryBudgetMiB: 32 * _gib,
        ),
      );
      await tester.pumpWidget(
        LumiaStitchApp(
          locale: const Locale('zh'),
          settingsController: settings,
          home: StitchHomePage(
            settingsController: settings,
            jobApi: api,
            repository: repository,
            batchQueueController: batch,
            powerGate: _ExternalPower(),
            foregroundWorkLock: _NoopLock(),
            initialTask: task,
            mobileOverride: false,
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => api.configureEntered.isCompleted,
        'Initial resource configuration did not start.',
      );
      await tester.runAsync(
        () => settings.update(
          const AppSettings(
            memoryBudgetMode: MemoryBudgetMode.manual,
            totalMemoryBudgetMiB: 16 * _gib,
          ),
        ),
      );
      releaseConfigure.complete();
      await _pumpUntil(
        tester,
        () => api.laterConfigureEntered.isCompleted,
        'Latest settings did not enter resource configuration.',
      );

      final start = find.text('开始合成');
      await _waitForEnabledStart(tester);
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pump();
      expect(
        api.startedBudgets,
        isEmpty,
        reason:
            'A direct start must wait for the latest resource configuration.',
      );

      releaseLatestConfigure.complete();
      await _pumpUntil(
        tester,
        () => api.configurations.length >= 2,
        'Latest resource settings were not applied after the in-flight update.',
      );
      await _pumpUntil(
        tester,
        () => find.textContaining('当前共享预算').evaluate().isNotEmpty,
        'Direct-start admission did not report the lowered shared budget.',
      );
      expect(api.configurations.last, (16 * _gib, 2, 12));
      expect(batch.desiredMemoryBudgetMiB, 16 * _gib);

      // The currently reserved 16GiB remains valid, but adding another 16GiB
      // task would exceed the new shared 16GiB application cap.
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pump();
      expect(api.startedBudgets, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      batch.dispose();
      settings.dispose();
    },
  );

  testWidgets(
    'resume waits for enough shared budget and retains its saved reservation',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'memory-resource-resume-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final api = _ResourceApi(nativeConcurrentJobs: 2);
      final task = _task('${temp.path}/render', phase: StitchPhase.paused);
      final repository = _Repository(temp.path, [task]);
      final batch = EmptyBatchQueueController(
        api: api,
        taskRepository: repository,
      );
      final settings = SettingsController(
        repository: _MemorySettingsRepository(),
        initial: const AppSettings(
          memoryBudgetMode: MemoryBudgetMode.manual,
          totalMemoryBudgetMiB: 512,
        ),
      );
      await tester.pumpWidget(
        LumiaStitchApp(
          locale: const Locale('zh'),
          settingsController: settings,
          home: StitchHomePage(
            settingsController: settings,
            jobApi: api,
            repository: repository,
            batchQueueController: batch,
            powerGate: _ExternalPower(),
            foregroundWorkLock: _NoopLock(),
            initialTask: task,
            mobileOverride: false,
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => api.configurations.isNotEmpty,
        'Desktop resource sync did not configure the core.',
      );
      final resume = find.text('恢复');
      await tester.ensureVisible(resume);
      await tester.tap(resume);
      await tester.pump();
      expect(
        api.resumes,
        0,
        reason: 'A 16GiB checkpoint must not resume inside a 512MiB app cap.',
      );

      await tester.runAsync(
        () => settings.update(
          const AppSettings(
            memoryBudgetMode: MemoryBudgetMode.manual,
            totalMemoryBudgetMiB: 32 * _gib,
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () =>
            api.configurations.isNotEmpty &&
            api.configurations.last.$1 == 32 * _gib,
        'Raised app cap was not synchronized before resuming the saved task.',
      );
      await tester.ensureVisible(resume);
      await tester.tap(resume);
      await _pumpUntil(
        tester,
        () => api.resumes == 1,
        'Saved native job did not resume.',
      );
      expect(repository.saved.last.memoryBudgetMiB, 16 * _gib);
      expect(api.startedBudgets, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      batch.dispose();
      settings.dispose();
    },
  );

  testWidgets('manual export obeys the current shared memory cap', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('memory-resource-export-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final api = _ResourceApi();
    final task = _task(
      '${temp.path}/render',
      phase: StitchPhase.completed,
    ).copyWith(nativeJobId: 'saved-job');
    final repository = _Repository(temp.path, [task]);
    final batch = EmptyBatchQueueController(
      api: api,
      taskRepository: repository,
    );
    final settings = SettingsController(
      repository: _MemorySettingsRepository(),
      initial: const AppSettings(
        memoryBudgetMode: MemoryBudgetMode.manual,
        totalMemoryBudgetMiB: 512,
      ),
    );
    await tester.pumpWidget(
      LumiaStitchApp(
        locale: const Locale('zh'),
        settingsController: settings,
        home: StitchHomePage(
          settingsController: settings,
          jobApi: api,
          repository: repository,
          batchQueueController: batch,
          powerGate: _ExternalPower(),
          foregroundWorkLock: _NoopLock(),
          initialTask: task,
          mobileOverride: false,
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () => api.configurations.isNotEmpty,
      'Desktop resource sync did not configure the core.',
    );
    final export = find.byKey(const Key('export-task-action'));
    await tester.ensureVisible(export);
    await tester.tap(export);
    await tester.pump();
    expect(
      api.exports,
      0,
      reason: 'A 16GiB export must not start under a 512MiB shared app cap.',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    batch.dispose();
    settings.dispose();
  });

  testWidgets('repeated direct-start taps during resource sync start one job', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('memory-resource-double-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final releaseConfigure = Completer<void>();
    final api = _ResourceApi(configureGate: releaseConfigure);
    final task = _task('${temp.path}/render');
    final repository = _Repository(temp.path, [task]);
    final batch = EmptyBatchQueueController(
      api: api,
      taskRepository: repository,
    );
    final settings = SettingsController(
      repository: _MemorySettingsRepository(),
      initial: const AppSettings(),
    );
    await tester.pumpWidget(
      LumiaStitchApp(
        locale: const Locale('zh'),
        settingsController: settings,
        home: StitchHomePage(
          settingsController: settings,
          jobApi: api,
          repository: repository,
          batchQueueController: batch,
          powerGate: _ExternalPower(),
          foregroundWorkLock: _NoopLock(),
          initialTask: task,
          mobileOverride: false,
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () => api.configureEntered.isCompleted,
      'Initial resource configuration did not start.',
    );
    final start = find.text('开始合成');
    await _waitForEnabledStart(tester);
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.tap(start);
    await tester.pump();
    releaseConfigure.complete();
    await _pumpUntil(
      tester,
      () => api.startedBudgets.isNotEmpty,
      'Direct render did not start after resource synchronization.',
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.startedBudgets, hasLength(1));

    await tester.pumpWidget(const SizedBox.shrink());
    batch.dispose();
    settings.dispose();
  });

  testWidgets('disposing during direct-start preflight prevents native start', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync(
      'memory-resource-dispose-start-',
    );
    addTearDown(() => temp.deleteSync(recursive: true));
    final releaseConfigure = Completer<void>();
    final api = _ResourceApi(configureGate: releaseConfigure);
    final task = _task('${temp.path}/render');
    final repository = _Repository(temp.path, [task]);
    final batch = EmptyBatchQueueController(
      api: api,
      taskRepository: repository,
    );
    final settings = SettingsController(
      repository: _MemorySettingsRepository(),
      initial: const AppSettings(),
    );
    await tester.pumpWidget(
      LumiaStitchApp(
        locale: const Locale('zh'),
        settingsController: settings,
        home: StitchHomePage(
          settingsController: settings,
          jobApi: api,
          repository: repository,
          batchQueueController: batch,
          powerGate: _ExternalPower(),
          foregroundWorkLock: _NoopLock(),
          initialTask: task,
          mobileOverride: false,
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () => api.configureEntered.isCompleted,
      'Initial resource configuration did not start.',
    );
    final start = find.text('开始合成');
    await _waitForEnabledStart(tester);
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    releaseConfigure.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(api.startedBudgets, isEmpty);

    batch.dispose();
    settings.dispose();
  });

  testWidgets('disposing during resume preflight prevents native resume', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync(
      'memory-resource-dispose-resume-',
    );
    addTearDown(() => temp.deleteSync(recursive: true));
    final releaseConfigure = Completer<void>();
    final api = _ResourceApi(configureGate: releaseConfigure);
    final task = _task('${temp.path}/render', phase: StitchPhase.paused);
    final repository = _Repository(temp.path, [task]);
    final batch = EmptyBatchQueueController(
      api: api,
      taskRepository: repository,
    );
    final settings = SettingsController(
      repository: _MemorySettingsRepository(),
      initial: const AppSettings(),
    );
    await tester.pumpWidget(
      LumiaStitchApp(
        locale: const Locale('zh'),
        settingsController: settings,
        home: StitchHomePage(
          settingsController: settings,
          jobApi: api,
          repository: repository,
          batchQueueController: batch,
          powerGate: _ExternalPower(),
          foregroundWorkLock: _NoopLock(),
          initialTask: task,
          mobileOverride: false,
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () => api.configureEntered.isCompleted,
      'Initial resource configuration did not start.',
    );
    final resume = find.text('恢复');
    await tester.ensureVisible(resume);
    await tester.tap(resume);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    releaseConfigure.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(api.resumes, 0);

    batch.dispose();
    settings.dispose();
  });
}
