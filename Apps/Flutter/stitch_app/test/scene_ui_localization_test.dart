import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/app_settings.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:stitch_app/services/settings_controller.dart';
import 'package:stitch_app/services/settings_repository.dart';
import 'package:stitch_app/settings_page.dart';
import 'package:stitch_app/l10n/stitch_localizations.dart';
import 'package:stitch_app/services/scene_model_service.dart';
import 'package:stitch_app/widgets/scene_model_dialog.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('scene-ui-test-');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('scene stage and native errors have Chinese operator text', () {
    const l = StitchLocalizations(Locale('zh'));
    expect(l.timelineStage('semantic-analysis'), '场景语义分析');
    expect(
      l.text('JOB_FAILED: scene model SHA-256 mismatch'),
      'JOB_FAILED: 场景模型 SHA-256 校验不匹配。',
    );
    expect(
      l.text('Bad state: Scene model SHA-256 verification failed.'),
      '场景模型 SHA-256 校验失败。',
    );
    expect(l.text('正在准备场景模型：37%'), '正在准备场景模型：37%');
    expect(
      l.text(
        'scene analysis needs approximately 1600 MiB for 640x480 source, model and ONNX Runtime workspace, above the 1024 MiB job budget',
      ),
      '场景分析约需 1600 MiB（640×480 原片、模型及 ONNX Runtime 工作区），超过 1024 MiB 任务预算。',
    );
  });

  test('scene preparation progress remains English in English locale', () {
    const l = StitchLocalizations(Locale('en'));
    expect(l.text('正在准备场景模型：37%'), 'Preparing scene model: 37%');
    expect(
      l.text(
        'scene analysis needs approximately 1600 MiB for 640x480 source, model and ONNX Runtime workspace, above the 1024 MiB job budget',
      ),
      'scene analysis needs approximately 1600 MiB for 640x480 source, model and ONNX Runtime workspace, above the 1024 MiB job budget',
    );
  });

  testWidgets('scene controls are localized and hidden for mobile settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = SettingsController(
      repository: SettingsRepository(file: File('${temp.path}/settings.json')),
      initial: const AppSettings(language: AppLanguage.en),
    );
    await tester.pumpWidget(
      _settingsApp(controller, mobile: false, locale: const Locale('en')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Output quality'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('protect-people-default')), findsOneWidget);
    expect(find.text('Protect people'), findsOneWidget);
    expect(find.text('Smooth water'), findsOneWidget);
    expect(find.textContaining('avoid cutting them at seams'), findsOneWidget);
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('goldens/scene-options-settings-en.png'),
    );

    await tester.pumpWidget(
      _settingsApp(controller, mobile: false, locale: const Locale('zh')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('输出画质'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('保护人物'), findsOneWidget);
    expect(find.text('平滑水面'), findsOneWidget);
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('goldens/scene-options-settings-zh.png'),
    );

    await tester.pumpWidget(
      _settingsApp(controller, mobile: true, locale: const Locale('zh')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('输出画质'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('protect-people-default')), findsNothing);
    expect(find.byKey(const Key('smooth-water-default')), findsNothing);
    controller.dispose();
  });

  testWidgets('preparation cancel closes the model dialog exactly once', (
    tester,
  ) async {
    final source = _ControlledSceneModelSource();
    final service = SceneModelService(
      manifest: SceneModelManifest(
        schemaVersion: 1,
        modelId: sceneModelId,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        sizeBytes: 2,
        bundlePath: 'data/models/scene-model-v1.onnx',
        fileName: 'scene-model-v1.onnx',
      ),
      cacheRootPath: () async => temp.path,
      bundleSource: source,
      fileSystem: _CancelTestFileSystem(),
    );
    await tester.pumpWidget(
      MaterialApp(
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
              child: const Text('Host page'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Host page'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(source.opened.isCompleted, isTrue);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Host page'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    unawaited(source.controller.close());
  });
}

Widget _settingsApp(
  SettingsController controller, {
  required bool mobile,
  required Locale locale,
}) => MaterialApp(
  locale: locale,
  supportedLocales: StitchLocalizations.supportedLocales,
  localizationsDelegates: const [
    StitchLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: SettingsPage(controller: controller, mobile: mobile),
);

class _ControlledSceneModelSource implements SceneModelBundleSource {
  final opened = Completer<void>();
  final controller = StreamController<List<int>>();

  @override
  Future<SceneModelSourceResponse> open() async {
    if (!opened.isCompleted) opened.complete();
    return _ControlledSceneModelResponse(controller.stream);
  }
}

class _ControlledSceneModelResponse implements SceneModelSourceResponse {
  const _ControlledSceneModelResponse(this.bytes);
  @override
  final int totalBytes = 2;
  @override
  final Stream<List<int>> bytes;
}

class _CancelTestFileSystem implements SceneModelFileSystem {
  final files = <String, List<int>>{};

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<int> length(String path) async => files[path]!.length;

  @override
  Future<String> sha256File(String path) async => List.filled(64, '0').join();

  @override
  Future<void> createDirectory(String path) async {}

  @override
  Future<void> append(String path, List<int> bytes) async {
    files.putIfAbsent(path, () => <int>[]).addAll(bytes);
  }

  @override
  Future<void> delete(String path) async {
    files.remove(path);
  }

  @override
  Future<void> rename(String source, String destination) async {
    files[destination] = files.remove(source)!;
  }
}
