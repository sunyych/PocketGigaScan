import 'package:flutter/material.dart' hide Text;

import '../l10n/localized_text.dart';
import '../l10n/stitch_localizations.dart';

class ResultDeletionChoice {
  const ResultDeletionChoice({
    this.keepInputs = false,
    this.keepOutputs = false,
  });

  final bool keepInputs;
  final bool keepOutputs;
}

Future<ResultDeletionChoice?> showResultDeletionConfirmation(
  BuildContext context, {
  required int count,
}) {
  if (count < 1) return Future.value(null);
  ModalRoute<ResultDeletionChoice>? dialogRoute;
  final result = showDialog<ResultDeletionChoice>(
    context: context,
    builder: (dialogContext) {
      dialogRoute = ModalRoute.of<ResultDeletionChoice>(dialogContext);
      return _ResultDeletionDialog(count: count);
    },
  );
  return _waitForDialogExit(result, () => dialogRoute);
}

Future<ResultDeletionChoice?> _waitForDialogExit(
  Future<ResultDeletionChoice?> result,
  ModalRoute<ResultDeletionChoice>? Function() getRoute,
) async {
  final choice = await result;
  await getRoute()?.completed;
  return choice;
}

class _ResultDeletionDialog extends StatefulWidget {
  const _ResultDeletionDialog({required this.count});

  final int count;

  @override
  State<_ResultDeletionDialog> createState() => _ResultDeletionDialogState();
}

class _ResultDeletionDialogState extends State<_ResultDeletionDialog> {
  bool _keepInputs = false;
  bool _keepOutputs = false;

  @override
  Widget build(BuildContext context) {
    final strings = StitchLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const Key('result-delete-confirmation'),
      scrollable: true,
      title: Text(strings.text('删除所选结果？')),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.62,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${strings.text('将删除所选结果记录以及可验证属于应用的输入副本、合成数据和导出文件。')}'
                ' ${strings.text('原始照片和无法验证归属的文件不会删除。')}',
              ),
              const SizedBox(height: 8),
              Text(
                '${strings.text('已选择：')}${widget.count}',
                key: const Key('result-delete-selected-count'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              CheckboxListTile(
                key: const Key('result-delete-keep-inputs'),
                value: _keepInputs,
                onChanged: (value) =>
                    setState(() => _keepInputs = value ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(strings.text('保留输入文件')),
                subtitle: Text(strings.text('保留应用保存的输入副本')),
              ),
              CheckboxListTile(
                key: const Key('result-delete-keep-outputs'),
                value: _keepOutputs,
                onChanged: (value) =>
                    setState(() => _keepOutputs = value ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(strings.text('保留输出文件')),
                subtitle: Text(strings.text('保留合成数据和可验证的导出文件')),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('result-delete-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.text('取消')),
        ),
        FilledButton.icon(
          key: const Key('result-delete-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: colors.error,
            foregroundColor: colors.onError,
          ),
          onPressed: () => Navigator.of(context).pop(
            ResultDeletionChoice(
              keepInputs: _keepInputs,
              keepOutputs: _keepOutputs,
            ),
          ),
          icon: const Icon(Icons.delete_outline),
          label: Text('${strings.text('删除')} ${widget.count}'),
        ),
      ],
    );
  }
}
