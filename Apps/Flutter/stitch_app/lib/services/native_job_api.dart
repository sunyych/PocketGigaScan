import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

const nativeAbiVersion = 1;

class NativeJobException implements Exception {
  const NativeJobException(this.message, {this.code = 'NATIVE_ERROR'});
  final String message;
  final String code;
  @override
  String toString() => '$code: $message';
}

abstract interface class JobApi {
  bool get isAvailable;
  String? get unavailableReason;
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  });
  Future<Map<String, Object?>> status(String jobId);
  Future<Map<String, Object?>> pause(String jobId);
  Future<Map<String, Object?>> resume(String jobId);
  Future<Map<String, Object?>> cancel(String jobId);
  Future<Map<String, Object?>> export(String jobId, String destination);
  Future<Map<String, Object?>> capabilities();
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  });
}

typedef _AbiNative = ffi.Uint32 Function();
typedef _AbiDart = int Function();
typedef _JobNative = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
typedef _JobDart = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _FreeDart = void Function(ffi.Pointer<ffi.Void>);

class NativeJobApi implements JobApi {
  NativeJobApi({ffi.DynamicLibrary? library}) {
    try {
      final loaded = library ?? _openLibrary();
      final abi = loaded.lookupFunction<_AbiNative, _AbiDart>(
        'lumia_gigascan_abi_version',
      );
      final job = loaded.lookupFunction<_JobNative, _JobDart>(
        'lumia_gigascan_job_json',
      );
      final free = loaded.lookupFunction<_FreeNative, _FreeDart>(
        'lumia_gigascan_free',
      );
      _job = job;
      _free = free;
      final version = abi();
      if (version != nativeAbiVersion) {
        _reason = '不兼容的原生核心 ABI：$version（需要 $nativeAbiVersion）';
      }
    } on Object catch (error) {
      _reason = '本地合成核心不可用：$error';
    }
  }

  _JobDart? _job;
  _FreeDart? _free;
  String? _reason;

  @override
  bool get isAvailable => _reason == null && _job != null && _free != null;
  @override
  String? get unavailableReason => _reason;

  ffi.DynamicLibrary _openLibrary() {
    if (Platform.isIOS) return ffi.DynamicLibrary.process();
    if (Platform.isAndroid) {
      return ffi.DynamicLibrary.open('liblumia_gigascan_core.so');
    }
    final name = Platform.isWindows
        ? 'lumia_gigascan_core.dll'
        : Platform.isMacOS
        ? 'liblumia_gigascan_core.dylib'
        : 'liblumia_gigascan_core.so';
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      '$executableDirectory${Platform.pathSeparator}$name',
      if (Platform.isMacOS) '$executableDirectory/../Frameworks/$name',
    ];
    Object? lastError;
    for (final candidate in candidates) {
      try {
        return ffi.DynamicLibrary.open(candidate);
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw NativeJobException(
      '未找到原生库 $name：$lastError',
      code: 'NATIVE_UNAVAILABLE',
    );
  }

  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) => _invoke({
    'command': 'start',
    'request': request,
    'outputDir': outputDirectory,
    'memoryBudgetMiB': memoryBudgetMiB,
    'workers': workers,
  });
  @override
  Future<Map<String, Object?>> status(String jobId) =>
      _invoke({'command': 'status', 'jobId': jobId});
  @override
  Future<Map<String, Object?>> pause(String jobId) =>
      _invoke({'command': 'pause', 'jobId': jobId});
  @override
  Future<Map<String, Object?>> resume(String jobId) =>
      _invoke({'command': 'resume', 'jobId': jobId});
  @override
  Future<Map<String, Object?>> cancel(String jobId) =>
      _invoke({'command': 'cancel', 'jobId': jobId});
  @override
  Future<Map<String, Object?>> export(String jobId, String destination) =>
      _invoke({
        'command': 'export',
        'jobId': jobId,
        'destination': destination,
      });
  @override
  Future<Map<String, Object?>> capabilities() =>
      _invoke({'command': 'capabilities'});
  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) => _invoke({
    'command': 'configureResources',
    'totalCpuWorkers': totalCpuWorkers,
    'totalMemoryBudgetMiB': totalMemoryBudgetMiB,
    'maxConcurrentJobs': maxConcurrentJobs,
  });

  Future<Map<String, Object?>> _invoke(Map<String, Object?> command) async {
    final job = _job;
    final free = _free;
    if (!isAvailable || job == null || free == null) {
      throw NativeJobException(
        unavailableReason ?? '原生合成核心不可用',
        code: 'NATIVE_UNAVAILABLE',
      );
    }
    final encoded = jsonEncode(command).toNativeUtf8();
    try {
      final responsePointer = job(encoded);
      if (responsePointer == ffi.nullptr) {
        throw const NativeJobException('原生核心返回空响应');
      }
      try {
        final decoded = jsonDecode(responsePointer.toDartString());
        if (decoded is! Map<String, Object?>) {
          throw const NativeJobException('原生响应不是 JSON 对象');
        }
        if (decoded['ok'] != true) {
          final error = decoded['error'];
          final details = error is Map<String, Object?>
              ? error
              : const <String, Object?>{};
          throw NativeJobException(
            details['message'] as String? ?? '本地处理失败',
            code: details['code'] as String? ?? 'NATIVE_ERROR',
          );
        }
        return decoded;
      } finally {
        free(responsePointer.cast<ffi.Void>());
      }
    } on NativeJobException {
      rethrow;
    } on Object catch (error) {
      throw NativeJobException('调用原生合成核心失败：$error');
    } finally {
      malloc.free(encoded);
    }
  }
}
