import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/l10n/stitch_localizations.dart';
import 'package:stitch_app/services/scene_model_service.dart';
import 'package:stitch_app/widgets/scene_model_dialog.dart';

void main() {
  testWidgets('preparation error can be retried into a verified ready model', (
    tester,
  ) async {
    final service = _RetryableSceneModelService();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          StitchLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: StitchLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showSceneModelDialog(context, Future.value(service)),
              child: const Text('Prepare model'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Prepare model'));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('offline'), findsOneWidget);
    expect(service.attempts, 1);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('场景模型已验证并可离线使用。'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(service.attempts, 2);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}

class _RetryableSceneModelService extends SceneModelService {
  _RetryableSceneModelService()
    : super(
        manifest: SceneModelManifest(
          schemaVersion: 1,
          modelId: sceneModelId,
          sha256: 'a' * 64,
          sizeBytes: 4,
          bundlePath: 'data/models/scene-model-v1.onnx',
          fileName: 'scene-model-v1.onnx',
        ),
        cacheRootPath: _cacheRoot,
        bundleSource: _UnusedBundleSource(),
        fileSystem: _UnusedFileSystem(),
      );

  int attempts = 0;

  @override
  Future<SceneModelMetadata> ensureReady({
    bool Function()? isCancelled,
    void Function(SceneModelProgress progress)? onProgress,
  }) async {
    attempts++;
    if (attempts == 1) throw StateError('offline');
    return SceneModelMetadata(
      modelPath: '/cache/model.onnx',
      sha256: 'a' * 64,
      cacheDirectory: '/cache',
    );
  }
}

Future<String> _cacheRoot() async => '/cache';

class _UnusedBundleSource implements SceneModelBundleSource {
  @override
  Future<SceneModelSourceResponse> open() =>
      throw StateError(
        'The widget test uses the overridden preparation method.',
      );
}

class _UnusedFileSystem implements SceneModelFileSystem {
  @override
  Future<void> append(String path, List<int> bytes) async {}
  @override
  Future<void> createDirectory(String path) async {}
  @override
  Future<void> delete(String path) async {}
  @override
  Future<bool> exists(String path) async => false;
  @override
  Future<int> length(String path) async => 0;
  @override
  Future<void> rename(String source, String destination) async {}
  @override
  Future<String> sha256File(String path) async => '';
}
