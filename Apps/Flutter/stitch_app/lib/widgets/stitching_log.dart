import 'package:flutter/material.dart';

import '../l10n/stitch_localizations.dart';
import '../models/stitch_timeline.dart';

/// Timestamp-left lifecycle log. Callers supply localized event text and total.
class StitchingLog extends StatelessWidget {
  const StitchingLog({
    super.key,
    required this.timeline,
    required this.eventLabel,
    required this.totalLabel,
  });

  final StitchTimeline timeline;
  final String Function(StitchTimelineEvent event) eventLabel;
  final String totalLabel;

  @override
  Widget build(BuildContext context) {
    final localization = StitchLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final event in timeline.events)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 112,
                  child: Text(
                    _format(event.timestampUtc),
                    textAlign: TextAlign.left,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _label(localization, event),
                    textAlign: TextAlign.left,
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            totalLabel,
            textAlign: TextAlign.left,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
      ],
    );
  }

  String _label(StitchLocalizations localization, StitchTimelineEvent event) {
    final label = eventLabel(event);
    if (event.stage == null && event.state == null && label == event.kind) {
      return localization.timelineEventKind(event.kind);
    }
    return label;
  }

  String _format(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}
