import 'package:flutter/services.dart';

/// Android document-picker operations shared with future mobile platforms.
/// Folder selections are copied into app-private staging before returning.
class MobileStorageService {
  const MobileStorageService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.lumiaiq.pocketgigascan/storage');

  final MethodChannel _channel;

  /// Selects a batch parent and returns its private staged filesystem path.
  /// Returning null means the user cancelled the folder picker.
  Future<String?> pickBatchParent() => _channel.invokeMethod<String>(
    'pickBatchParent',
  );

  /// Removes a completed, app-private staging copy after task inputs are durable.
  Future<bool> releaseBatchParent(String stagedPath) async =>
      await _channel.invokeMethod<bool>('releaseBatchParent', {
        'path': stagedPath,
      }) ??
      false;

  /// Copies an existing export through ACTION_CREATE_DOCUMENT.
  /// Returns false when the user cancels the save picker.
  Future<bool> saveExport(
    String sourcePath, {
    required String mimeType,
    required String suggestedName,
  }) async =>
      await _channel.invokeMethod<bool>('saveExport', {
        'path': sourcePath,
        'mimeType': mimeType,
        'suggestedName': suggestedName,
      }) ??
      false;

  /// Shares an app-owned export using its format MIME type.
  Future<bool> shareExport(
    String sourcePath, {
    required String mimeType,
  }) async =>
      await _channel.invokeMethod<bool>('shareExport', {
        'path': sourcePath,
        'mimeType': mimeType,
      }) ??
      false;
}
