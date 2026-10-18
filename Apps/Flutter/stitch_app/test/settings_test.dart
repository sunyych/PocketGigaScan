import 'dart:io';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:stitch_app/main.dart' show LumiaStitchApp;
import 'package:stitch_app/settings_page.dart';
import 'package:stitch_app/models/app_settings.dart';
import 'package:stitch_app/models/performance_options.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/services/settings_controller.dart';
import 'package:stitch_app/services/settings_repository.dart';

void main() {
  late Directory temp;
  late SettingsRepository repository;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('settings-test-');
    repository = SettingsRepository(
      file: File('${temp.path}${Platform.pathSeparator}settings.json'),
    );
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('settings survive controller restart and keep defaults', () async {
    final first = SettingsController(
      repository: repository,
      initial: const AppSettings(),
    );
    await first.update(
      const AppSettings(
        language: AppLanguage.zh,
        themeMode: AppThemeMode.dark,
        accent: AppAccent.purple,
        exportFormat: ExportFormat.png,
        performance: PerformanceOptions(orbFeatures: true),
        outputDirectory: 'content://tree/abc',
      ),
    );
    final restarted = SettingsController(repository: repository);
    await restarted.ready;
    expect(restarted.settings.language, AppLanguage.zh);
    expect(restarted.settings.themeMode, AppThemeMode.dark);
    expect(restarted.settings.performance.orbFeatures, isTrue);
    expect(restarted.settings.outputDirectory, 'content://tree/abc');
    expect(restarted.settings.exportFormat, ExportFormat.png);
    first.dispose();
    restarted.dispose();
  });

  test('unknown and incomplete JSON tolerates prior and future versions', () {
    final settings = AppSettings.fromJson({
      'version': 900,
      'language': 'future',
      'ignored': true,
    });
    expect(settings.language, AppLanguage.system);
    expect(settings.exportFormat, ExportFormat.tiff);
    expect(settings.seamBlendMode, SeamBlendMode.deghost);
  });

  test(
    'platform defaults preserve the existing Windows and Android choices',
    () {
      final windows = AppSettings.defaults(mobile: false);
      final android = AppSettings.defaults(mobile: true, android: true);
      final ios = AppSettings.defaults(mobile: true);
      expect(windows.exportFormat, ExportFormat.tiff);
      expect(windows.refineGridNeighbors, isTrue);
      expect(windows.seamBlendMode, SeamBlendMode.deghost);
      expect(android.exportFormat, ExportFormat.tiff);
      expect(android.refineGridNeighbors, isTrue);
      expect(android.seamBlendMode, SeamBlendMode.deghost);
      expect(ios.exportFormat, ExportFormat.png);
      expect(ios.refineGridNeighbors, isFalse);
      expect(ios.seamBlendMode, SeamBlendMode.feather);
    },
  );

  test(
    'rapid updates are serialized and latest value survives restart',
    () async {
      final controller = SettingsController(
        repository: repository,
        initial: const AppSettings(),
      );
      await Future.wait([
        controller.update(const AppSettings(language: AppLanguage.en)),
        controller.update(const AppSettings(language: AppLanguage.zh)),
      ]);
      final restarted = SettingsController(repository: repository);
      await restarted.ready;
      expect(restarted.settings.language, AppLanguage.zh);
      controller.dispose();
      restarted.dispose();
    },
  );

  testWidgets(
    'settings controls render at phone width and language applies live',
    (tester) async {
      tester.view.physicalSize = const Size(400, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = SettingsController(
        repository: repository,
        initial: const AppSettings(),
      );
      await tester.pumpWidget(
        LumiaStitchApp(
          settingsController: controller,
          home: SettingsPage(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      expect(find.textContaining('Output quality'), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<AppLanguage>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chinese').last);
      await tester.pumpAndSettle();
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('输出画质'), findsOneWidget);
      expect(find.byType(DropdownButton<AppThemeMode>), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<AppThemeMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      await tester.tap(find.byType(DropdownButton<AppLanguage>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      controller.dispose();
    },
  );

  test(
    'a preference changed during load is not overwritten by delayed storage',
    () async {
      final delayed = _DelayedSettingsRepository();
      final controller = SettingsController(repository: delayed);
      await controller.update(const AppSettings(language: AppLanguage.zh));
      delayed.loaded.complete(const AppSettings(language: AppLanguage.en));
      await controller.ready;
      expect(controller.settings.language, AppLanguage.zh);
      controller.dispose();
    },
  );

  test(
    'save failures remain visible and a disposed controller ignores late errors',
    () async {
      final failed = SettingsController(
        repository: _FailingSettingsRepository(),
        initial: const AppSettings(),
      );
      await failed.update(const AppSettings(language: AppLanguage.zh));
      expect(failed.error, contains('settings write failed'));
      failed.dispose();

      final delayed = _DelayedSaveRepository();
      final disposed = SettingsController(
        repository: delayed,
        initial: const AppSettings(),
      );
      final saving = disposed.update(
        const AppSettings(language: AppLanguage.en),
      );
      disposed.dispose();
      delayed.saved.completeError(
        const FileSystemException('late write failure'),
      );
      await saving;
    },
  );

  test(
    'an older failed write cannot replace the latest successful state',
    () async {
      final repository = _OrderedSaveRepository();
      final controller = SettingsController(
        repository: repository,
        initial: const AppSettings(),
      );
      final first = controller.update(
        const AppSettings(language: AppLanguage.en),
      );
      final second = controller.update(
        const AppSettings(language: AppLanguage.zh),
      );
      repository.saves[1].complete();
      await second;
      repository.saves[0].completeError(
        const FileSystemException('older write failed'),
      );
      await first;
      expect(controller.settings.language, AppLanguage.zh);
      expect(controller.error, isNull);
      controller.dispose();
    },
  );
}

class _DelayedSettingsRepository extends SettingsRepository {
  final loaded = Completer<AppSettings>();
  @override
  Future<AppSettings> load() => loaded.future;
  @override
  Future<void> save(AppSettings settings) async {}
}

class _FailingSettingsRepository extends SettingsRepository {
  @override
  Future<void> save(AppSettings settings) async =>
      throw const FileSystemException('settings write failed');
}

class _DelayedSaveRepository extends SettingsRepository {
  final saved = Completer<void>();
  @override
  Future<void> save(AppSettings settings) => saved.future;
}

class _OrderedSaveRepository extends SettingsRepository {
  final saves = <Completer<void>>[Completer<void>(), Completer<void>()];
  var index = 0;
  @override
  Future<void> save(AppSettings settings) => saves[index++].future;
}
