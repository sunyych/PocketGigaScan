import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/main.dart' show LumiaStitchApp;
import 'package:stitch_app/models/app_settings.dart';
import 'package:stitch_app/services/memory_budget_policy.dart';
import 'package:stitch_app/services/settings_controller.dart';
import 'package:stitch_app/services/settings_repository.dart';
import 'package:stitch_app/settings_page.dart';

void main() {
  testWidgets('memory budget controls render in English and Chinese', (
    tester,
  ) async {
    for (final language in [AppLanguage.en, AppLanguage.zh]) {
      final controller = SettingsController(
        initial: AppSettings(language: language),
      );
      await tester.pumpWidget(
        LumiaStitchApp(
          settingsController: controller,
          home: SettingsPage(
            controller: controller,
            memoryReading: const MemoryResourceReading(
              totalMemoryMiB: 128 * 1024,
              availableMemoryMiB: 64 * 1024,
              logicalCpuCount: 16,
              source: 'fixture',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final title = language == AppLanguage.en ? 'App memory budget' : '应用内存预算';
      await tester.scrollUntilVisible(
        find.text(title),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(
        find.text(language == AppLanguage.en ? 'Automatic' : '自动分配'),
        findsOneWidget,
      );
      expect(
        find.text(language == AppLanguage.en ? 'Manual' : '手动设置'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          language == AppLanguage.en ? 'Available: 64 GiB' : '可用: 64 GiB',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
  });

  testWidgets(
    'manual marks and automatic mode persist across controller reload',
    (tester) async {
      final temp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('memory-settings-'),
      ))!;
      addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
      final repository = SettingsRepository(
        file: File('${temp.path}${Platform.pathSeparator}settings.json'),
      );
      final settingsFile = repository.file!;

      Future<void> pumpUntilPersisted(String mode, int budgetMiB) async {
        final deadline = Stopwatch()..start();
        while (deadline.elapsed < const Duration(seconds: 5)) {
          final persisted = await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            if (!await settingsFile.exists()) return null;
            final value = jsonDecode(await settingsFile.readAsString());
            return value is Map<String, dynamic> ? value : null;
          });
          await tester.pump();
          if (persisted?['memoryBudgetMode'] == mode &&
              persisted?['totalMemoryBudgetMiB'] == budgetMiB) {
            return;
          }
        }
        fail(
          'Settings save did not persist $mode/$budgetMiB within five seconds',
        );
      }

      final controller = SettingsController(
        repository: repository,
        initial: const AppSettings(language: AppLanguage.en),
      );
      await tester.pumpWidget(
        LumiaStitchApp(
          settingsController: controller,
          home: SettingsPage(
            controller: controller,
            memoryReading: const MemoryResourceReading(
              totalMemoryMiB: 128 * 1024,
              availableMemoryMiB: 64 * 1024,
              logicalCpuCount: 16,
              source: 'fixture',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('App memory budget'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('App memory budget'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manual'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('total-memory-budget-slider')),
        findsOneWidget,
      );
      expect(find.widgetWithText(ActionChip, '16 GiB'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, '32 GiB'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, '64 GiB'), findsNothing);
      final budgetMarks = find
          .descendant(
            of: find.byType(SettingsPage),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .hitTestable();
      await tester.scrollUntilVisible(
        find.widgetWithText(ActionChip, '32 GiB').hitTestable(),
        250,
        scrollable: budgetMarks,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ActionChip, '32 GiB').hitTestable());
      await tester.pumpAndSettle();
      await pumpUntilPersisted('manual', 32 * 1024);
      final manual = (await tester.runAsync(() async {
        final loaded = SettingsController(repository: repository);
        await loaded.ready;
        return loaded;
      }))!;
      expect(manual.settings.memoryBudgetMode, MemoryBudgetMode.manual);
      expect(manual.settings.totalMemoryBudgetMiB, 32 * 1024);

      // UI persistence is intentionally unawaited. Start it inside the widget
      // zone, then pump fake-async work while observing the real owned settings
      // file before reloading through the real repository.
      controller.updateWith(
        (settings) =>
            settings.copyWith(memoryBudgetMode: MemoryBudgetMode.automatic),
      );
      await pumpUntilPersisted('automatic', 32 * 1024);
      final automatic = (await tester.runAsync(() async {
        final loaded = SettingsController(repository: repository);
        await loaded.ready;
        return loaded;
      }))!;
      expect(automatic.settings.memoryBudgetMode, MemoryBudgetMode.automatic);
      expect(automatic.settings.totalMemoryBudgetMiB, 32 * 1024);
      expect(find.byKey(const Key('total-memory-budget-slider')), findsNothing);
      controller.dispose();
      manual.dispose();
      automatic.dispose();
    },
  );
}
