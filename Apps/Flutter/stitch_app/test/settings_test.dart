import 'dart:io';
import 'dart:async';
import 'dart:convert';
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
    expect(settings.exportFormat, ExportFormat.jpeg);
    expect(settings.seamBlendMode, SeamBlendMode.deghost);
    expect(settings.textSizeMode, TextSizeMode.system);
    expect(settings.textScale, 1.0);
  });

  test('text size settings round trip and sanitize invalid scales', () {
    const custom = AppSettings(
      textSizeMode: TextSizeMode.custom,
      textScale: 1.5,
    );
    final restored = AppSettings.decode(jsonEncode(custom.toJson()));
    expect(restored.textSizeMode, TextSizeMode.custom);
    expect(restored.textScale, 1.5);
    expect(const AppSettings(textScale: double.nan).effectiveTextScale, 1.0);
    expect(
      AppSettings.fromJson({
        ...custom.toJson(),
        'textScale': double.nan,
      }).textScale,
      1.0,
    );
    expect(
      AppSettings.fromJson({...custom.toJson(), 'textScale': 99}).textScale,
      2.0,
    );
    expect(
      AppSettings.fromJson({...custom.toJson(), 'textScale': -1}).textScale,
      1.0,
    );
  });

  test(
    'task date format and rail width persist and sanitize old values',
    () async {
      final controller = SettingsController(
        repository: repository,
        initial: const AppSettings(),
      );
      await controller.update(
        const AppSettings(
          taskDateFormat: TaskDateFormat.monthDayYear,
          taskRailWidth: 312,
        ),
      );
      final restarted = SettingsController(repository: repository);
      await restarted.ready;
      expect(restarted.settings.taskDateFormat, TaskDateFormat.monthDayYear);
      expect(restarted.settings.taskRailWidth, 312);
      final legacy = AppSettings.fromJson({
        'taskDateFormat': 'unknown',
        'taskRailWidth': double.infinity,
      });
      expect(legacy.taskDateFormat, TaskDateFormat.yearMonthDay);
      expect(legacy.taskRailWidth, 230);
      expect(AppSettings.fromJson({'taskRailWidth': 900}).taskRailWidth, 520);
      controller.dispose();
      restarted.dispose();
    },
  );

  test('task dates format in either supported order and retain time', () {
    final local = DateTime(2026, 10, 29, 9, 7);
    expect(
      formatTaskDateTime(local, TaskDateFormat.yearMonthDay),
      '2026-10-29 09:07',
    );
    expect(
      formatTaskDateTime(local, TaskDateFormat.monthDayYear),
      '10/29/2026 09:07',
    );
  });

  testWidgets('task date format can be switched from settings immediately', (
    tester,
  ) async {
    final controller = SettingsController(
      repository: _InMemorySettingsRepository(),
      initial: const AppSettings(language: AppLanguage.zh),
    );
    await tester.pumpWidget(
      LumiaStitchApp(
        settingsController: controller,
        home: SettingsPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    final selector = find.byType(DropdownButton<TaskDateFormat>);
    expect(selector, findsOneWidget);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('MM/DD/YYYY').last);
    await tester.pumpAndSettle();
    expect(controller.settings.taskDateFormat, TaskDateFormat.monthDayYear);
    expect(find.text('MM/DD/YYYY').first, findsOneWidget);
    controller.dispose();
  });

  testWidgets(
    'system text scale is preserved and custom scale is not multiplied',
    (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      var observedScale = 0.0;
      final controller = SettingsController(
        repository: repository,
        initial: const AppSettings(),
      );
      await tester.pumpWidget(
        LumiaStitchApp(
          settingsController: controller,
          home: Builder(
            builder: (context) {
              observedScale = MediaQuery.textScalerOf(context).scale(1);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(observedScale, 1.8);

      tester.platformDispatcher.textScaleFactorTestValue = 2.2;
      await tester.pumpAndSettle();
      expect(observedScale, 2.2);

      await tester.runAsync(
        () => controller.update(
          const AppSettings(textSizeMode: TextSizeMode.custom, textScale: 2.0),
        ),
      );
      await tester.pumpAndSettle();
      expect(observedScale, 2.0);
      controller.dispose();
    },
  );

  testWidgets('large text settings fit a narrow English phone layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = SettingsController(
      repository: repository,
      initial: const AppSettings(
        language: AppLanguage.en,
        textSizeMode: TextSizeMode.custom,
        textScale: 2.0,
      ),
    );
    await tester.pumpWidget(
      LumiaStitchApp(
        settingsController: controller,
        home: SettingsPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('text-size-settings')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('text-size-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('text-size-slider')), findsOneWidget);
    expect(find.byKey(const Key('text-size-150')), findsOneWidget);
    expect(find.byKey(const Key('text-size-100')), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets(
    'Chinese system mode exposes 150 percent and 100 percent shortcuts',
    (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = SettingsController(
        repository: _InMemorySettingsRepository(),
        initial: const AppSettings(language: AppLanguage.zh),
      );
      await tester.pumpWidget(
        LumiaStitchApp(
          settingsController: controller,
          home: SettingsPage(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('text-size-settings')),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('text-size-settings')));
      await tester.pumpAndSettle();
      expect(find.text('文字大小'), findsOneWidget);
      expect(find.text('大字体 150%'), findsOneWidget);
      await tester.tap(find.byKey(const Key('text-size-150')));
      await tester.pumpAndSettle();
      expect(controller.settings.textSizeMode, TextSizeMode.custom);
      expect(controller.settings.effectiveTextScale, 1.5);
      expect(find.text('手动 · 150%'), findsOneWidget);
      await tester.tap(find.byKey(const Key('text-size-100')));
      await tester.pumpAndSettle();
      expect(controller.settings.effectiveTextScale, 1.0);
      controller.dispose();
    },
  );

  testWidgets('large text uses stacked full-width setting dropdowns', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = SettingsController(
      repository: _InMemorySettingsRepository(),
      initial: const AppSettings(
        language: AppLanguage.zh,
        textSizeMode: TextSizeMode.custom,
        textScale: 1.5,
      ),
    );
    await tester.pumpWidget(
      LumiaStitchApp(
        settingsController: controller,
        home: SettingsPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('输出画质'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('输出画质'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButton<ExportFormat>>(
            find.byType(DropdownButton<ExportFormat>),
          )
          .isExpanded,
      isTrue,
    );
    expect(
      tester
          .widget<DropdownButton<SeamBlendMode>>(
            find.byType(DropdownButton<SeamBlendMode>),
          )
          .isExpanded,
      isTrue,
    );
    expect(find.text('输出格式'), findsOneWidget);
    expect(find.text('接缝融合'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('long format labels can wrap in large text dropdown menus', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = SettingsController(
      repository: _InMemorySettingsRepository(),
      initial: const AppSettings(
        language: AppLanguage.en,
        textSizeMode: TextSizeMode.custom,
        textScale: 2.0,
        exportFormat: ExportFormat.tiff,
      ),
    );
    await tester.pumpWidget(
      LumiaStitchApp(
        settingsController: controller,
        home: SettingsPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Output quality'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Output quality'));
    await tester.pumpAndSettle();
    final dropdownFinder = find.byType(DropdownButton<ExportFormat>);
    final dropdown = tester.widget<DropdownButton<ExportFormat>>(
      dropdownFinder,
    );
    expect(dropdown.isExpanded, isTrue);
    expect(dropdown.itemHeight, isNull);
    final longLabel = find.text('TIFF (lossless; BigTIFF for large images)');
    expect(longLabel, findsOneWidget);
    expect(tester.getRect(longLabel).height, greaterThan(48));
    await tester.tap(dropdownFinder);
    await tester.pumpAndSettle();
    expect(longLabel, findsNWidgets(2));
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  test('platform defaults use JPEG on desktop and preserve mobile choices', () {
    final windows = AppSettings.defaults(mobile: false);
    final android = AppSettings.defaults(mobile: true, android: true);
    final ios = AppSettings.defaults(mobile: true);
    expect(windows.exportFormat, ExportFormat.jpeg);
    expect(windows.refineGridNeighbors, isTrue);
    expect(windows.seamBlendMode, SeamBlendMode.deghost);
    expect(android.exportFormat, ExportFormat.tiff);
    expect(android.refineGridNeighbors, isTrue);
    expect(android.seamBlendMode, SeamBlendMode.deghost);
    expect(ios.exportFormat, ExportFormat.png);
    expect(ios.refineGridNeighbors, isFalse);
    expect(ios.seamBlendMode, SeamBlendMode.feather);
  });

  test('migrates an unset legacy desktop TIFF default to JPEG once', () async {
    final legacy = File('${temp.path}${Platform.pathSeparator}settings.json');
    await legacy.writeAsString(
      '{"version":1,"exportFormat":"tiff","language":"zh"}',
    );

    final loaded = await SettingsRepository(
      file: legacy,
      defaults: AppSettings.defaults(mobile: false),
    ).load();
    final persisted = AppSettings.decode(await legacy.readAsString());

    expect(loaded.exportFormat, ExportFormat.jpeg);
    expect(loaded.language, AppLanguage.zh);
    expect(persisted.exportFormat, ExportFormat.jpeg);
    expect(persisted.exportFormatExplicitlySet, isFalse);
  });

  test('preserves an explicitly selected legacy output format', () async {
    final legacy = File('${temp.path}${Platform.pathSeparator}settings.json');
    await legacy.writeAsString(
      '{"version":2,"exportFormat":"tiff",'
      '"exportFormatExplicitlySet":true}',
    );
    final loaded = await SettingsRepository(
      file: legacy,
      defaults: AppSettings.defaults(mobile: false),
    ).load();
    expect(loaded.exportFormat, ExportFormat.tiff);
    expect(loaded.exportFormatExplicitlySet, isTrue);
  });

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

class _InMemorySettingsRepository extends SettingsRepository {
  @override
  Future<AppSettings> load() async => const AppSettings();

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
