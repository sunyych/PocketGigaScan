import 'dart:async';

import 'package:flutter/services.dart';

class MobileResourceBudget {
  const MobileResourceBudget({
    required this.totalMemoryMiB,
    required this.availableMemoryMiB,
    required this.cpuCount,
    required this.availableStorageMiB,
    required this.thermalStatus,
    bool readingsValid = true,
  }) : _hasValidReadings = readingsValid;

  final int totalMemoryMiB;
  final int availableMemoryMiB;
  final int cpuCount;
  final int availableStorageMiB;
  final String thermalStatus;
  final bool _hasValidReadings;

  /// Conservative process-wide values accepted by the native resource API.
  /// These are recommendations; callers may lower them for a particular job.
  int get recommendedTotalMemoryBudgetMiB => _hasValidReadings
      ? (availableMemoryMiB ~/ 3).clamp(128, 128 * 1024).toInt()
      : 128;

  int get recommendedTotalCpuWorkers =>
      _hasValidReadings ? (cpuCount ~/ 2).clamp(1, 32).toInt() : 1;

  int get recommendedMaxConcurrentJobs {
    if (!_hasValidReadings) return 1;
    final cpuLimit = recommendedTotalCpuWorkers;
    final memoryLimit = recommendedTotalMemoryBudgetMiB ~/ 128;
    return (cpuLimit < memoryLimit ? cpuLimit : memoryLimit)
        .clamp(1, 8)
        .toInt();
  }

  /// Avoid admitting new jobs once Android reports moderate or worse heat.
  bool get shouldDeferNewStarts => const {
    'moderate',
    'severe',
    'critical',
    'emergency',
    'shutdown',
  }.contains(thermalStatus.toLowerCase());

  bool get isStorageConstrained =>
      !_hasValidReadings || availableStorageMiB < 512;

  factory MobileResourceBudget.fromMap(Map<Object?, Object?> values) {
    final totalMemory = _integer(values['totalMemoryMiB']);
    final availableMemory = _integer(values['availableMemoryMiB']);
    final cpus = _integer(values['cpuCount']);
    final storage = _integer(values['availableStorageMiB']);
    final thermal = values['thermalStatus'];
    final valid =
        totalMemory > 0 &&
        availableMemory > 0 &&
        availableMemory <= totalMemory &&
        cpus > 0 &&
        storage >= 0 &&
        thermal is String;
    return MobileResourceBudget(
      totalMemoryMiB: totalMemory,
      availableMemoryMiB: availableMemory,
      cpuCount: cpus,
      availableStorageMiB: storage,
      thermalStatus: thermal is String ? thermal : 'unknown',
      readingsValid: valid,
    );
  }

  static int _integer(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }
    return 0;
  }
}

/// Reads current Android resource headroom and manages the render foreground service.
class MobileRuntimeService {
  MobileRuntimeService({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('com.lumiaiq.pocketgigascan/runtime') {
    attachTimeoutHandler();
  }

  final MethodChannel _channel;
  final StreamController<List<String>> _timeoutRequests =
      StreamController<List<String>>.broadcast();

  Future<MobileResourceBudget> readResourceBudget() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'readResourceBudget',
    );
    if (result == null) throw const FormatException('Resource data was empty');
    return MobileResourceBudget.fromMap(result);
  }

  /// Reads timeout pause requests persisted by Android; reading never consumes them.
  Future<List<String>> readPendingTimeoutJobs() async {
    final result = await _channel.invokeListMethod<Object?>(
      'readPendingTimeoutJobs',
    );
    return result?.whereType<String>().toList(growable: false) ?? const [];
  }

  /// Acknowledges only job IDs the caller has safely processed.
  Future<bool> acknowledgeTimeoutJobs(Iterable<String> jobIds) async {
    try {
      return await _channel.invokeMethod<bool>('acknowledgeTimeoutJobs', {
            'jobIds': jobIds.toList(growable: false),
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Starts/stops the data-sync foreground service while a render is active.
  /// Returns false only if Android could not start or stop the service.
  Future<bool> setProcessingActive(bool active, {String? jobId}) async {
    try {
      return await _channel.invokeMethod<bool>('setProcessingActive', {
            'active': active,
            'jobId': ?jobId,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Emits all active job ids when Android's foreground-service time limit is reached.
  Stream<List<String>> get timeoutRequests => _timeoutRequests.stream;

  /// Installs the native timeout event handler on this shared channel.
  void attachTimeoutHandler() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'processingTimeout') {
        final ids = call.arguments is List
            ? (call.arguments as List).whereType<String>().toList(
                growable: false,
              )
            : const <String>[];
        _timeoutRequests.add(ids);
      }
    });
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _timeoutRequests.close();
  }
}
