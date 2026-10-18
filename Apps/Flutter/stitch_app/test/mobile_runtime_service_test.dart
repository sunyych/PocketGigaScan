import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/services/mobile_runtime_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/mobile-runtime');
  const productionChannel = MethodChannel('com.lumiaiq.pocketgigascan/runtime');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(productionChannel, null);
  });

  test('default service uses the production runtime channel', () async {
    messenger.setMockMethodCallHandler(productionChannel, (call) async {
      expect(call.method, 'readResourceBudget');
      return {
        'totalMemoryMiB': 4096,
        'availableMemoryMiB': 2048,
        'cpuCount': 4,
        'availableStorageMiB': 1024,
        'thermalStatus': 'none',
      };
    });
    final service = MobileRuntimeService();
    addTearDown(service.dispose);

    final budget = await service.readResourceBudget();
    expect(budget.totalMemoryMiB, 4096);
  });

  test('resource budget fields are mapped from the Android platform', () async {
    final service = MobileRuntimeService(channel: channel);
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'readResourceBudget');
      return {
        'totalMemoryMiB': 3790,
        'availableMemoryMiB': 1420,
        'cpuCount': 8,
        'availableStorageMiB': 24000,
        'thermalStatus': 'light',
      };
    });

    final budget = await service.readResourceBudget();
    expect(budget.totalMemoryMiB, 3790);
    expect(budget.availableMemoryMiB, 1420);
    expect(budget.cpuCount, 8);
    expect(budget.availableStorageMiB, 24000);
    expect(budget.thermalStatus, 'light');
    expect(budget.recommendedTotalMemoryBudgetMiB, 473);
    expect(budget.recommendedTotalCpuWorkers, 4);
    expect(budget.recommendedMaxConcurrentJobs, 3);
    expect(budget.shouldDeferNewStarts, isFalse);
    expect(budget.isStorageConstrained, isFalse);
    await service.dispose();
  });

  test('low-memory device stays within native minimum and one worker', () {
    final budget = MobileResourceBudget.fromMap({
      'totalMemoryMiB': 2048,
      'availableMemoryMiB': 300,
      'cpuCount': 2,
      'availableStorageMiB': 400,
      'thermalStatus': 'light',
    });
    expect(budget.recommendedTotalMemoryBudgetMiB, 128);
    expect(budget.recommendedTotalCpuWorkers, 1);
    expect(budget.recommendedMaxConcurrentJobs, 1);
    expect(budget.isStorageConstrained, isTrue);
  });

  test(
    'high-memory recommendation respects native worker and memory bounds',
    () {
      final budget = MobileResourceBudget.fromMap({
        'totalMemoryMiB': 65536,
        'availableMemoryMiB': 50000,
        'cpuCount': 128,
        'availableStorageMiB': 100000,
        'thermalStatus': 'none',
      });
      expect(budget.recommendedTotalMemoryBudgetMiB, 50000 ~/ 3);
      expect(budget.recommendedTotalCpuWorkers, 32);
      expect(budget.recommendedMaxConcurrentJobs, 8);
    },
  );

  test('moderate or hotter thermal state defers new starts', () {
    for (final thermal in ['moderate', 'severe', 'critical', 'emergency']) {
      final budget = MobileResourceBudget.fromMap({
        'totalMemoryMiB': 4096,
        'availableMemoryMiB': 2048,
        'cpuCount': 4,
        'availableStorageMiB': 2048,
        'thermalStatus': thermal,
      });
      expect(budget.shouldDeferNewStarts, isTrue, reason: thermal);
    }
  });

  test(
    'missing or malformed readings use conservative start-safe defaults',
    () {
      final budget = MobileResourceBudget.fromMap({
        'totalMemoryMiB': 'unknown',
        'availableMemoryMiB': -20,
        'cpuCount': null,
        'availableStorageMiB': 'unknown',
        'thermalStatus': null,
      });
      expect(budget.recommendedTotalMemoryBudgetMiB, 128);
      expect(budget.recommendedTotalCpuWorkers, 1);
      expect(budget.recommendedMaxConcurrentJobs, 1);
      expect(budget.isStorageConstrained, isTrue);
      expect(budget.shouldDeferNewStarts, isFalse);
    },
  );

  test('processing state changes register a job id and fail closed', () async {
    final service = MobileRuntimeService(channel: channel);
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    expect(await service.setProcessingActive(true, jobId: 'job-a'), isTrue);
    expect(await service.setProcessingActive(false, jobId: 'job-a'), isTrue);
    expect(calls.map((call) => call.arguments), [
      {'active': true, 'jobId': 'job-a'},
      {'active': false, 'jobId': 'job-a'},
    ]);

    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'DENIED'),
    );
    expect(await service.setProcessingActive(true, jobId: 'job-b'), isFalse);
    await service.dispose();
  });

  test(
    'pending timeout reads do not auto-ack and explicit ack sends exact ids',
    () async {
      final service = MobileRuntimeService(channel: channel);
      final calls = <MethodCall>[];
      var pending = <String>['job-a', 'job-b'];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'readPendingTimeoutJobs') return pending;
        if (call.method == 'acknowledgeTimeoutJobs') {
          final ids = (call.arguments as Map)['jobIds'] as List<Object?>;
          pending = pending.where((id) => !ids.contains(id)).toList();
          return true;
        }
        return null;
      });

      expect(await service.readPendingTimeoutJobs(), ['job-a', 'job-b']);
      expect(pending, ['job-a', 'job-b']);
      expect(await service.acknowledgeTimeoutJobs(['job-a']), isTrue);
      expect(await service.readPendingTimeoutJobs(), ['job-b']);
      expect(calls.map((call) => call.method), [
        'readPendingTimeoutJobs',
        'acknowledgeTimeoutJobs',
        'readPendingTimeoutJobs',
      ]);
      expect(calls[1].arguments, {
        'jobIds': ['job-a'],
      });
      await service.dispose();
    },
  );
}
