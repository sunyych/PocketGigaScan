import 'dart:convert';

import 'performance_options.dart';
import 'stitch_quality.dart';

enum AppLanguage { system, en, zh }

enum AppThemeMode { system, light, dark }

enum AppAccent { teal, blue, purple, orange }

enum MemoryBudgetMode { automatic, manual }

enum TextSizeMode { system, custom }

enum TaskDateFormat { yearMonthDay, monthDayYear }

enum ResultGallerySort {
  nameAscending,
  nameDescending,
  newestFirst,
  oldestFirst,
}

String formatTaskDateTime(DateTime value, TaskDateFormat format) {
  final local = value.toLocal();
  final year = local.year.toString().padLeft(4, '0');
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final date = format == TaskDateFormat.yearMonthDay
      ? '$year-$month-$day'
      : '$month/$day/$year';
  return '$date ${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

class AppSettings {
  const AppSettings({
    this.language = AppLanguage.system,
    this.themeMode = AppThemeMode.system,
    this.accent = AppAccent.teal,
    this.exportFormat = ExportFormat.jpeg,
    this.exportFormatExplicitlySet = false,
    this.refineGridNeighbors = true,
    this.seamBlendMode = SeamBlendMode.deghost,
    this.localTextureWarp = true,
    this.protectPeople = false,
    this.smoothWater = false,
    this.memoryBudgetMode = MemoryBudgetMode.automatic,
    this.totalMemoryBudgetMiB = 512,
    this.performance = const PerformanceOptions(),
    this.textSizeMode = TextSizeMode.system,
    this.textScale = 1.0,
    this.outputDirectory,
    this.batchOutputDirectory,
    this.taskDateFormat = TaskDateFormat.yearMonthDay,
    this.resultGallerySort = ResultGallerySort.newestFirst,
    this.taskRailWidth = 230,
  });

  final AppLanguage language;
  final AppThemeMode themeMode;
  final AppAccent accent;
  final ExportFormat exportFormat;
  final bool exportFormatExplicitlySet;
  final bool refineGridNeighbors;
  final SeamBlendMode seamBlendMode;
  final bool localTextureWarp;
  final bool protectPeople;
  final bool smoothWater;
  final MemoryBudgetMode memoryBudgetMode;
  final int totalMemoryBudgetMiB;
  final PerformanceOptions performance;
  final TextSizeMode textSizeMode;
  final double textScale;

  double get effectiveTextScale => _safeTextScale(textScale);

  /// Filesystem path on desktop or a platform document URI on Android.
  final String? outputDirectory;
  final String? batchOutputDirectory;
  final TaskDateFormat taskDateFormat;
  final ResultGallerySort resultGallerySort;
  final double taskRailWidth;

  factory AppSettings.defaults({required bool mobile, bool android = false}) =>
      AppSettings(
        exportFormat: mobile
            ? (android ? ExportFormat.tiff : ExportFormat.png)
            : ExportFormat.jpeg,
        refineGridNeighbors: !mobile || android,
        seamBlendMode: mobile && !android
            ? SeamBlendMode.feather
            : SeamBlendMode.deghost,
      );

  AppSettings copyWith({
    AppLanguage? language,
    AppThemeMode? themeMode,
    AppAccent? accent,
    ExportFormat? exportFormat,
    bool? exportFormatExplicitlySet,
    bool? refineGridNeighbors,
    SeamBlendMode? seamBlendMode,
    bool? localTextureWarp,
    bool? protectPeople,
    bool? smoothWater,
    MemoryBudgetMode? memoryBudgetMode,
    int? totalMemoryBudgetMiB,
    PerformanceOptions? performance,
    TextSizeMode? textSizeMode,
    double? textScale,
    String? outputDirectory,
    bool clearOutputDirectory = false,
    String? batchOutputDirectory,
    bool clearBatchOutputDirectory = false,
    TaskDateFormat? taskDateFormat,
    ResultGallerySort? resultGallerySort,
    double? taskRailWidth,
  }) => AppSettings(
    language: language ?? this.language,
    themeMode: themeMode ?? this.themeMode,
    accent: accent ?? this.accent,
    exportFormat: exportFormat ?? this.exportFormat,
    exportFormatExplicitlySet:
        exportFormatExplicitlySet ?? this.exportFormatExplicitlySet,
    refineGridNeighbors: refineGridNeighbors ?? this.refineGridNeighbors,
    seamBlendMode: seamBlendMode ?? this.seamBlendMode,
    localTextureWarp: localTextureWarp ?? this.localTextureWarp,
    protectPeople: protectPeople ?? this.protectPeople,
    smoothWater: smoothWater ?? this.smoothWater,
    memoryBudgetMode: memoryBudgetMode ?? this.memoryBudgetMode,
    totalMemoryBudgetMiB: totalMemoryBudgetMiB ?? this.totalMemoryBudgetMiB,
    performance: performance ?? this.performance,
    textSizeMode: textSizeMode ?? this.textSizeMode,
    textScale: textScale ?? this.textScale,
    outputDirectory: clearOutputDirectory
        ? null
        : outputDirectory ?? this.outputDirectory,
    batchOutputDirectory: clearBatchOutputDirectory
        ? null
        : batchOutputDirectory ?? this.batchOutputDirectory,
    taskDateFormat: taskDateFormat ?? this.taskDateFormat,
    resultGallerySort: resultGallerySort ?? this.resultGallerySort,
    taskRailWidth: _safeTaskRailWidth(taskRailWidth ?? this.taskRailWidth),
  );

  Map<String, Object?> toJson() => {
    'version': 2,
    'language': language.name,
    'themeMode': themeMode.name,
    'accent': accent.name,
    'exportFormat': exportFormat.name,
    'exportFormatExplicitlySet': exportFormatExplicitlySet,
    'refineGridNeighbors': refineGridNeighbors,
    'seamBlendMode': seamBlendMode.name,
    'localTextureWarp': localTextureWarp,
    'protectPeople': protectPeople,
    'smoothWater': smoothWater,
    'memoryBudgetMode': memoryBudgetMode.name,
    'totalMemoryBudgetMiB': totalMemoryBudgetMiB,
    'performance': performance.toJson(),
    'textSizeMode': textSizeMode.name,
    'textScale': effectiveTextScale,
    'outputDirectory': outputDirectory,
    'batchOutputDirectory': batchOutputDirectory,
    'taskDateFormat': taskDateFormat.name,
    'resultGallerySort': resultGallerySort.name,
    'taskRailWidth': _safeTaskRailWidth(taskRailWidth),
  };

  factory AppSettings.fromJson(Map<String, Object?> json) {
    T enumValue<T extends Enum>(List<T> values, Object? raw, T fallback) {
      for (final value in values) {
        if (value.name == raw) {
          return value;
        }
      }
      return fallback;
    }

    return AppSettings(
      language: enumValue(
        AppLanguage.values,
        json['language'],
        AppLanguage.system,
      ),
      themeMode: enumValue(
        AppThemeMode.values,
        json['themeMode'],
        AppThemeMode.system,
      ),
      accent: enumValue(AppAccent.values, json['accent'], AppAccent.teal),
      exportFormat: json.containsKey('exportFormat')
          ? ExportFormat.fromSavedValue(json['exportFormat'])
          : ExportFormat.jpeg,
      exportFormatExplicitlySet:
          json['exportFormatExplicitlySet'] as bool? ?? false,
      refineGridNeighbors: json['refineGridNeighbors'] as bool? ?? true,
      seamBlendMode: json.containsKey('seamBlendMode')
          ? SeamBlendMode.fromSavedValue(json['seamBlendMode'])
          : SeamBlendMode.deghost,
      localTextureWarp: json['localTextureWarp'] as bool? ?? true,
      protectPeople: json['protectPeople'] as bool? ?? false,
      smoothWater: json['smoothWater'] as bool? ?? false,
      memoryBudgetMode: enumValue(
        MemoryBudgetMode.values,
        json['memoryBudgetMode'],
        MemoryBudgetMode.automatic,
      ),
      totalMemoryBudgetMiB: _integer(json['totalMemoryBudgetMiB']) ?? 512,
      performance: PerformanceOptions.fromJson(
        (json['performance'] as Map?)?.cast<String, Object?>(),
      ),
      textSizeMode: enumValue(
        TextSizeMode.values,
        json['textSizeMode'],
        TextSizeMode.system,
      ),
      textScale: _safeTextScale(json['textScale']),
      outputDirectory: json['outputDirectory'] as String?,
      batchOutputDirectory: json['batchOutputDirectory'] as String?,
      taskDateFormat: enumValue(
        TaskDateFormat.values,
        json['taskDateFormat'],
        TaskDateFormat.yearMonthDay,
      ),
      resultGallerySort: enumValue(
        ResultGallerySort.values,
        json['resultGallerySort'],
        ResultGallerySort.newestFirst,
      ),
      taskRailWidth: _safeTaskRailWidth(json['taskRailWidth']),
    );
  }

  static AppSettings decode(String value) =>
      AppSettings.fromJson((jsonDecode(value) as Map).cast<String, Object?>());

  static int? _integer(Object? value) => switch (value) {
    int result when result > 0 => result,
    num result
        when result.isFinite &&
            result > 0 &&
            result == result.roundToDouble() =>
      result.toInt(),
    _ => null,
  };

  static double _safeTextScale(Object? value) => switch (value) {
    num scale when scale.isFinite =>
      scale.toDouble().clamp(1.0, 2.0).toDouble(),
    _ => 1.0,
  };

  static double _safeTaskRailWidth(Object? value) => switch (value) {
    num width when width.isFinite => width.toDouble().clamp(180.0, 520.0),
    _ => 230.0,
  };
}
