import 'package:flutter/material.dart' hide Text;
import 'package:flutter/material.dart' as material;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/l10n/localized_text.dart' show StitchStatusMessage;
import 'package:stitch_app/l10n/localized_text.dart' as localized;
import 'package:stitch_app/l10n/stitch_localizations.dart';

void main() {
  for (final locale in [const Locale('en'), const Locale('zh')]) {
    testWidgets(
      '${locale.languageCode}: Windows task write denial has localized summary and raw details',
      (tester) async {
        const raw =
            r'PathAccessException: Creation failed, path=C:\Users\fixture-user\AppData\Roaming\com.lumia\Lumia Stitch\LumiaStitch\tasks\retry-task (OS Error: Access is denied., errno = 5)';
        const prefixed = '导入失败：$raw';
        final localization = StitchLocalizations(locale);
        final summary = localization.localizedTaskDirectoryAccessDeniedSummary(
          prefixed,
        )!;
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: StitchLocalizations.supportedLocales,
            localizationsDelegates: const [
              StitchLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Scaffold(
              body: Column(
                children: [
                  localized.Text(raw),
                  StitchStatusMessage(message: prefixed),
                ],
              ),
            ),
          ),
        );

        expect(find.text(localization.text(raw)), findsOneWidget);
        expect(find.text(summary), findsOneWidget);
        final tile = find.byType(ExpansionTile);
        expect(tile, findsOneWidget);
        expect(find.byType(SelectableText), findsNothing);
        await tester.tap(
          find.descendant(of: tile, matching: find.byType(material.Text)),
        );
        await tester.pumpAndSettle();
        expect(find.text(raw), findsOneWidget);
        expect(find.byType(SelectableText), findsOneWidget);
      },
    );
  }

  for (final locale in [const Locale('en'), const Locale('zh')]) {
    testWidgets(
      '${locale.languageCode}: technical status details align to the left',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: StitchLocalizations.supportedLocales,
            localizationsDelegates: const [
              StitchLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(24),
                child: StitchStatusMessage(
                  message:
                      '错误：a longer technical detail that wraps across lines',
                ),
              ),
            ),
          ),
        );

        final tileFinder = find.byType(ExpansionTile);
        final tile = tester.widget<ExpansionTile>(tileFinder);
        expect(tile.initiallyExpanded, isFalse);
        expect(tile.expandedAlignment, Alignment.centerLeft);
        expect(tile.expandedCrossAxisAlignment, CrossAxisAlignment.start);
        expect(find.byType(SelectableText), findsNothing);

        await tester.tap(
          find.descendant(of: tileFinder, matching: find.byType(material.Text)),
        );
        await tester.pumpAndSettle();

        final summary = find.byType(material.Text).first;
        final detail = find.byType(SelectableText);
        expect(detail, findsOneWidget);
        expect(
          tester.getTopLeft(summary).dx,
          closeTo(tester.getTopLeft(detail).dx, 0.01),
        );
      },
    );
  }
}
