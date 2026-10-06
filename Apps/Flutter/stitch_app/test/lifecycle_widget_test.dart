import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:stitch_app/main.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'package:stitch_app/services/mobile_runtime_service.dart';
import 'support/chinese_test_app.dart';
import 'support/empty_batch_queue_controller.dart';

class FakeApi implements JobApi {
  int starts = 0, pauses = 0, resumes = 0, exports = 0;
  String statusState = 'running';
  String statusOperation = 'render';
  String? stateAfterPause;
  bool failPause = false;
  @override
  bool isAvailable = true;
  @override
  String? unavailableReason;
  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async {
    starts++;
    return {'ok': true, 'state': 'queued', 'jobId': 'test-job'};
  }

  @override
  Future<Map<String, Object?>> status(String jobId) async => {
    'ok': true,
    'state': statusState,
    'operation': statusOperation,
    'stage': 'register',
    'progress': 0.1,
  };
  @override
  Future<Map<String, Object?>> pause(String jobId) async {
    pauses++;
    if (failPause) throw StateError('native pause rejected');
    statusState = stateAfterPause ?? 'pausing';
    return {'ok': true, 'state': statusState};
  }

  @override
  Future<Map<String, Object?>> resume(String jobId) async {
    resumes++;
    return {'ok': true, 'state': 'running'};
  }

  @override
  Future<Map<String, Object?>> cancel(String jobId) async => {
    'ok': true,
    'state': 'cancelled',
  };
  @override
  Future<Map<String, Object?>> export(String jobId, String destination) async {
    exports++;
    statusOperation = 'export';
    return {'ok': true, 'state': 'running'};
  }

  @override
  Future<Map<String, Object?>> capabilities() async => {
    'ok': true,
    'capabilities': {
      'logicalCpuCount': 8,
      'maxWorkersPerJob': 32,
      'maxConcurrentJobs': 2,
      'totalCpuWorkers': 7,
      'totalMemoryBudgetMiB': 1024,
      'activeJobs': 0,
      'reservedWorkers': 0,
      'reservedMemoryMiB': 0,
    },
  };
  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) async => await capabilities();
}

class FakePower implements PowerGate {
  FakePower(this.value);
  PowerState value;
  @override
  Future<PowerState> readState() async => value;
}

class FakeRepository extends TaskRepository {
  FakeRepository(this.tasks);
  final List<StitchTask> tasks;
  @override
  Future<List<StitchTask>> loadAll() async => tasks;
  @override
  Future<void> save(StitchTask task) async {
    final index = tasks.indexWhere((item) => item.id == task.id);
    if (index < 0) {
      tasks.add(task);
    } else {
      tasks[index] = task;
    }
  }
}

class NoopForegroundWorkLock implements ForegroundWorkLock {
  @override
  Future<void> enable() async {}

  @override
  Future<void> disable() async {}
}

StitchTask fixture(
  StitchPhase phase, {
  String id = 'fixture',
  String? jobId,
  bool autoExportOnCompletion = false,
  String outputDirectory = 'output',
}) => StitchTask(
  id: id,
  createdAt: DateTime.utc(2026),
  sourceDirectory: 'source',
  outputDirectory: outputDirectory,
  photos: const [
    ImportedPhoto(
      originalName: 'image.jpg',
      storedPath: '0000.jpg',
      sha256: 'hash',
      width: 100,
      height: 80,
      originalOrder: 0,
    ),
  ],
  grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
  horizontalFovDegrees: 45,
  memoryBudgetMiB: 128,
  workers: 1,
  phase: phase,
  nativeJobId: jobId,
  autoExportOnCompletion: autoExportOnCompletion,
);

