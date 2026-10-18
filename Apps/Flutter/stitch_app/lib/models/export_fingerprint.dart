class ExportFileFingerprint {
  const ExportFileFingerprint({
    required this.sizeBytes,
    required this.modifiedAtMicros,
  });

  final int sizeBytes;
  final int modifiedAtMicros;

  Map<String, Object?> toJson() => {
    'sizeBytes': sizeBytes,
    'modifiedAtMicros': modifiedAtMicros,
  };

  factory ExportFileFingerprint.fromJson(Map<String, Object?> json) =>
      ExportFileFingerprint(
        sizeBytes: json['sizeBytes']! as int,
        modifiedAtMicros: json['modifiedAtMicros']! as int,
      );
}
