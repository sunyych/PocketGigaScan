import '../models/app_settings.dart';

class MemoryResourceReading {
  const MemoryResourceReading({
    required this.totalMemoryMiB,
    required this.availableMemoryMiB,
    this.logicalCpuCount = 1,
    this.valid = true,
    this.source = 'unknown',
  });

  final int totalMemoryMiB;
  final int availableMemoryMiB;
  final int logicalCpuCount;
  final bool valid;
  final String source;

  factory MemoryResourceReading.fromMap(
    Map<Object?, Object?> values, {
    required String source,
  }) {
    final total = _integer(values['totalMemoryMiB']);
    final available = _integer(values['availableMemoryMiB']);
    final cpus = _integer(values['logicalCpuCount'] ?? values['cpuCount']);
    final valid = total > 0 && available > 0 && available <= total;
    return MemoryResourceReading(
      totalMemoryMiB: total,
      availableMemoryMiB: available,
      logicalCpuCount: cpus > 0 ? cpus : 1,
      valid: valid,
      source: source,
    );
  }

  static int _integer(Object? value) => switch (value) {
    int result => result,
    num result when result.isFinite && result == result.roundToDouble() =>
      result.toInt(),
    _ => 0,
  };
}

class MemoryBudgetRecommendation {
  const MemoryBudgetRecommendation({
    required this.minimumMiB,
    required this.maximumMiB,
    required this.recommendedMiB,
    required this.selectedMiB,
    required this.markMiB,
    required this.readingValid,
  });

  final int minimumMiB;
  final int maximumMiB;
  final int recommendedMiB;
  final int selectedMiB;
  final List<int> markMiB;
  final bool readingValid;
}

/// Whole-application managed memory budget. Desktop uses 75% of available
/// memory; mobile uses one third. Neither recommendation allocates memory.
abstract final class MemoryBudgetPolicy {
  static const minimumMiB = 128;
  static const maximumMiB = 128 * 1024;
  static const gibibyteMiB = 1024;
  static const _availableHeadroomNumerator = 3;
  static const _availableHeadroomDenominator = 4;

  static int allocatedJobBudgetMiB(int totalMemoryMiB, int concurrentJobs) {
    final slots = concurrentJobs
        .clamp(1, (totalMemoryMiB ~/ minimumMiB).clamp(1, 8))
        .toInt();
    return (totalMemoryMiB ~/ slots).clamp(minimumMiB, maximumMiB).toInt();
  }

  static MemoryBudgetRecommendation evaluate(
    AppSettings settings,
    MemoryResourceReading reading, {
    required bool mobile,
  }) {
    final fallback = mobile ? minimumMiB : 512;
    final available = reading.availableMemoryMiB;
    final readingValid =
        reading.valid &&
        reading.totalMemoryMiB > 0 &&
        available > 0 &&
        available <= reading.totalMemoryMiB;
    final safeAvailable = mobile
        ? available ~/ 3
        : (available ~/ _availableHeadroomDenominator) *
                  _availableHeadroomNumerator +
              (available % _availableHeadroomDenominator) *
                  _availableHeadroomNumerator ~/
                  _availableHeadroomDenominator;
    final safeMaximum = readingValid
        ? safeAvailable.clamp(minimumMiB, maximumMiB).toInt()
        : fallback;
    final recommended = readingValid ? safeMaximum : fallback;
    final selected = settings.memoryBudgetMode == MemoryBudgetMode.automatic
        ? recommended
        : settings.totalMemoryBudgetMiB.clamp(minimumMiB, safeMaximum).toInt();
    final marks = [16, 32, 64]
        .map((gib) => gib * gibibyteMiB)
        .where((mib) => mib <= safeMaximum)
        .toList(growable: false);
    return MemoryBudgetRecommendation(
      minimumMiB: minimumMiB,
      maximumMiB: safeMaximum,
      recommendedMiB: recommended,
      selectedMiB: selected,
      markMiB: marks,
      readingValid: readingValid,
    );
  }

  static int sliderValue(int value, int maximumMiB) =>
      value.clamp(minimumMiB, maximumMiB).toInt();
}
