import 'package:flutter/material.dart' hide Text;
import 'package:flutter/material.dart' as material;

import 'stitch_localizations.dart';

/// Drop-in app Text used by existing screens; the actual Material Text is
/// created at build time so a system locale change updates visible copy.
class Text extends StatelessWidget {
  const Text(
    this.data, {
    super.key,
    this.translate = true,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  });

  final String data;
  final bool translate;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  @override
  Widget build(BuildContext context) => material.Text(
    translate ? StitchLocalizations.of(context).text(data) : data,
    style: style,
    strutStyle: strutStyle,
    textAlign: textAlign,
    textDirection: textDirection,
    locale: locale,
    softWrap: softWrap,
    overflow: overflow,
    textScaler: textScaler,
    maxLines: maxLines,
    semanticsLabel: semanticsLabel,
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
    selectionColor: selectionColor,
  );
}

class StitchStatusMessage extends StatelessWidget {
  const StitchStatusMessage({super.key, required this.message, this.style});

  final String message;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final localization = StitchLocalizations.of(context);
    final split = message.indexOf('：');
    if (split <= 0 || split == message.length - 1) {
      return Text(message, style: style);
    }
    final summary = message.substring(0, split + 1);
    final detail = message.substring(split + 1).trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(summary, style: style),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          dense: true,
          title: Text(localization.text('Technical details'), style: style),
          children: [SelectableText(detail, style: style)],
        ),
      ],
    );
  }
}