Future<EmptyBatchQueueController?> pumpPage(
  WidgetTester tester,
  StitchTask task,
  FakeApi api,
  PowerState power, {
  required bool mobile,
  bool android = false,
  MobileRuntimeService? runtimeService,
  ForegroundWorkLock? foregroundWorkLock,
  List<StitchTask>? tasks,
  FakeRepository? repository,
}) async {
  final taskRepository = repository ?? FakeRepository(tasks ?? [task]);
  final queueController = android
      ? EmptyBatchQueueController(api: api, taskRepository: taskRepository)
      : null;
  await tester.pumpWidget(
    ChineseTestApp(
      home: StitchHomePage(
        initialTask: task,
        jobApi: api,
        powerGate: FakePower(power),
        repository: taskRepository,
        batchQueueController: queueController,
        mobileOverride: mobile,
        androidOverride: android,
        mobileRuntimeService: runtimeService,
        foregroundWorkLock: foregroundWorkLock ?? NoopForegroundWorkLock(),
      ),
    ),
  );
  await tester.pump();
  return queueController;
}

Future<void> _pumpUntilStartEnabled(WidgetTester tester) async {
  final deadline = Stopwatch()..start();
  final start = find.widgetWithText(FilledButton, '开始合成');
  while (deadline.elapsed < const Duration(seconds: 5)) {
    if (start.evaluate().isNotEmpty &&
        tester.widget<FilledButton>(start).onPressed != null) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(
    start.evaluate().isNotEmpty &&
        tester.widget<FilledButton>(start).onPressed != null,
    isTrue,
    reason: 'Single-task start did not become enabled',
  );
}

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
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue, reason: '$reason (5 second deadline)');
}

