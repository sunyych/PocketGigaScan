import 'stitch_quality.dart';
import 'performance_options.dart';

enum BatchItemState {
  pending,
  needsSettings,
  needsApproval,
  needsFormatApproval,
  skipped,
  ready,
  running,
  exporting,
  paused,
  cancelled,
  failed,
  completed,
}

class BatchQueueItem {
  const BatchQueueItem({
    required this.id,
    required this.name,
    required this.sourceDirectory,
    required this.state,
    this.taskId,
    this.durableInputDirectory,
    this.message,
    this.estimatedLayout = false,
    this.pauseRequested = false,
    this.publishFailed = false,
    this.jpegScalingApproved = false,
    this.progress = 0,
    this.etaSeconds,
    this.elapsedSeconds = 0,
    this.lastTickAt,
    this.progressOperation,
    this.progressSamples = const [],
    this.usbSourceIdentity,
    this.usbSourceSignature,
    this.usbStableSince,
  });

  final String id;
  final String name;
  final String sourceDirectory;
  final BatchItemState state;
  final String? taskId;

  /// Task-owned input copy used to recover after temporary SAF staging is freed.
  final String? durableInputDirectory;
  final String? message;
  final bool estimatedLayout;
  final bool pauseRequested;

  /// True when the completed task's private export could not be published to
  /// the chosen folder and the operator can retry publishing from the queue.
  final bool publishFailed;
  final bool jpegScalingApproved;
  final double progress;
  final int? etaSeconds;
  final int elapsedSeconds;
  final DateTime? lastTickAt;
  final String? progressOperation;
  final List<ProgressSample> progressSamples;

  /// Stable volume and panorama-relative identity for removable-media imports.
  final String? usbSourceIdentity;
  final String? usbSourceSignature;
  final DateTime? usbStableSince;

  BatchQueueItem copyWith({
    String? sourceDirectory,
    BatchItemState? state,
    String? taskId,
    String? durableInputDirectory,
    bool clearDurableInputDirectory = false,
    String? message,
    bool clearMessage = false,
    bool? estimatedLayout,
    bool? pauseRequested,
    bool? publishFailed,
    bool? jpegScalingApproved,
    bool clearPublishFailed = false,
    double? progress,
    int? etaSeconds,
    bool clearEtaSeconds = false,
    int? elapsedSeconds,
    DateTime? lastTickAt,
    bool clearLastTickAt = false,
    String? progressOperation,
    List<ProgressSample>? progressSamples,
    String? usbSourceIdentity,
    String? usbSourceSignature,
    DateTime? usbStableSince,
    bool clearUsbStableSince = false,
  }) => BatchQueueItem(
    id: id,
    name: name,
    sourceDirectory: sourceDirectory ?? this.sourceDirectory,
    state: state ?? this.state,
    taskId: taskId ?? this.taskId,
    durableInputDirectory: clearDurableInputDirectory
        ? null
        : durableInputDirectory ?? this.durableInputDirectory,
    message: clearMessage ? null : message ?? this.message,
    estimatedLayout: estimatedLayout ?? this.estimatedLayout,
    pauseRequested: pauseRequested ?? this.pauseRequested,
    publishFailed: clearPublishFailed
        ? false
        : publishFailed ?? this.publishFailed,
    jpegScalingApproved: jpegScalingApproved ?? this.jpegScalingApproved,
    progress: progress ?? this.progress,
    etaSeconds: clearEtaSeconds ? null : etaSeconds ?? this.etaSeconds,
    elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
    lastTickAt: clearLastTickAt ? null : lastTickAt ?? this.lastTickAt,
    progressOperation: progressOperation ?? this.progressOperation,
    progressSamples: progressSamples ?? this.progressSamples,
    usbSourceIdentity: usbSourceIdentity ?? this.usbSourceIdentity,
    usbSourceSignature: usbSourceSignature ?? this.usbSourceSignature,
    usbStableSince: clearUsbStableSince
        ? null
        : usbStableSince ?? this.usbStableSince,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'sourceDirectory': sourceDirectory,
    'state': state.name,
    'taskId': taskId,
    'durableInputDirectory': durableInputDirectory,
    'message': message,
    'estimatedLayout': estimatedLayout,
    'pauseRequested': pauseRequested,
    'publishFailed': publishFailed,
    'jpegScalingApproved': jpegScalingApproved,
    'progress': progress,
    'etaSeconds': etaSeconds,
    'elapsedSeconds': elapsedSeconds,
    'lastTickAt': lastTickAt?.toIso8601String(),
    'progressOperation': progressOperation,
    'progressSamples': progressSamples
        .map((sample) => sample.toJson())
        .toList(),
    'usbSourceIdentity': usbSourceIdentity,
    'usbSourceSignature': usbSourceSignature,
    'usbStableSince': usbStableSince?.toIso8601String(),
  };

