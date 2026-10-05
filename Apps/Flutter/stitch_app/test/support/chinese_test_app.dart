import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:stitch_app/l10n/stitch_localizations.dart';

/// Existing UI snapshots stay on their historical Chinese copy. Locale-specific
/// behavior is covered separately by localization_test.dart.
class ChineseTestApp extends StatelessWidget {
  const ChineseTestApp({super.key, required this.home});

  final Widget home;

  @override
  Widget build(BuildContext context) => MaterialApp(
    locale: const Locale('zh'),
    supportedLocales: StitchLocalizations.supportedLocales,
    localizationsDelegates: const [
      StitchLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  );
}
