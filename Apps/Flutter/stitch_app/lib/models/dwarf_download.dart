import 'dart:convert';

enum DwarfDownloadState {
  queued,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
}

class DwarfDeviceInfo {
  const DwarfDeviceInfo({
    required this.deviceName,
    this.deviceId,
    this.serialNumber,
    this.sdCardAvailable,
  });
  final String deviceName;
  final String? deviceId;
  final String? serialNumber;
  final bool? sdCardAvailable;
  factory DwarfDeviceInfo.fromJson(Map<String, Object?> json) =>
      DwarfDeviceInfo(
        deviceName:
            json['deviceName'] as String? ??
            json['deviceId'] as String? ??
            'DWARF',
        deviceId: json['deviceId'] as String?,
        serialNumber: json['serialNumber'] as String?,
        sdCardAvailable: json['sdCardAvailable'] as bool?,
      );
}

class DwarfPanorama {
  const DwarfPanorama({
    required this.id,
    required this.title,
    required this.filePath,
    required this.fileSize,
    required this.mediaType,
    this.capturedAt,
    this.thumbnailUrl,
  });
  final String id, title, filePath;
  final int fileSize, mediaType;
  final DateTime? capturedAt;
  final String? thumbnailUrl;
}

class DwarfOriginal {
  const DwarfOriginal({
    required this.id,
    required this.name,
    required this.url,
    this.size,
    this.etag,
    this.lastModified,
  });
  final String id, name, url;
  final int? size;
  final String? etag, lastModified;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'size': size,
    'etag': etag,
    'lastModified': lastModified,
  };
  factory DwarfOriginal.fromJson(Map<String, Object?> j) => DwarfOriginal(
    id: j['id']! as String,
    name: j['name']! as String,
    url: j['url']! as String,
    size: j['size'] as int?,
    etag: j['etag'] as String?,
    lastModified: j['lastModified'] as String?,
  );
}

class DwarfDownloadFile {
  const DwarfDownloadFile({
    required this.original,
    required this.path,
    this.bytes = 0,
    this.complete = false,
    this.error,
    this.sha256,
  });
  final DwarfOriginal original;
  final String path;
  final int bytes;
  final bool complete;
  final String? error;
  final String? sha256;
  Map<String, Object?> toJson() => {
    'original': original.toJson(),
    'path': path,
    'bytes': bytes,
    'complete': complete,
    'error': error,
    'sha256': sha256,
  };
  factory DwarfDownloadFile.fromJson(Map<String, Object?> j) =>
      DwarfDownloadFile(
        original: DwarfOriginal.fromJson(
          (j['original']! as Map).cast<String, Object?>(),
        ),
        path: j['path']! as String,
        bytes: j['bytes'] as int? ?? 0,
        complete: j['complete'] as bool? ?? false,
        error: j['error'] as String?,
        sha256: j['sha256'] as String?,
      );
}

class DwarfDownloadProgress {
  const DwarfDownloadProgress({
    required this.batchId,
    required this.fileName,
    required this.fileBytes,
    required this.fileSize,
    required this.completedFiles,
    required this.totalFiles,
  });
  final String batchId, fileName;
  final int fileBytes, fileSize, completedFiles, totalFiles;
}

class DwarfDownloadBatch {
  const DwarfDownloadBatch({
    required this.id,
    required this.directory,
    required this.state,
    required this.files,
    this.error,
    this.metadata = const {},
  });
  final String id, directory;
  final DwarfDownloadState state;
  final List<DwarfDownloadFile> files;
  final String? error;
  final Map<String, Object?> metadata;
  int get completedBytes => files.fold(
    0,
    (n, f) => n + (f.complete ? (f.original.size ?? f.bytes) : f.bytes),
  );
  int get totalBytes => files.fold(0, (n, f) => n + (f.original.size ?? 0));
  bool get isComplete =>
      files.isNotEmpty &&
      state == DwarfDownloadState.completed &&
      files.every((f) => f.complete);
  Map<String, Object?> toJson() => {
    'schema': 1,
    'id': id,
    'directory': directory,
    'state': state.name,
    'error': error,
    'metadata': metadata,
    'files': files.map((f) => f.toJson()).toList(),
  };
  factory DwarfDownloadBatch.fromJson(Map<String, Object?> j) {
    if (j['schema'] != 1 || j['files'] is! List) {
      throw const FormatException('Unsupported DWARF download manifest schema');
    }
    return DwarfDownloadBatch(
      id: j['id']! as String,
      directory: j['directory']! as String,
      state: DwarfDownloadState.values.firstWhere(
        (s) => s.name == j['state'],
        orElse: () => DwarfDownloadState.paused,
      ),
      error: j['error'] as String?,
      metadata: (j['metadata'] as Map? ?? const {}).cast<String, Object?>(),
      files: (j['files']! as List)
          .map(
            (v) =>
                DwarfDownloadFile.fromJson((v as Map).cast<String, Object?>()),
          )
          .toList(),
    );
  }
}

String encodeDwarfDownloadJson(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);
