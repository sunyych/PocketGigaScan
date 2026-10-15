import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const sceneModelId = 'upernet-convnext-tiny-ade20k-v1';
const sceneModelManifestAsset = 'assets/scene_model_manifest.json';

/// Whether scene inference can run on the supplied target platform.
bool supportsSceneInference({required bool isWindows, required bool isMacOS}) =>
    isWindows || isMacOS;

/// Resolve the bundled model location for the desktop application layout.
/// Windows stores data beside the executable. macOS stores resources inside
/// the app bundle at Contents/Resources.
String resolveSceneModelBundlePath({
  required String resolvedExecutable,
  required bool isMacOS,
  required String fileName,
}) {
  final path = isMacOS ? p.posix : p.windows;
  final executableDirectory = path.dirname(resolvedExecutable);
  return isMacOS
      ? path.normalize(
          path.join(
            path.dirname(executableDirectory),
            'Resources',
            'models',
            fileName,
          ),
        )
      : path.join(executableDirectory, 'data', 'models', fileName);
}

bool get supportsSceneInferenceOnCurrentPlatform => supportsSceneInference(
  isWindows: Platform.isWindows,
  isMacOS: Platform.isMacOS,
);

class SceneModelManifest {
  const SceneModelManifest({
    required this.schemaVersion,
    required this.modelId,
    required this.sha256,
    required this.sizeBytes,
    required this.bundlePath,
    required this.fileName,
  });

  final int schemaVersion;
  final String modelId;
  final String? sha256;
  final int? sizeBytes;
  final String bundlePath;
  final String fileName;

  factory SceneModelManifest.fromJson(Map<String, Object?> json) =>
      SceneModelManifest(
        schemaVersion: json['schemaVersion'] as int? ?? 0,
        modelId: json['modelId'] as String? ?? '',
        sha256: json['modelSha256'] as String?,
        sizeBytes: json['sizeBytes'] as int?,
        bundlePath: json['bundlePath'] as String? ?? '',
        fileName: json['fileName'] as String? ?? '',
      );

  String? get unavailableReason {
    if (schemaVersion != 1 || modelId != sceneModelId) {
      return 'Scene model manifest is invalid.';
    }
    if (sha256 == null || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sha256!)) {
      return 'Scene model is unavailable: its verified SHA-256 is not configured.';
    }
    if (sizeBytes == null || sizeBytes! <= 0) {
      return 'Scene model is unavailable: its verified file size is not configured.';
    }
    if (!const {
          'data/models/scene-model-v1.onnx',
          '../Resources/models/scene-model-v1.onnx',
        }.contains(bundlePath) ||
        fileName != 'scene-model-v1.onnx') {
      return 'Scene model manifest has an invalid bundled model path.';
    }
    return null;
  }
}

class SceneModelMetadata {
  const SceneModelMetadata({
    required this.modelPath,
    required this.sha256,
    required this.cacheDirectory,
  });

  final String modelPath;
  final String sha256;
  final String cacheDirectory;
}

class SceneModelProgress {
  const SceneModelProgress(this.receivedBytes, this.totalBytes);
  final int receivedBytes;
  final int totalBytes;
  double get fraction => totalBytes <= 0
      ? 0
      : (receivedBytes / totalBytes).clamp(0.0, 1.0).toDouble();
}

class SceneModelCancelled implements Exception {
  const SceneModelCancelled();
  @override
  String toString() => 'Scene model preparation cancelled.';
}

abstract interface class SceneModelBundleSource {
  Future<SceneModelSourceResponse> open();
}

abstract interface class SceneModelSourceResponse {
  int? get totalBytes;
  Stream<List<int>> get bytes;
}

abstract interface class SceneModelFileSystem {
  Future<bool> exists(String path);
  Future<int> length(String path);
  Future<String> sha256File(String path);
  Future<void> createDirectory(String path);
  Future<void> append(String path, List<int> bytes);
  Future<void> delete(String path);
  Future<void> rename(String source, String destination);
}