  factory BatchQueueItem.fromJson(Map<String, Object?> json) => BatchQueueItem(
    id: json['id']! as String,
    name: json['name']! as String,
    sourceDirectory: json['sourceDirectory']! as String,
    state: BatchItemState.values.firstWhere(
      (state) => state.name == json['state'],
      orElse: () => BatchItemState.failed,
    ),
    taskId: json['taskId'] as String?,
    durableInputDirectory: json['durableInputDirectory'] as String?,
    message: json['message'] as String?,
    estimatedLayout: json['estimatedLayout'] as bool? ?? false,
    pauseRequested: json['pauseRequested'] as bool? ?? false,
    publishFailed: json['publishFailed'] as bool? ?? false,
    jpegScalingApproved: json['jpegScalingApproved'] as bool? ?? false,
    progress: (json['progress'] as num? ?? 0).toDouble(),
    etaSeconds: json['etaSeconds'] as int?,
    elapsedSeconds: json['elapsedSeconds'] as int? ?? 0,
    lastTickAt: json['lastTickAt'] is String
        ? DateTime.tryParse(json['lastTickAt']! as String)
        : null,
    progressOperation: json['progressOperation'] as String?,
    progressSamples: (json['progressSamples'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(ProgressSample.fromJson)
        .toList(),
    usbSourceIdentity: json['usbSourceIdentity'] as String?,
    usbSourceSignature: json['usbSourceSignature'] as String?,
    usbStableSince: json['usbStableSince'] is String
        ? DateTime.tryParse(json['usbStableSince']! as String)
        : null,
  );
}

class ProgressSample {
  const ProgressSample(this.at, this.progress);
  final DateTime at;
  final double progress;
  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'progress': progress,
  };
  factory ProgressSample.fromJson(Map<String, Object?> json) => ProgressSample(
    DateTime.parse(json['at']! as String),
    (json['progress']! as num).toDouble(),
  );
}

class BatchQueue {
  const BatchQueue({
    required this.id,
    required this.createdAt,
    required this.parentDirectory,
    required this.outputDirectory,
    required this.items,
    this.outputFormat = ExportFormat.jpeg,
    this.started = true,
    this.exportDestination,
    this.performanceOptions = const PerformanceOptions(),
    this.refineGridNeighbors = true,
    this.seamBlendMode = SeamBlendMode.deghost,
    this.localTextureWarp = true,
    this.protectPeople = false,
    this.smoothWater = false,
    this.usbSource = false,
    this.usbVolumeId,
    this.deleteUsbSources = false,
  });

  final String id;
  final DateTime createdAt;
  final String parentDirectory;
  final String outputDirectory;
  final List<BatchQueueItem> items;
  final ExportFormat outputFormat;

  /// Whether this queue has been explicitly started by the operator.
  final bool started;

  /// Filesystem folder on desktop, persisted SAF tree URI on Android.
  final String? exportDestination;
  final PerformanceOptions performanceOptions;
  final bool refineGridNeighbors;
  final SeamBlendMode seamBlendMode;
  final bool localTextureWarp;
  final bool protectPeople;
  final bool smoothWater;
  final bool usbSource;
  final String? usbVolumeId;
  final bool deleteUsbSources;

