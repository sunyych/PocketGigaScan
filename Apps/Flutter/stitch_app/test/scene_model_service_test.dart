import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/services/scene_model_service.dart';

void main() {
  const bytes = <int>[1, 2, 3, 4, 5, 6];
  final digest = sha256.convert(bytes).toString();
  final manifest = SceneModelManifest(
    schemaVersion: 1,
    modelId: sceneModelId,
    sha256: digest,
    sizeBytes: bytes.length,
    bundlePath: 'data/models/scene-model-v1.onnx',
    fileName: 'scene-model-v1.onnx',
  );

  test(
    'prepares and verifies bundled model then reuses cache offline',
    () async {
      final fs = _MemoryFileSystem();
      final bundle = _FakeBundleSource(bytes);
      final service = _service(manifest, fs, bundle);
      final prepared = await service.ensureReady();
      expect(prepared.modelPath, endsWith('scene-model-v1.onnx'));
      expect(prepared.sha256, digest);
      expect(
        prepared.cacheDirectory,
        endsWith(p.join('scene-cache', sceneModelId)),
      );
      expect(await fs.exists(prepared.modelPath), isTrue);
      expect(await fs.exists('${prepared.modelPath}.part'), isFalse);

      bundle.failOpens = true;
      final offline = await service.ensureReady();
      expect(offline.modelPath, prepared.modelPath);
      expect(offline.sha256, prepared.sha256);
      expect(bundle.opens, 1);
    },
  );

  test('cancel removes partial cache and leaves model unavailable', () async {
    final fs = _MemoryFileSystem();
    final service = _service(manifest, fs, _FakeBundleSource(bytes));
    var cancelled = false;
    await expectLater(
      service.ensureReady(
        isCancelled: () => cancelled,
        onProgress: (_) => cancelled = true,
      ),
      throwsA(isA<SceneModelCancelled>()),
    );
    expect(fs.files, isEmpty);
  });

  test('wrong hash and missing bundle never create a ready model', () async {
    final fs = _MemoryFileSystem();
    final wrongHash = SceneModelManifest(
      schemaVersion: 1,
      modelId: sceneModelId,
      sha256: '0' * 64,
      sizeBytes: bytes.length,
      bundlePath: manifest.bundlePath,
      fileName: manifest.fileName,
    );
    await expectLater(
      _service(wrongHash, fs, _FakeBundleSource(bytes)).ensureReady(),
      throwsStateError,
    );
    expect(fs.files, isEmpty);

    final missing = _FakeBundleSource(bytes)..failOpens = true;
    await expectLater(
      _service(manifest, fs, missing).ensureReady(),
      throwsA(isA<Exception>()),
    );
    expect(fs.files, isEmpty);
  });

  test(
    'missing manifest digest blocks preparation; deletion respects active work',
    () async {
      final fs = _MemoryFileSystem();
      final unavailable = SceneModelManifest(
        schemaVersion: 1,
        modelId: sceneModelId,
        sha256: null,
        sizeBytes: null,
        bundlePath: manifest.bundlePath,
        fileName: manifest.fileName,
      );
      final bundle = _FakeBundleSource(bytes);
      await expectLater(
        _service(unavailable, fs, bundle).ensureReady(),
        throwsA(isA<StateError>()),
      );
      expect(bundle.opens, 0);

      final service = _service(manifest, fs, _FakeBundleSource(bytes));
      final metadata = await service.ensureReady();
      await expectLater(
        service.deleteCachedModel(activeTasks: true),
        throwsStateError,
      );
      await service.deleteCachedModel(activeTasks: false);
      expect(await fs.exists(metadata.modelPath), isFalse);
    },
  );
}

SceneModelService _service(
  SceneModelManifest manifest,
  _MemoryFileSystem fs,
  _FakeBundleSource bundle,
) => SceneModelService(
  manifest: manifest,
  cacheRootPath: () async => r'C:\app-support',
  bundleSource: bundle,
  fileSystem: fs,
);

class _FakeBundleSource implements SceneModelBundleSource {
  _FakeBundleSource(this.data);
  final List<int> data;
  int opens = 0;
  bool failOpens = false;

  @override
  Future<SceneModelSourceResponse> open() async {
    opens++;
    if (failOpens) throw Exception('bundled model unavailable');
    return _FakeResponse(data.length, [data]);
  }
}

class _FakeResponse implements SceneModelSourceResponse {
  const _FakeResponse(this.totalBytes, this.chunks);
  @override
  final int totalBytes;
  final List<List<int>> chunks;
  @override
  Stream<List<int>> get bytes => Stream.fromIterable(chunks);
}

class _MemoryFileSystem implements SceneModelFileSystem {
  final files = <String, List<int>>{};
  final directories = <String>{};
  @override
  Future<void> append(String path, List<int> bytes) async {
    files.putIfAbsent(path, () => <int>[]).addAll(bytes);
  }

  @override
  Future<void> createDirectory(String path) async {
    directories.add(path);
  }

  @override
  Future<void> delete(String path) async {
    files.remove(path);
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);
  @override
  Future<int> length(String path) async => files[path]!.length;
  @override
  Future<void> rename(String source, String destination) async {
    files[destination] = files.remove(source)!;
  }

  @override
  Future<String> sha256File(String path) async =>
      sha256.convert(files[path]!).toString();
}
