import 'stitch_quality.dart';

enum BatchItemState {
  pending,
  needsSettings,
  needsApproval,
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
    this.progress = 0,
    this.etaSeconds,
    this.elapsedSeconds = 0,
    this.lastTickAt,
    this.progressOperation,
    this.progressSamples = const [],
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
  final double progress;
  final int? etaSeconds;
  final int elapsedSeconds;
  final DateTime? lastTickAt;
  final String? progressOperation;
  final List<ProgressSample> progressSamples;

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
    double? progress,
    int? etaSeconds,
    bool clearEtaSeconds = false,
    int? elapsedSeconds,
    DateTime? lastTickAt,
    bool clearLastTickAt = false,
    String? progressOperation,
    List<ProgressSample>? progressSamples,
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
    progress: progress ?? this.progress,
    etaSeconds: clearEtaSeconds ? null : etaSeconds ?? this.etaSeconds,
    elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
    lastTickAt: clearLastTickAt ? null : lastTickAt ?? this.lastTickAt,
    progressOperation: progressOperation ?? this.progressOperation,
    progressSamples: progressSamples ?? this.progressSamples,
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
    'progress': progress,
    'etaSeconds': etaSeconds,
    'elapsedSeconds': elapsedSeconds,
    'lastTickAt': lastTickAt?.toIso8601String(),
    'progressOperation': progressOperation,
    'progressSamples': progressSamples
        .map((sample) => sample.toJson())
        .toList(),
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
    this.outputFormat = ExportFormat.tiff,
  });

  final String id;
  final DateTime createdAt;
  final String parentDirectory;
  final String outputDirectory;
  final List<BatchQueueItem> items;
  final ExportFormat outputFormat;

  BatchQueue copyWith({
    List<BatchQueueItem>? items,
    ExportFormat? outputFormat,
  }) => BatchQueue(
    id: id,
    createdAt: createdAt,
    parentDirectory: parentDirectory,
    outputDirectory: outputDirectory,
    items: items ?? this.items,
    outputFormat: outputFormat ?? this.outputFormat,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'parentDirectory': parentDirectory,
    'outputDirectory': outputDirectory,
    'items': items.map((item) => item.toJson()).toList(),
    'outputFormat': outputFormat.name,
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
  );
}