class FileSceneModelBundleSource implements SceneModelBundleSource {
  const FileSceneModelBundleSource(this.path);
  final String path;
  @override
  Future<SceneModelSourceResponse> open() async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('Bundled scene model is missing.', path);
    }
    return _FileSceneModelSourceResponse(await file.length(), file.openRead());
  }
}

class _FileSceneModelSourceResponse implements SceneModelSourceResponse {
  const _FileSceneModelSourceResponse(this.totalBytes, this.bytes);
  @override
  final int totalBytes;
  @override
  final Stream<List<int>> bytes;
}

class IoSceneModelFileSystem implements SceneModelFileSystem {
  @override
  Future<bool> exists(String path) => File(path).exists();
  @override
  Future<int> length(String path) => File(path).length();
  @override
  Future<String> sha256File(String path) async =>
      (await sha256.bind(File(path).openRead()).first).toString();
  @override
  Future<void> createDirectory(String path) async {
    await Directory(path).create(recursive: true);
  }

  @override
  Future<void> append(String path, List<int> bytes) async {
    await File(path).open(mode: FileMode.append).then((file) async {
      await file.writeFrom(bytes);
      await file.flush();
      await file.close();
    });
  }

  @override
  Future<void> delete(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> rename(String source, String destination) async {
    await File(source).rename(destination);
  }
}

class SceneModelService {
  SceneModelService({
    required this.manifest,
    required this.cacheRootPath,
    SceneModelBundleSource? bundleSource,
    SceneModelFileSystem? fileSystem,
  }) : _bundleSource =
           bundleSource ??
           FileSceneModelBundleSource(
             resolveSceneModelBundlePath(
               resolvedExecutable: Platform.resolvedExecutable,
               isMacOS: Platform.isMacOS,
               fileName: manifest.fileName,
             ),
           ),
       _fileSystem = fileSystem ?? IoSceneModelFileSystem();

  final SceneModelManifest manifest;
  final Future<String> Function() cacheRootPath;
  final SceneModelBundleSource _bundleSource;
  final SceneModelFileSystem _fileSystem;
  bool _active = false;
  Future<SceneModelMetadata>? _pendingPreparation;
  Completer<void>? _cancelSignal;

  bool get isPreparing => _active;

