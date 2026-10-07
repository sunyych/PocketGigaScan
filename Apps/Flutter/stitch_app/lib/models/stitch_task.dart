import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'grid_options.dart';
import 'imported_photo.dart';
import 'performance_options.dart';
import 'stitch_quality.dart';
import 'export_fingerprint.dart';
import 'stitch_timeline.dart';

enum StitchPhase {
  imported,
  queued,
  running,
  pausing,
  paused,
  interrupted,
  exporting,
  completed,
  cancelled,
  failed,
}

class StitchTask {
  const StitchTask({
    required this.id,
    required this.createdAt,
    required this.sourceDirectory,
    required this.outputDirectory,
    required this.photos,
    required this.grid,
    required this.horizontalFovDegrees,
    required this.memoryBudgetMiB,
    required this.workers,
    required this.phase,
    this.forceGridFallback = false,
    this.autoGridOverlap = true,
    this.gridHorizontalOverlap = 0.3,
    this.gridVerticalOverlap = 0.3,
    this.cameraProfileId,
    this.cameraCalibrationOverridden = false,
    this.nativeJobId,
    this.stage = 'ready',
    this.progress = 0,
    this.error,
    this.pauseReason,
    this.centralReference,
    this.exportPath,
    this.performanceOptions = const PerformanceOptions(),
    this.exportFormat = ExportFormat.png,
    this.autoExportOnCompletion = false,
    this.refineGridNeighbors = false,
    this.seamBlendMode = SeamBlendMode.feather,
    this.localTextureWarp = true,
    this.resultStats,
    this.exportFingerprint,
    this.exportCheckpointPath,
    this.largeJobApprovalScope,
    this.timeline = const StitchTimeline(),
    this.exportDirectory,
    this.publishedExportPath,
    this.publishError,
  });

  final String id;
  final DateTime createdAt;
  final String sourceDirectory;
  final String outputDirectory;
  final List<ImportedPhoto> photos;
  final GridOptions grid;
  final double horizontalFovDegrees;
  final int memoryBudgetMiB;
  final int workers;
  final StitchPhase phase;
  final bool forceGridFallback;
  final bool autoGridOverlap;
  final double gridHorizontalOverlap;
  final double gridVerticalOverlap;
  final String? cameraProfileId;
  final bool cameraCalibrationOverridden;
  final String? nativeJobId;
  final String stage;
  final double progress;
  final String? error;
  final String? pauseReason;
  final GridCell? centralReference;
  final String? exportPath;
  final PerformanceOptions performanceOptions;
  final ExportFormat exportFormat;
  final bool autoExportOnCompletion;
  final bool refineGridNeighbors;
  final SeamBlendMode seamBlendMode;
  final bool localTextureWarp;
  final Map<String, Object?>? resultStats;
  final ExportFileFingerprint? exportFingerprint;
  final String? exportCheckpointPath;

  /// Approval is bound to this task identity, the current grid and photo bytes.
  final String? largeJobApprovalScope;
  final StitchTimeline timeline;
  final String? exportDirectory;
  final String? publishedExportPath;
  final String? publishError;

  bool get needsLargeJobConfirmation =>
      grid.rows > 6 || grid.columns > 6 || photos.length > 36;

