import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/main.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'support/chinese_test_app.dart';

class FakeApi implements JobApi {
  int starts = 0, pauses = 0, resumes = 0, exports = 0;
  String statusState = 'running';
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
    'stage': 'register',
    'progress': 0.1,
  };
  @override
  Future<Map<String, Object?>> pause(String jobId) async {
    pauses++;
    statusState = 'pausing';
    return {'ok': true, 'state': 'pausing'};
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
  Future<void> save(StitchTask task) async {}
}

StitchTask fixture(StitchPhase phase, {String? jobId}) => StitchTask(
  id: 'fixture',
  createdAt: DateTime.utc(2026),
  sourceDirectory: 'source',
  outputDirectory: 'output',
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
);

Future<void> pumpPage(
  WidgetTester tester,
  StitchTask task,
  FakeApi api,
  PowerState power, {
  required bool mobile,
}) async {
  await tester.pumpWidget(
    ChineseTestApp(
      home: StitchHomePage(
        initialTask: task,
        jobApi: api,
        powerGate: FakePower(power),
        repository: FakeRepository([task]),
        mobileOverride: mobile,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'mobile start fails closed when external power is not confirmed',
    (tester) async {
      final api = FakeApi();
      await pumpPage(
        tester,
        fixture(StitchPhase.imported),
        api,
        PowerState.battery,
        mobile: true,
      );
      await tester.tap(find.text('开始合成'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.starts, 0);
      expect(find.textContaining('外部电源'), findsOneWidget);
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
    'unplugging during work requests pause; plugging back never auto-resumes',
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
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      power.value = PowerState.battery;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.pauses, 1);
      power.value = PowerState.externalPower;
      await tester.pump(const Duration(seconds: 2));
      expect(api.resumes, 0);
      expect(api.statusState, 'pausing');
    },
  );

  testWidgets(
    'unknown external power blocks paused resume and completed export',
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
      expect(api.resumes, 0);
      expect(find.textContaining('无法确认外接电源状态'), findsOneWidget);

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
          ),
        ),
      );
      final exportButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '导出完整 PNG'),
      );
      expect(exportButton.onPressed, isNotNull);
      await tester.tap(find.text('导出完整 PNG'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(completedApi.exports, 0);
      expect(find.textContaining('整图导出需要外接电源'), findsOneWidget);
    },
  );
}