  void cancelPreparation() {
    final signal = _cancelSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  Future<String> _modelDirectory() async =>
      p.join(await cacheRootPath(), 'scene-models', manifest.modelId);

  Future<SceneModelMetadata?> cachedMetadata() async {
    if (manifest.unavailableReason != null) return null;
    final directory = await _modelDirectory();
    final modelPath = p.join(directory, manifest.fileName);
    if (!await _isVerified(modelPath)) return null;
    await _fileSystem.createDirectory(
      p.join(await cacheRootPath(), 'scene-cache', manifest.modelId),
    );
    return _metadata(modelPath, directory);
  }

  Future<SceneModelMetadata> ensureReady({
    bool Function()? isCancelled,
    void Function(SceneModelProgress progress)? onProgress,
  }) {
    final pending = _pendingPreparation;
    if (pending != null) return pending;
    late final Future<SceneModelMetadata> operation;
    operation = _prepare(isCancelled: isCancelled, onProgress: onProgress)
        .whenComplete(() {
          if (identical(_pendingPreparation, operation)) {
            _pendingPreparation = null;
          }
        });
    _pendingPreparation = operation;
    return operation;
  }

  Future<SceneModelMetadata> _prepare({
    bool Function()? isCancelled,
    void Function(SceneModelProgress progress)? onProgress,
  }) async {
    final unavailable = manifest.unavailableReason;
    if (unavailable != null) throw StateError(unavailable);
    final directory = await _modelDirectory();
    final modelPath = p.join(directory, manifest.fileName);
    if (await _isVerified(modelPath)) {
      await _fileSystem.createDirectory(
        p.join(await cacheRootPath(), 'scene-cache', manifest.modelId),
      );
      return _metadata(modelPath, directory);
    }
    if (_active) throw StateError('Scene model preparation is already active.');
    _active = true;
    final cancellation = Completer<void>();
    _cancelSignal = cancellation;
    final partPath = '$modelPath.part';
    var success = false;
    try {
      await _fileSystem.createDirectory(directory);
      await _fileSystem.delete(partPath);
      final response = await _bundleSource.open();
      var bytesReceived = 0;
      final iterator = StreamIterator<List<int>>(response.bytes);
      try {
        while (true) {
          final hasNext = await Future.any<bool>([
            iterator.moveNext(),
            cancellation.future.then((_) => false),
          ]);
          if (!hasNext) {
            if (cancellation.isCompleted || (isCancelled?.call() ?? false)) {
              throw const SceneModelCancelled();
            }
            break;
          }
          if (isCancelled?.call() ?? false) throw const SceneModelCancelled();
          final chunk = iterator.current;
          bytesReceived += chunk.length;
          await _fileSystem.append(partPath, chunk);
          onProgress?.call(
            SceneModelProgress(
              bytesReceived,
              manifest.sizeBytes ?? response.totalBytes ?? 0,
            ),
          );
        }
      } finally {
        await iterator.cancel();
      }
      if (isCancelled?.call() ?? false) throw const SceneModelCancelled();
      if (bytesReceived != manifest.sizeBytes) {
        throw StateError(
          'Scene model size mismatch: expected ${manifest.sizeBytes} bytes, received $bytesReceived.',
        );
      }
      final actualHash = await _fileSystem.sha256File(partPath);
      if (actualHash.toLowerCase() != manifest.sha256!.toLowerCase()) {
        throw StateError('Scene model SHA-256 verification failed.');
      }
      final sceneCachePath = p.join(
        await cacheRootPath(),
        'scene-cache',
        manifest.modelId,
      );
      await _fileSystem.createDirectory(sceneCachePath);
      await _fileSystem.delete(modelPath);
      await _fileSystem.rename(partPath, modelPath);
      success = true;
      return _metadata(modelPath, directory);
    } finally {
      _active = false;
      if (identical(_cancelSignal, cancellation)) _cancelSignal = null;
      if (!success) await _fileSystem.delete(partPath);
    }
  }

  Future<bool> _isVerified(String path) async {
    if (await _fileSystem.exists(path) != true) return false;
    if (manifest.sizeBytes == null || manifest.sha256 == null) return false;
    if (await _fileSystem.length(path) != manifest.sizeBytes) return false;
    return (await _fileSystem.sha256File(path)).toLowerCase() ==
        manifest.sha256!.toLowerCase();
  }

  SceneModelMetadata _metadata(String path, String directory) =>
      SceneModelMetadata(
        modelPath: path,
        sha256: manifest.sha256!.toLowerCase(),
        cacheDirectory: p.normalize(
          p.join(directory, '..', '..', 'scene-cache', manifest.modelId),
        ),
      );

  Future<void> deleteCachedModel({required bool activeTasks}) async {
    if (activeTasks) {
      throw StateError('Cannot remove the scene model while a task is active.');
    }
    if (_active || _pendingPreparation != null) {
      throw StateError('Cannot remove the scene model during preparation.');
    }
    final directory = await _modelDirectory();
    await _fileSystem.delete(p.join(directory, manifest.fileName));
    await _fileSystem.delete('${p.join(directory, manifest.fileName)}.part');
  }
}

Future<SceneModelManifest> loadSceneModelManifest() async =>
    SceneModelManifest.fromJson(
      (jsonDecode(await rootBundle.loadString(sceneModelManifestAsset)) as Map)
          .cast<String, Object?>(),
    );

Future<SceneModelService> createDefaultSceneModelService() async {
  final manifest = await loadSceneModelManifest();
  return SceneModelService(
    manifest: manifest,
    bundleSource: FileSceneModelBundleSource(
      resolveSceneModelBundlePath(
        resolvedExecutable: Platform.resolvedExecutable,
        isMacOS: Platform.isMacOS,
        fileName: manifest.fileName,
      ),
    ),
    cacheRootPath: () async => (await getApplicationSupportDirectory()).path,
  );
}