  String get currentLargeJobApprovalScope {
    final forced = grid.forceGridCells.toList()
      ..sort(
        (a, b) => a.row != b.row
            ? a.row.compareTo(b.row)
            : a.column.compareTo(b.column),
      );
    final canonical = jsonEncode({
      'taskId': id,
      'jobPath': outputDirectory,
      'rows': grid.rows,
      'columns': grid.columns,
      'mode': grid.mode.name,
      'axis': grid.axis.name,
      'startCorner': grid.startCorner.name,
      'serpentine': grid.serpentine,
      'forced': forced.map((cell) => [cell.row, cell.column]).toList(),
      'photos': photos
          .map(
            (photo) => {
              'path': photo.storedPath,
              'sha256': photo.sha256,
              'width': photo.width,
              'height': photo.height,
              'order': photo.originalOrder,
            },
          )
          .toList(),
    });
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  bool get hasCurrentLargeJobApproval =>
      !needsLargeJobConfirmation ||
      largeJobApprovalScope == currentLargeJobApprovalScope;

  StitchTask copyWith({
    List<ImportedPhoto>? photos,
    GridOptions? grid,
    double? horizontalFovDegrees,
    int? memoryBudgetMiB,
    int? workers,
    StitchPhase? phase,
    bool? forceGridFallback,
    bool? autoGridOverlap,
    double? gridHorizontalOverlap,
    double? gridVerticalOverlap,
    String? cameraProfileId,
    bool clearCameraProfileId = false,
    bool? cameraCalibrationOverridden,
    String? nativeJobId,
    bool clearNativeJobId = false,
    String? stage,
    double? progress,
    String? error,
    bool clearError = false,
    String? pauseReason,
    bool clearPauseReason = false,
    GridCell? centralReference,
    bool clearCentralReference = false,
    String? exportPath,
    PerformanceOptions? performanceOptions,
    ExportFormat? exportFormat,
    bool? autoExportOnCompletion,
    bool? refineGridNeighbors,
    SeamBlendMode? seamBlendMode,
    bool? localTextureWarp,
    Map<String, Object?>? resultStats,
    ExportFileFingerprint? exportFingerprint,
    bool clearExportFingerprint = false,
    String? exportCheckpointPath,
    bool clearExportCheckpointPath = false,
    String? largeJobApprovalScope,
    bool clearLargeJobApprovalScope = false,
    StitchTimeline? timeline,
    String? exportDirectory,
    bool clearExportDirectory = false,
    String? publishedExportPath,
    bool clearPublishedExportPath = false,
    String? publishError,
    bool clearPublishError = false,
  }) => StitchTask(
    id: id,
    createdAt: createdAt,
    sourceDirectory: sourceDirectory,
    outputDirectory: outputDirectory,
    photos: photos ?? this.photos,
    grid: grid ?? this.grid,
    horizontalFovDegrees: horizontalFovDegrees ?? this.horizontalFovDegrees,
    memoryBudgetMiB: memoryBudgetMiB ?? this.memoryBudgetMiB,
    workers: workers ?? this.workers,
    phase: phase ?? this.phase,
    forceGridFallback: forceGridFallback ?? this.forceGridFallback,
    autoGridOverlap: autoGridOverlap ?? this.autoGridOverlap,
    gridHorizontalOverlap: gridHorizontalOverlap ?? this.gridHorizontalOverlap,
    gridVerticalOverlap: gridVerticalOverlap ?? this.gridVerticalOverlap,
    cameraProfileId: clearCameraProfileId
        ? null
        : cameraProfileId ?? this.cameraProfileId,
    cameraCalibrationOverridden:
        cameraCalibrationOverridden ?? this.cameraCalibrationOverridden,
    nativeJobId: clearNativeJobId ? null : nativeJobId ?? this.nativeJobId,
    stage: stage ?? this.stage,
    progress: progress ?? this.progress,
    error: clearError ? null : error ?? this.error,
    pauseReason: clearPauseReason ? null : pauseReason ?? this.pauseReason,
    centralReference: clearCentralReference
        ? null
        : centralReference ?? this.centralReference,
    exportPath: exportPath ?? this.exportPath,
    performanceOptions: performanceOptions ?? this.performanceOptions,
    exportFormat: exportFormat ?? this.exportFormat,
    autoExportOnCompletion:
        autoExportOnCompletion ?? this.autoExportOnCompletion,
    refineGridNeighbors: refineGridNeighbors ?? this.refineGridNeighbors,
    seamBlendMode: seamBlendMode ?? this.seamBlendMode,
    localTextureWarp: localTextureWarp ?? this.localTextureWarp,
    resultStats: resultStats ?? this.resultStats,
    exportFingerprint: clearExportFingerprint
        ? null
        : exportFingerprint ?? this.exportFingerprint,
    exportCheckpointPath: clearExportCheckpointPath
        ? null
        : exportCheckpointPath ?? this.exportCheckpointPath,
    largeJobApprovalScope: clearLargeJobApprovalScope
        ? null
        : largeJobApprovalScope ?? this.largeJobApprovalScope,
    timeline: timeline ?? this.timeline,
    exportDirectory: clearExportDirectory
        ? null
        : exportDirectory ?? this.exportDirectory,
    publishedExportPath: clearPublishedExportPath
        ? null
        : publishedExportPath ?? this.publishedExportPath,
    publishError: clearPublishError ? null : publishError ?? this.publishError,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'sourceDirectory': sourceDirectory,
    'outputDirectory': outputDirectory,
    'photos': photos.map((photo) => photo.toJson()).toList(),
    'grid': grid.toJson(),
    'horizontalFovDegrees': horizontalFovDegrees,
    'memoryBudgetMiB': memoryBudgetMiB,
    'workers': workers,
    'phase': phase.name,
    'forceGridFallback': forceGridFallback,
    'autoGridOverlap': autoGridOverlap,
    'gridHorizontalOverlap': gridHorizontalOverlap,
    'gridVerticalOverlap': gridVerticalOverlap,
    'cameraProfileId': cameraProfileId,
    'cameraCalibrationOverridden': cameraCalibrationOverridden,
    'nativeJobId': nativeJobId,
    'stage': stage,
    'progress': progress,
    'error': error,
    'pauseReason': pauseReason,
    'centralReference': centralReference == null
        ? null
        : {'row': centralReference!.row, 'column': centralReference!.column},
    'exportPath': exportPath,
    'performanceOptions': performanceOptions.toJson(),
    'exportFormat': exportFormat.name,
    'autoExportOnCompletion': autoExportOnCompletion,
    'refineGridNeighbors': refineGridNeighbors,
    'seamBlendMode': seamBlendMode.name,
    'localTextureWarp': localTextureWarp,
    'resultStats': resultStats,
    'exportFingerprint': exportFingerprint?.toJson(),
    'exportCheckpointPath': exportCheckpointPath,
    'largeJobApprovalScope': largeJobApprovalScope,
    'timeline': timeline.toJson(),
    'exportDirectory': exportDirectory,
    'publishedExportPath': publishedExportPath,
    'publishError': publishError,
  };

  factory StitchTask.fromJson(Map<String, Object?> json) {
    final gridJson = json['grid'] as Map<String, Object?>? ?? const {};
    final photos = (json['photos']! as List<Object?>)
        .map((photo) => ImportedPhoto.fromJson(photo as Map<String, Object?>))
        .toList();
    final grid = GridOptions.fromJson(gridJson, photos: photos);
    final savedPhase = StitchPhase.values.firstWhere(
      (phase) => phase.name == json['phase'],
      orElse: () => StitchPhase.imported,
    );
    final phase = switch (savedPhase) {
      StitchPhase.queued ||
      StitchPhase.running ||
      StitchPhase.pausing ||
      StitchPhase.exporting => StitchPhase.interrupted,
      _ => savedPhase,
    };
    final savedStage = json['stage'] as String? ?? 'ready';
    final savedExportPath = json['exportPath'] as String?;
    final legacyExportCheckpoint =
        json['exportCheckpointPath'] as String? ??
        (savedStage == 'export' &&
                (savedPhase == StitchPhase.exporting ||
                    savedPhase == StitchPhase.interrupted)
            ? savedExportPath
            : null);
    final ref = json['centralReference'] as Map<String, Object?>?;
    return StitchTask(
      id: json['id']! as String,
      createdAt: DateTime.parse(json['createdAt']! as String),
      sourceDirectory: json['sourceDirectory']! as String,
      outputDirectory: json['outputDirectory']! as String,
      photos: photos,
      grid: grid,
      horizontalFovDegrees: (json['horizontalFovDegrees'] as num? ?? 45)
          .toDouble(),
      memoryBudgetMiB: json['memoryBudgetMiB'] as int? ?? 128,
      workers: json['workers'] as int? ?? 2,
      phase: phase,
      forceGridFallback: json['forceGridFallback'] as bool? ?? false,
      autoGridOverlap:
          json['autoGridOverlap'] as bool? ?? json['nativeJobId'] == null,
      gridHorizontalOverlap: (json['gridHorizontalOverlap'] as num? ?? 0.3)
          .toDouble(),
      gridVerticalOverlap: (json['gridVerticalOverlap'] as num? ?? 0.3)
          .toDouble(),
      cameraProfileId: json['cameraProfileId'] as String?,
      cameraCalibrationOverridden:
          json['cameraCalibrationOverridden'] as bool? ?? false,
      nativeJobId: json['nativeJobId'] as String?,
      stage: savedStage,
      progress: (json['progress'] as num? ?? 0).toDouble(),
      error: json['error'] as String?,
      pauseReason: json['pauseReason'] as String?,
      centralReference: ref == null
          ? null
          : GridCell(ref['row']! as int, ref['column']! as int),
      exportPath: legacyExportCheckpoint == savedExportPath
          ? null
          : savedExportPath,
      performanceOptions: PerformanceOptions.fromJson(
        json['performanceOptions'] as Map<String, Object?>?,
      ),
      exportFormat: ExportFormat.fromSavedValue(json['exportFormat']),
      autoExportOnCompletion: json['autoExportOnCompletion'] as bool? ?? false,
      refineGridNeighbors: json['refineGridNeighbors'] as bool? ?? false,
      seamBlendMode: SeamBlendMode.fromSavedValue(json['seamBlendMode']),
      localTextureWarp: json['localTextureWarp'] as bool? ?? true,
      resultStats: json['resultStats'] as Map<String, Object?>?,
      exportFingerprint: json['exportFingerprint'] is Map<String, Object?>
          ? ExportFileFingerprint.fromJson(
              json['exportFingerprint']! as Map<String, Object?>,
            )
          : null,
      exportCheckpointPath: legacyExportCheckpoint,
      largeJobApprovalScope: json['largeJobApprovalScope'] as String?,
      timeline: StitchTimeline.fromJson(
        json['timeline'] as Map<String, Object?>?,
      ),
      exportDirectory: json['exportDirectory'] as String?,
      publishedExportPath: json['publishedExportPath'] as String?,
      publishError: json['publishError'] as String?,
    );
  }
}
