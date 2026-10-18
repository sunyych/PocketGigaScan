import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/stitch_localizations.dart';
import '../services/scene_model_service.dart';

Future<void> showSceneModelDialog(
  BuildContext context,
  Future<SceneModelService> service,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _SceneModelDialog(service: service),
);

class SceneModelManagerTile extends StatefulWidget {
  const SceneModelManagerTile({
    super.key,
    required this.service,
    required this.activeTasks,
  });
  final Future<SceneModelService> service;
  final bool activeTasks;

  @override
  State<SceneModelManagerTile> createState() => _SceneModelManagerTileState();
}

class _SceneModelManagerTileState extends State<SceneModelManagerTile> {
  String? _error;
  bool _working = false;

  @override
  Widget build(BuildContext context) {
    final l = StitchLocalizations.of(context);
    return ExpansionTile(
      title: Text(l.sceneModel),
      children: [
        ListTile(title: Text(l.sceneModelBundleHelp)),
        ListTile(
          title: Text(l.sceneModelPrepare),
          onTap: _working
              ? null
              : () => showSceneModelDialog(context, widget.service),
        ),
        ListTile(
          title: Text(l.sceneModelDelete),
          enabled: !_working && !widget.activeTasks,
          onTap: _working || widget.activeTasks ? null : _delete,
        ),
        if (_error != null)
          ListTile(
            title: Text(
              StitchLocalizations.of(context).text(_error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  Future<void> _delete() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await (await widget.service).deleteCachedModel(
        activeTasks: widget.activeTasks,
      );
    } on Object catch (error) {
      _error = error.toString();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }
}

class _SceneModelDialog extends StatefulWidget {
  const _SceneModelDialog({required this.service});
  final Future<SceneModelService> service;

  @override
  State<_SceneModelDialog> createState() => _SceneModelDialogState();
}

class _SceneModelDialogState extends State<_SceneModelDialog> {
  bool _cancelled = false;
  bool _running = false;
  bool _ready = false;
  bool _closing = false;
  int _received = 0;
  int _total = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_prepare());
    });
  }

  Future<void> _prepare() async {
    setState(() {
      _running = true;
      _error = null;
      _cancelled = false;
      _received = 0;
      _total = 0;
    });
    try {
      await (await widget.service).ensureReady(
        isCancelled: () => _cancelled,
        onProgress: (value) {
          if (mounted) {
            setState(() {
              _received = value.receivedBytes;
              _total = value.totalBytes;
            });
          }
        },
      );
      if (mounted) setState(() => _ready = true);
    } on SceneModelCancelled {
      _closeDialog();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _closeDialog() {
    if (!mounted || _closing) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = StitchLocalizations.of(context);
    final fraction = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;
    return AlertDialog(
      title: Text(l.sceneModel),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_ready ? l.sceneModelReady : l.sceneModelPreparing),
          if (_running) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: fraction),
            const SizedBox(height: 8),
            Text(
              _total > 0
                  ? '${_formatBytes(_received)} / ${_formatBytes(_total)}'
                  : _formatBytes(_received),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            SelectableText(l.text(_error!)),
          ],
        ],
      ),
      actions: [
        if (_running)
          TextButton(
            onPressed: () {
              _cancelled = true;
              unawaited(
                widget.service.then((service) => service.cancelPreparation()),
              );
              _closeDialog();
            },
            child: Text(l.cancel),
          )
        else if (_ready)
          TextButton(onPressed: _closeDialog, child: Text(l.done))
        else ...[
          TextButton(onPressed: _prepare, child: Text(l.retry)),
          TextButton(onPressed: _closeDialog, child: Text(l.cancel)),
        ],
      ],
    );
  }

  String _formatBytes(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB'
      : '${(bytes / 1024).toStringAsFixed(0)} KiB';
}
