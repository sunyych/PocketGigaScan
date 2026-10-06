import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/stitch_timeline.dart';
import 'package:stitch_app/widgets/stitching_log.dart';

void main() {
  testWidgets('timestamp stays left of localized step at narrow width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(280, 500));
    final timeline = StitchTimeline(
      events: [
        StitchTimelineEvent(
          id: 'start',
          timestampUtc: DateTime.utc(2026, 10, 6, 19, 30),
          kind: 'started',
        ),
      ],
    );

    for (final language in ['en', 'zh']) {
      final label = language == 'en' ? 'Rendering panorama' : '正在生成全景图';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(8),
              child: StitchingLog(
                timeline: timeline,
                eventLabel: (_) => label,
                totalLabel: language == 'en'
                    ? 'Wall clock: 2 min'
                    : '墙钟时间：2 分钟',
              ),
            ),
          ),
        ),
      );
      final row = find.byType(Row).first;
      final texts = tester
          .widgetList<Text>(
            find.descendant(of: row, matching: find.byType(Text)),
          )
          .toList();
      expect(texts, hasLength(2));
      expect(texts.first.data, matches(RegExp(r'^\d\d:\d\d:\d\d$')));
      expect(texts.first.textAlign, TextAlign.left);
      expect(texts.last.data, label);
      expect(texts.last.textAlign, TextAlign.left);
      expect(tester.takeException(), isNull);
    }
    await tester.binding.setSurfaceSize(null);
  });
}
