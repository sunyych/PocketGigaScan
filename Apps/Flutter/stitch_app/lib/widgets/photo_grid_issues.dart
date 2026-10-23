import 'package:flutter/material.dart';

import '../l10n/stitch_localizations.dart';
import '../services/registration_issues.dart';

class PhotoGridIssueConnection {
  const PhotoGridIssueConnection({
    required this.issue,
    required this.start,
    required this.end,
    required this.handled,
  });

  final RegistrationIssue issue;
  final Offset start;
  final Offset end;
  final bool handled;

  Offset get center => Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2);
}

class PhotoGridIssueOverlay extends StatelessWidget {
  const PhotoGridIssueOverlay({
    super.key,
    required this.size,
    required this.connections,
    required this.onTapIssue,
    required this.child,
  });

  final Size size;
  final List<PhotoGridIssueConnection> connections;
  final ValueChanged<RegistrationIssue> onTapIssue;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final localization = StitchLocalizations.of(context);
    return SizedBox.fromSize(
      size: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: child),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _IssueConnectionPainter(connections)),
            ),
          ),
          for (final connection in connections)
            Positioned(
              left: connection.center.dx - 7,
              top: connection.center.dy - 7,
              child: Tooltip(
                key: ValueKey(
                  'photo-grid-issue-tooltip-${connection.issue.fromPhotoPath}-${connection.issue.toPhotoPath}',
                ),
                richMessage: TextSpan(
                  style: const TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.w700,
                  ),
                  children: [
                    TextSpan(
                      text: _issueMeasurement(localization, connection.issue),
                    ),
                    const TextSpan(text: '\n'),
                    TextSpan(
                      text: connection.handled
                          ? _issueHandled(localization)
                          : _issueMismatch(localization),
                    ),
                  ],
                ),
                child: Semantics(
                  button: true,
                  label: _issueMeasurement(localization, connection.issue),
                  child: GestureDetector(
                    key: ValueKey(
                      'photo-grid-issue-${connection.issue.fromPhotoPath}-${connection.issue.toPhotoPath}',
                    ),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onTapIssue(connection.issue),
                    child: const SizedBox(width: 14, height: 14),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class PhotoGridIssueList extends StatelessWidget {
  const PhotoGridIssueList({
    super.key,
    required this.issues,
    required this.handled,
    required this.onTapIssue,
  });

  final List<RegistrationIssue> issues;
  final bool Function(RegistrationIssue issue) handled;
  final ValueChanged<RegistrationIssue> onTapIssue;

  @override
  Widget build(BuildContext context) {
    final localization = StitchLocalizations.of(context);
    if (issues.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(localization.text('上次配准的超标匹配关系')),
        for (final issue in issues)
          TextButton(
            key: ValueKey(
              'photo-grid-issue-list-${issue.fromPhotoPath}-${issue.toPhotoPath}',
            ),
            onPressed: () => onTapIssue(issue),
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              foregroundColor: Colors.red.shade700,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
            child: Wrap(
              spacing: 6,
              children: [
                Text(_issueMeasurement(localization, issue)),
                Text(
                  handled(issue)
                      ? localization.text('上次诊断，已按网格锁定，待重算')
                      : _issueMismatch(localization),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class PhotoGridSelectionActions extends StatelessWidget {
  const PhotoGridSelectionActions({
    super.key,
    required this.selectionCount,
    required this.canLock,
    required this.canUnlock,
    required this.onClear,
    required this.onLock,
    required this.onUnlock,
  });

  final int selectionCount;
  final bool canLock;
  final bool canUnlock;
  final VoidCallback onClear;
  final VoidCallback onLock;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final localization = StitchLocalizations.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(localization.text('已选照片：$selectionCount')),
        TextButton(
          key: const Key('grid-clear-selection-action'),
          onPressed: selectionCount == 0 ? null : onClear,
          child: Text(localization.text('清除选中')),
        ),
        FilledButton.tonal(
          key: const Key('grid-lock-selected-action'),
          onPressed: canLock ? onLock : null,
          child: Text(localization.text('锁定所选照片的网格位置')),
        ),
        TextButton(
          key: const Key('grid-unlock-selected-action'),
          onPressed: canUnlock ? onUnlock : null,
          child: Text(localization.text('解除所选照片的网格锁定')),
        ),
      ],
    );
  }
}

Future<bool?> showRegistrationRepairDialog(
  BuildContext context,
  List<RegistrationIssue> issues,
) =>
    showDialog<bool>(
      context: context,
      builder: (context) => RegistrationRepairConfirmationDialog(
        issues: issues,
      ),
    );

class RegistrationRepairConfirmationDialog extends StatelessWidget {
  const RegistrationRepairConfirmationDialog({
    super.key,
    required this.issues,
  });

  final List<RegistrationIssue> issues;

  @override
  Widget build(BuildContext context) {
    final localization = StitchLocalizations.of(context);
    return AlertDialog(
      key: const Key('registration-repair-confirmation'),
      title: Text(localization.text('发现相邻照片配准误差超限')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              localization.text(
                '是否按拍摄网格锁定以下问题位置并立即重新合成？原任务和原片会保留。',
              ),
            ),
            const SizedBox(height: 8),
            for (final issue in issues)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(_issueMeasurement(localization, issue)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('registration-repair-decline'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(localization.text('暂不重试')),
        ),
        FilledButton(
          key: const Key('registration-repair-accept'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(localization.text('锁定并重新合成')),
        ),
      ],
    );
  }
}

String _issueMeasurement(
  StitchLocalizations localization,
  RegistrationIssue issue,
) => localization.isChinese
    ? '${issue.fromName} ↔ ${issue.toName} · RMS ${issue.rmsPx.toStringAsFixed(2)} 像素 / 上限 ${issue.limitPx.toStringAsFixed(2)} 像素'
    : '${issue.fromName} ↔ ${issue.toName} · RMS ${issue.rmsPx.toStringAsFixed(2)} px / limit ${issue.limitPx.toStringAsFixed(2)} px';

String _issueMismatch(StitchLocalizations localization) =>
    localization.text('不匹配');

String _issueHandled(StitchLocalizations localization) =>
    localization.text('上次诊断，已按网格锁定，待重算');

class _IssueConnectionPainter extends CustomPainter {
  const _IssueConnectionPainter(this.connections);

  final List<PhotoGridIssueConnection> connections;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red.shade700
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final connection in connections) {
      canvas.drawLine(connection.start, connection.end, paint);
      canvas.drawCircle(connection.center, 2.5, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _IssueConnectionPainter oldDelegate) =>
      oldDelegate.connections != connections;
}
