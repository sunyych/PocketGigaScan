import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/app_settings.dart';
import 'package:stitch_app/services/memory_budget_policy.dart';

void main() {
  test('native system memory reading is valid without a CPU field', () {
    final reading = MemoryResourceReading.fromMap({
      'totalMemoryMiB': 128 * 1024,
      'availableMemoryMiB': 64 * 1024,
    }, source: 'native-system');
    expect(reading.valid, isTrue);
    expect(reading.logicalCpuCount, 1);
  });

  test(
    'automatic cap follows measured available headroom and supported marks',
    () {
      final reading = MemoryResourceReading(
        totalMemoryMiB: 127 * 1024,
        availableMemoryMiB: 64 * 1024,
        logicalCpuCount: 16,
        source: 'native',
      );
      final result = MemoryBudgetPolicy.evaluate(
        const AppSettings(),
        reading,
        mobile: false,
      );
      expect(result.readingValid, isTrue);
      expect(result.maximumMiB, 48 * 1024);
      expect(result.recommendedMiB, result.maximumMiB);
      expect(result.selectedMiB, result.recommendedMiB);
      expect(result.markMiB, [16 * 1024, 32 * 1024]);
      expect(result.markMiB, isNot(contains(64 * 1024)));
    },
  );

  test('new task shares fit within configured app budget', () {
    expect(MemoryBudgetPolicy.allocatedJobBudgetMiB(32 * 1024, 2), 16 * 1024);
    expect(MemoryBudgetPolicy.allocatedJobBudgetMiB(512, 8), 128);
    expect(MemoryBudgetPolicy.allocatedJobBudgetMiB(128 * 1024, 99), 16 * 1024);
  });

  test(
    'manual setting remains persisted while its effective cap follows headroom',
    () {
      const settings = AppSettings(
        memoryBudgetMode: MemoryBudgetMode.manual,
        totalMemoryBudgetMiB: 64 * 1024,
      );
      final result = MemoryBudgetPolicy.evaluate(
        settings,
        const MemoryResourceReading(
          totalMemoryMiB: 128 * 1024,
          availableMemoryMiB: 40 * 1024,
          logicalCpuCount: 16,
        ),
        mobile: false,
      );
      expect(result.selectedMiB, 30 * 1024);
      expect(settings.totalMemoryBudgetMiB, 64 * 1024);
      expect(settings.toJson()['totalMemoryBudgetMiB'], 64 * 1024);
    },
  );

  test('missing measurements use conservative platform fallback', () {
    final desktop = MemoryBudgetPolicy.evaluate(
      const AppSettings(),
      const MemoryResourceReading(
        totalMemoryMiB: 0,
        availableMemoryMiB: 0,
        valid: false,
      ),
      mobile: false,
    );
    final mobile = MemoryBudgetPolicy.evaluate(
      const AppSettings(),
      const MemoryResourceReading(
        totalMemoryMiB: 0,
        availableMemoryMiB: 0,
        valid: false,
      ),
      mobile: true,
    );
    expect(desktop.selectedMiB, 512);
    expect(mobile.selectedMiB, 128);
    expect(desktop.readingValid, isFalse);
    expect(mobile.readingValid, isFalse);
  });

  test('inconsistent physical readings use conservative mobile fallback', () {
    final result = MemoryBudgetPolicy.evaluate(
      const AppSettings(),
      const MemoryResourceReading(
        totalMemoryMiB: 4096,
        availableMemoryMiB: 8192,
        logicalCpuCount: 4,
      ),
      mobile: true,
    );
    expect(result.readingValid, isFalse);
    expect(result.selectedMiB, 128);
  });

  test(
    'legacy settings decode to automatic memory mode without dropping values',
    () {
      final legacy = AppSettings.fromJson({'language': 'en'});
      expect(legacy.memoryBudgetMode, MemoryBudgetMode.automatic);
      expect(legacy.totalMemoryBudgetMiB, 512);
      final manual = AppSettings.fromJson({
        'memoryBudgetMode': 'manual',
        'totalMemoryBudgetMiB': 32 * 1024,
      });
      expect(manual.memoryBudgetMode, MemoryBudgetMode.manual);
      expect(manual.totalMemoryBudgetMiB, 32 * 1024);
    },
  );
}