  BatchQueue copyWith({
    String? parentDirectory,
    String? outputDirectory,
    List<BatchQueueItem>? items,
    ExportFormat? outputFormat,
    bool? started,
    String? exportDestination,
    PerformanceOptions? performanceOptions,
    bool? refineGridNeighbors,
    SeamBlendMode? seamBlendMode,
    bool? localTextureWarp,
    bool? protectPeople,
    bool? smoothWater,
    bool? usbSource,
    String? usbVolumeId,
    bool? deleteUsbSources,
  }) => BatchQueue(
    id: id,
    createdAt: createdAt,
    parentDirectory: parentDirectory ?? this.parentDirectory,
    outputDirectory: outputDirectory ?? this.outputDirectory,
    items: items ?? this.items,
    outputFormat: outputFormat ?? this.outputFormat,
    started: started ?? this.started,
    exportDestination: exportDestination ?? this.exportDestination,
    performanceOptions: performanceOptions ?? this.performanceOptions,
    refineGridNeighbors: refineGridNeighbors ?? this.refineGridNeighbors,
    seamBlendMode: seamBlendMode ?? this.seamBlendMode,
    localTextureWarp: localTextureWarp ?? this.localTextureWarp,
    protectPeople: protectPeople ?? this.protectPeople,
    smoothWater: smoothWater ?? this.smoothWater,
    usbSource: usbSource ?? this.usbSource,
    usbVolumeId: usbVolumeId ?? this.usbVolumeId,
    deleteUsbSources: deleteUsbSources ?? this.deleteUsbSources,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'parentDirectory': parentDirectory,
    'outputDirectory': outputDirectory,
    'items': items.map((item) => item.toJson()).toList(),
    'outputFormat': outputFormat.name,
    'started': started,
    'exportDestination': exportDestination,
    'performanceOptions': performanceOptions.toJson(),
    'refineGridNeighbors': refineGridNeighbors,
    'seamBlendMode': seamBlendMode.name,
    'localTextureWarp': localTextureWarp,
    'protectPeople': protectPeople,
    'smoothWater': smoothWater,
    'usbSource': usbSource,
    'usbVolumeId': usbVolumeId,
    'deleteUsbSources': deleteUsbSources,
  };

  factory BatchQueue.fromJson(Map<String, Object?> json) => BatchQueue(
    id: json['id']! as String,
    createdAt: DateTime.parse(json['createdAt']! as String),
    parentDirectory: json['parentDirectory']! as String,
    outputDirectory: json['outputDirectory']! as String,
    items: (json['items']! as List<Object?>)
        .whereType<Map<String, Object?>>()
        .map(BatchQueueItem.fromJson)
        .toList(),
    outputFormat: ExportFormat.fromSavedValue(json['outputFormat']),
    // Queues saved before the explicit start control were already auto-run.
    started: json['started'] as bool? ?? true,
    exportDestination: json['exportDestination'] as String?,
    performanceOptions: PerformanceOptions.fromJson(
      json['performanceOptions'] as Map<String, Object?>?,
    ),
    refineGridNeighbors: json['refineGridNeighbors'] as bool? ?? true,
    seamBlendMode: SeamBlendMode.values.firstWhere(
      (value) => value.name == json['seamBlendMode'],
      orElse: () => SeamBlendMode.deghost,
    ),
    localTextureWarp: json['localTextureWarp'] as bool? ?? true,
    protectPeople: json['protectPeople'] as bool? ?? false,
    smoothWater: json['smoothWater'] as bool? ?? false,
    usbSource: json['usbSource'] as bool? ?? false,
    usbVolumeId: json['usbVolumeId'] as String?,
    deleteUsbSources: json['deleteUsbSources'] as bool? ?? false,
  );
}