void main() {
  testWidgets('mobile start is not blocked by external power state', (
    tester,
  ) async {
    final output = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'mobile-start-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync();
    addTearDown(() => output.delete(recursive: true));
    final task = fixture(
      StitchPhase.imported,
      outputDirectory: '${output.path}${Platform.pathSeparator}render',
    );
    final api = FakeApi();
    await pumpPage(tester, task, api, PowerState.battery, mobile: true);
    await _pumpUntilStartEnabled(tester);
    await tester.tap(find.widgetWithText(FilledButton, '开始合成'));
    await tester.pump();
    await _pumpUntil(
      tester,
      () => api.starts == 1,
      'Mobile single-task start did not reach the native API',
    );
    expect(api.starts, 1);
  });

  testWidgets('Android guard failure prevents native job start', (
    tester,
  ) async {
    final output = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'android-guard-start-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync();
    addTearDown(() => output.delete(recursive: true));
    const channel = MethodChannel('test.lifecycle-runtime-guard');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'readResourceBudget') {
            return <String, Object?>{
              'totalMemoryMiB': 4096,
              'availableMemoryMiB': 2048,
              'cpuCount': 8,
              'availableStorageMiB': 4096,
              'thermalStatus': 'none',
            };
          }
          if (call.method == 'setProcessingActive') return false;
          return null;
        });
    final runtime = MobileRuntimeService(channel: channel);
    final queueController = await pumpPage(
      tester,
      fixture(
        StitchPhase.imported,
        outputDirectory: '${output.path}${Platform.pathSeparator}render',
      ),
      FakeApi(),
      PowerState.battery,
      mobile: true,
      android: true,
      runtimeService: runtime,
    );
    await _pumpUntilStartEnabled(tester);
    final api =
        tester.widget<StitchHomePage>(find.byType(StitchHomePage)).jobApi!
            as FakeApi;
    await tester.tap(find.widgetWithText(FilledButton, '开始合成'));
    await tester.pump();
    await _pumpUntil(
      tester,
      () => find.text('无法启动 Android 后台运行保护；核心任务尚未启动').evaluate().isNotEmpty,
      'Android foreground-service rejection was not surfaced',
    );
    expect(api.starts, 0);
    expect(api.pauses, 0);
    expect(find.text('无法启动 Android 后台运行保护；核心任务尚未启动'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    queueController?.dispose();
    await runtime.dispose();
  });

  testWidgets('Android auto export retries after thermal deferral', (
    tester,
  ) async {
    final documents = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'android-auto-export-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync();
    addTearDown(() => documents.delete(recursive: true));
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => documents.path);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    const channel = MethodChannel('test.android-auto-export-runtime');
    var thermal = 'moderate';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'readResourceBudget') {
            return <String, Object?>{
              'totalMemoryMiB': 4096,
              'availableMemoryMiB': 2048,
              'cpuCount': 8,
              'availableStorageMiB': 4096,
              'thermalStatus': thermal,
            };
          }
          if (call.method == 'setProcessingActive') return true;
          return null;
        });
    final runtime = MobileRuntimeService(channel: channel);
    final api = FakeApi()..statusState = 'completed';
    final output = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'android-auto-export-task-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync();
    addTearDown(() => output.delete(recursive: true));
    final task = fixture(
      StitchPhase.running,
      jobId: 'auto-export-job',
      autoExportOnCompletion: true,
      outputDirectory: '${output.path}${Platform.pathSeparator}render',
    );
    final queueController = await pumpPage(
      tester,
      task,
      api,
      PowerState.battery,
      mobile: true,
      android: true,
      runtimeService: runtime,
    );
    await _pumpUntil(
      tester,
      () => find.text('设备温度较高，待温度降低后再启动新任务。').evaluate().isNotEmpty,
      'Thermal deferral was not surfaced for automatic export',
    );
    expect(api.exports, 0);
    expect(find.text('设备温度较高，待温度降低后再启动新任务。'), findsOneWidget);

    thermal = 'none';
    await _pumpUntil(
      tester,
      () => api.exports == 1,
      'Automatic export did not retry after thermal status cooled',
    );
    expect(api.exports, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(api.exports, 1);
    await tester.pumpWidget(const SizedBox());
    queueController?.dispose();
    await runtime.dispose();
  });

  testWidgets(
    'cold start pauses a timed-out unselected standalone job before acknowledging it',
    (tester) async {
      const channel = MethodChannel('test.cold-timeout-recovery');
      final pendingIds = <String>['timed-out-unselected-job'];
      final acknowledged = <String>[];
      var runtimeStartCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'readResourceBudget':
                return <String, Object?>{
                  'totalMemoryMiB': 4096,
                  'availableMemoryMiB': 2048,
                  'cpuCount': 8,
                  'availableStorageMiB': 4096,
                  'thermalStatus': 'none',
                };
              case 'readPendingTimeoutJobs':
                return List<String>.of(pendingIds);
              case 'acknowledgeTimeoutJobs':
                final ids = ((call.arguments as Map)['jobIds'] as List)
                    .cast<String>();
                acknowledged.addAll(ids);
                pendingIds.removeWhere(ids.contains);
                return true;
              case 'setProcessingActive':
                final arguments = call.arguments as Map;
                if (arguments['active'] == true) runtimeStartCalls++;
                return true;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final selected = fixture(
        StitchPhase.imported,
        outputDirectory: 'selected-output',
      );
      final timedOut = fixture(
        StitchPhase.running,
        id: 'unselected-timeout-task',
        jobId: 'timed-out-unselected-job',
        autoExportOnCompletion: true,
        outputDirectory: 'timed-out-output',
      );
      final repository = FakeRepository([selected, timedOut]);
      final api = FakeApi()..stateAfterPause = 'paused';
      final runtime = MobileRuntimeService(channel: channel);
      final queueController = await pumpPage(
        tester,
        selected,
        api,
        PowerState.battery,
        mobile: true,
        android: true,
        runtimeService: runtime,
        repository: repository,
      );
      await _pumpUntil(
        tester,
        () => acknowledged.contains('timed-out-unselected-job'),
        'Cold-start timeout was not paused and acknowledged',
      );

      final saved = repository.tasks.singleWhere(
        (task) => task.id == 'unselected-timeout-task',
      );
      expect(api.pauses, 1);
      expect(api.statusState, 'paused');
      expect(saved.phase, StitchPhase.paused);
      expect(saved.autoExportOnCompletion, isFalse);
      expect(acknowledged, ['timed-out-unselected-job']);
      expect(pendingIds, isEmpty);
      expect(runtimeStartCalls, 0);

      await tester.pumpWidget(const SizedBox());
      queueController?.dispose();
      await runtime.dispose();
    },
  );

  testWidgets(
    'timed-out standalone job stays pending when pause fails and status remains running',
    (tester) async {
      const channel = MethodChannel('test.failed-timeout-recovery');
      final pendingIds = <String>['still-running-timeout-job'];
      final acknowledged = <String>[];
      var runtimeStartCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'readResourceBudget':
                return <String, Object?>{
                  'totalMemoryMiB': 4096,
                  'availableMemoryMiB': 2048,
                  'cpuCount': 8,
                  'availableStorageMiB': 4096,
                  'thermalStatus': 'none',
                };
              case 'readPendingTimeoutJobs':
                return List<String>.of(pendingIds);
              case 'acknowledgeTimeoutJobs':
                final ids = ((call.arguments as Map)['jobIds'] as List)
                    .cast<String>();
                acknowledged.addAll(ids);
                pendingIds.removeWhere(ids.contains);
                return true;
              case 'setProcessingActive':
                final arguments = call.arguments as Map;
                if (arguments['active'] == true) runtimeStartCalls++;
                return true;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final selected = fixture(
        StitchPhase.imported,
        outputDirectory: 'selected-output',
      );
      final timedOut = fixture(
        StitchPhase.running,
        id: 'unselected-running-timeout-task',
        jobId: 'still-running-timeout-job',
        autoExportOnCompletion: true,
        outputDirectory: 'still-running-output',
      );
      final repository = FakeRepository([selected, timedOut]);
      final api = FakeApi()..failPause = true;
      final runtime = MobileRuntimeService(channel: channel);
      final queueController = await pumpPage(
        tester,
        selected,
        api,
        PowerState.battery,
        mobile: true,
        android: true,
        runtimeService: runtime,
        repository: repository,
      );
      await _pumpUntil(
        tester,
        () =>
            api.pauses == 1 &&
            repository.tasks
                    .singleWhere(
                      (task) => task.id == 'unselected-running-timeout-task',
                    )
                    .pauseReason !=
                null,
        'Cold-start recovery never requested a pause for the unselected job',
      );

      final saved = repository.tasks.singleWhere(
        (task) => task.id == 'unselected-running-timeout-task',
      );
      expect(api.statusState, 'running');
      expect(saved.phase, StitchPhase.running);
      expect(saved.autoExportOnCompletion, isFalse);
      expect(saved.pauseReason, contains('仍在停止'));
      expect(acknowledged, isEmpty);
      expect(pendingIds, ['still-running-timeout-job']);
      expect(runtimeStartCalls, 0);

      await tester.pumpWidget(const SizedBox());
      queueController?.dispose();
      await runtime.dispose();
    },
  );

  testWidgets(
    'failed timeout acknowledgement blocks standalone resume until saved',
    (tester) async {
      const channel = MethodChannel('test.timeout-ack-retry');
      final pendingIds = <String>['timed-out-standalone-job'];
      var acknowledgements = 0;
      var allowAcknowledgement = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'readResourceBudget':
                return <String, Object?>{
                  'totalMemoryMiB': 4096,
                  'availableMemoryMiB': 2048,
                  'cpuCount': 8,
                  'availableStorageMiB': 4096,
                  'thermalStatus': 'none',
                };
              case 'readPendingTimeoutJobs':
                return List<String>.of(pendingIds);
              case 'acknowledgeTimeoutJobs':
                acknowledgements++;
                if (!allowAcknowledgement) return false;
                final ids = ((call.arguments as Map)['jobIds'] as List)
                    .cast<String>();
                pendingIds.removeWhere(ids.contains);
                return true;
              case 'setProcessingActive':
                return true;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final task = fixture(
        StitchPhase.running,
        id: 'timed-out-standalone-task',
        jobId: 'timed-out-standalone-job',
      );
      final repository = FakeRepository([task]);
      final api = FakeApi()..stateAfterPause = 'paused';
      final runtime = MobileRuntimeService(channel: channel);
      final queueController = await pumpPage(
        tester,
        task,
        api,
        PowerState.battery,
        mobile: true,
        android: true,
        runtimeService: runtime,
        repository: repository,
      );

      await _pumpUntil(
        tester,
        () =>
            acknowledgements == 1 &&
            api.pauses == 1 &&
            repository.tasks.single.phase == StitchPhase.paused,
        'Timeout pause was not confirmed before the initial acknowledgement',
      );
      expect(pendingIds, ['timed-out-standalone-job']);

      await tester.tap(find.text('恢复'));
      await tester.pump();
      await _pumpUntil(
        tester,
        () => acknowledgements == 2,
        'Explicit resume did not retry the failed durable acknowledgement',
      );
      expect(api.resumes, 0);
      expect(api.pauses, 1);
      expect(pendingIds, ['timed-out-standalone-job']);
      expect(find.text('无法保存 Android 后台暂停记录；请重试后再启动或恢复。'), findsOneWidget);

      allowAcknowledgement = true;
      await tester.tap(find.text('恢复'));
      await tester.pump();
      await _pumpUntil(
        tester,
        () => api.resumes == 1,
        'Resume did not proceed after the durable acknowledgement succeeded',
      );
      expect(acknowledgements, 3);
      expect(api.pauses, 1);
      expect(pendingIds, isEmpty);

      await tester.pumpWidget(const SizedBox());
      queueController?.dispose();
      await runtime.dispose();
    },
  );

  testWidgets('mobile background requests a cooperative pause', (tester) async {
    final api = FakeApi();
    await pumpPage(
      tester,
      fixture(StitchPhase.running, jobId: 'test-job'),
      api,
      PowerState.externalPower,
      mobile: true,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(api.pauses, 1);
  });

  testWidgets('desktop background leaves the native job running', (
    tester,
  ) async {
    final api = FakeApi();
    await pumpPage(
      tester,
      fixture(StitchPhase.running, jobId: 'test-job'),
      api,
      PowerState.notRequired,
      mobile: false,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(api.pauses, 0);
  });

  testWidgets(
    'external power changes do not pause or auto-resume a running job',
    (tester) async {
      final api = FakeApi();
      final power = FakePower(PowerState.externalPower);
      await tester.pumpWidget(
        ChineseTestApp(
          home: StitchHomePage(
            initialTask: fixture(StitchPhase.running, jobId: 'test-job'),
            jobApi: api,
            powerGate: power,
            repository: FakeRepository([]),
            mobileOverride: true,
            foregroundWorkLock: NoopForegroundWorkLock(),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      power.value = PowerState.battery;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.pauses, 0);
      power.value = PowerState.externalPower;
      await tester.pump(const Duration(seconds: 2));
      expect(api.resumes, 0);
      expect(api.statusState, 'running');
    },
  );

  testWidgets(
    'unknown external power does not block paused resume or enable export',
    (tester) async {
      final api = FakeApi();
      await pumpPage(
        tester,
        fixture(StitchPhase.paused, jobId: 'test-job'),
        api,
        PowerState.unknown,
        mobile: true,
      );
      await tester.tap(find.text('恢复'));
      await tester.pump();
      expect(api.resumes, 1);

      final completedApi = FakeApi();
      await tester.pumpWidget(
        ChineseTestApp(
          home: StitchHomePage(
            key: const ValueKey('completed-task'),
            initialTask: fixture(StitchPhase.completed, jobId: 'test-job'),
            initialManifest: const {},
            jobApi: completedApi,
            powerGate: FakePower(PowerState.unknown),
            repository: FakeRepository([]),
            mobileOverride: true,
            foregroundWorkLock: NoopForegroundWorkLock(),
          ),
        ),
      );
      final exportButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '导出完整 PNG'),
      );
      expect(exportButton.onPressed, isNotNull);
      expect(completedApi.exports, 0);
    },
  );
}
