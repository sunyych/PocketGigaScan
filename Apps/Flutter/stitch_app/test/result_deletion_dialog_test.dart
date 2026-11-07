import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/l10n/stitch_localizations.dart';
import 'package:stitch_app/widgets/result_deletion_dialog.dart';

void main() {
  testWidgets('confirmation defaults delete files and cancel returns null', (
    tester,
  ) async {
    ResultDeletionChoice? choice;
    await tester.pumpWidget(
      _app(
        onResult: (context) async {
          choice = await showResultDeletionConfirmation(context, count: 3);
        },
      ),
    );
    await tester.tap(find.byKey(const Key('open-delete-confirmation')));
    await tester.pumpAndSettle();

    expect(find.text('Selected: 3'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('result-delete-keep-inputs')),
          )
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('result-delete-keep-outputs')),
          )
          .value,
      isFalse,
    );
    await tester.tap(find.byKey(const Key('result-delete-cancel')));
    await tester.pumpAndSettle();
    expect(choice, isNull);
  });

  testWidgets('large text on a narrow screen keeps dialog actions reachable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    ResultDeletionChoice? choice;
    await tester.pumpWidget(
      _app(
        onResult: (context) async {
          choice = await showResultDeletionConfirmation(context, count: 23);
        },
        textScale: 2,
      ),
    );
    await tester.tap(find.byKey(const Key('open-delete-confirmation')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('result-delete-selected-count')),
      findsOneWidget,
    );

    final confirm = find.byKey(const Key('result-delete-confirm'));
    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    expect(confirm.hitTestable(), findsOneWidget);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(choice, isNotNull);
    expect(choice!.keepInputs, isFalse);
    expect(choice!.keepOutputs, isFalse);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('keep inputs and outputs can be selected independently', (
    tester,
  ) async {
    ResultDeletionChoice? choice;
    await tester.pumpWidget(
      _app(
        onResult: (context) async {
          choice = await showResultDeletionConfirmation(context, count: 1);
        },
      ),
    );
    await tester.tap(find.byKey(const Key('open-delete-confirmation')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('result-delete-keep-inputs')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('result-delete-keep-inputs')),
          )
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('result-delete-keep-outputs')),
          )
          .value,
      isFalse,
    );
    await tester.tap(find.byKey(const Key('result-delete-confirm')));
    await tester.pumpAndSettle();
    expect(choice?.keepInputs, isTrue);
    expect(choice?.keepOutputs, isFalse);
  });
}

Widget _app({
  required Future<void> Function(BuildContext context) onResult,
  double textScale = 1,
}) => MaterialApp(
  locale: const Locale('en'),
  supportedLocales: StitchLocalizations.supportedLocales,
  localizationsDelegates: const [
    StitchLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          key: const Key('open-delete-confirmation'),
          onPressed: () => onResult(context),
          child: const Text('Open'),
        ),
      ),
    ),
  ),
);
