import 'dart:convert';

import 'performance_options.dart';
import 'stitch_quality.dart';

enum AppLanguage { system, en, zh }

enum AppThemeMode { system, light, dark }

enum AppAccent { teal, blue, purple, orange }

class AppSettings {
  const AppSettings({
    this.language = AppLanguage.system,
    this.themeMode = AppThemeMode.system,
    this.accent = AppAccent.teal,
    this.exportFormat = ExportFormat.tiff,
    this.refineGridNeighbors = true,
    this.seamBlendMode = SeamBlendMode.deghost,
    this.localTextureWarp = true,
    this.performance = const PerformanceOptions(),
    this.outputDirectory,
  });

  final AppLanguage language;
  final AppThemeMode themeMode;
  final AppAccent accent;
  final ExportFormat exportFormat;
  final bool refineGridNeighbors;
  final SeamBlendMode seamBlendMode;
  final bool localTextureWarp;
  final PerformanceOptions performance;

  /// Filesystem path on desktop or a platform document URI on Android.
  final String? outputDirectory;

  factory AppSettings.defaults({required bool mobile, bool android = false}) =>
      AppSettings(
        exportFormat: mobile && !android ? ExportFormat.png : ExportFormat.tiff,
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
    bool? refineGridNeighbors,
    SeamBlendMode? seamBlendMode,
    bool? localTextureWarp,
    PerformanceOptions? performance,
    String? outputDirectory,
    bool clearOutputDirectory = false,
  }) => AppSettings(
    language: language ?? this.language,
    themeMode: themeMode ?? this.themeMode,
    accent: accent ?? this.accent,
    exportFormat: exportFormat ?? this.exportFormat,
    refineGridNeighbors: refineGridNeighbors ?? this.refineGridNeighbors,
    seamBlendMode: seamBlendMode ?? this.seamBlendMode,
    localTextureWarp: localTextureWarp ?? this.localTextureWarp,
    performance: performance ?? this.performance,
    outputDirectory: clearOutputDirectory
        ? null
        : outputDirectory ?? this.outputDirectory,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'language': language.name,
    'themeMode': themeMode.name,
    'accent': accent.name,
    'exportFormat': exportFormat.name,
    'refineGridNeighbors': refineGridNeighbors,
    'seamBlendMode': seamBlendMode.name,
    'localTextureWarp': localTextureWarp,
    'performance': performance.toJson(),
    'outputDirectory': outputDirectory,
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
          : ExportFormat.tiff,
      refineGridNeighbors: json['refineGridNeighbors'] as bool? ?? true,
      seamBlendMode: json.containsKey('seamBlendMode')
          ? SeamBlendMode.fromSavedValue(json['seamBlendMode'])
          : SeamBlendMode.deghost,
      localTextureWarp: json['localTextureWarp'] as bool? ?? true,
      performance: PerformanceOptions.fromJson(
        (json['performance'] as Map?)?.cast<String, Object?>(),
      ),
      outputDirectory: json['outputDirectory'] as String?,
    );
  }

  static AppSettings decode(String value) =>
      AppSettings.fromJson((jsonDecode(value) as Map).cast<String, Object?>());
}
