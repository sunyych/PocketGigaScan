import 'package:flutter/services.dart';

/// Android document-picker operations shared with future mobile platforms.
/// Folder selections are copied into app-private staging before returning.
class MobileStorageService {
  const MobileStorageService({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('com.lumiaiq.pocketgigascan/storage');

  final MethodChannel _channel;

  Future<OutputFolderSelection?> pickOutputFolder() async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      'pickOutputFolder',
    );
    if (value == null) return null;
    final uri = value['uri'];
    final name = value['displayName'];
    if (uri is! String || name is! String) {
      throw const FormatException('Invalid output folder response');
    }
    return OutputFolderSelection(uri: uri, displayName: name);
  }

  Future<PublishedExport> publishExport(
    String sourcePath, {
    required String destinationUri,
    required String mimeType,
    required String suggestedName,
  }) async {
    final value = await _channel
        .invokeMapMethod<String, Object?>('publishExport', {
          'path': sourcePath,
          'treeUri': destinationUri,
          'mimeType': mimeType,
          'suggestedName': suggestedName,
        });
    if (value == null ||
        value['uri'] is! String ||
        value['displayName'] is! String) {
      throw const FormatException('Invalid published export response');
    }
    return PublishedExport(
      uri: value['uri']! as String,
      displayName: value['displayName']! as String,
    );
  }

  /// Selects a batch parent and returns its private staged filesystem path.
  /// Returning null means the user cancelled the folder picker.
  Future<String?> pickBatchParent() =>
      _channel.invokeMethod<String>('pickBatchParent');

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

class OutputFolderSelection {
  const OutputFolderSelection({required this.uri, required this.displayName});
  final String uri;
  final String displayName;
}

class PublishedExport {
  const PublishedExport({required this.uri, required this.displayName});
  final String uri;
  final String displayName;
}
