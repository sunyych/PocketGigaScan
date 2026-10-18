class ImportedPhoto {
  const ImportedPhoto({
    required this.originalName,
    required this.storedPath,
    required this.sha256,
    required this.width,
    required this.height,
    required this.originalOrder,
    this.exifMake,
    this.exifModel,
    this.exifLensModel,
    this.exifFocalLengthMm,
  });

  final String originalName;
  final String storedPath;
  final String sha256;
  final int width;
  final int height;
  final int originalOrder;
  final String? exifMake;
  final String? exifModel;
  final String? exifLensModel;
  final double? exifFocalLengthMm;

  bool get isVerifiedDwarf3Tele =>
      exifMake?.trim().toUpperCase() == 'DWARFLAB' &&
      exifModel?.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '') ==
          'DWARF3' &&
      exifLensModel?.trim().toUpperCase() == 'TELE';

  ImportedPhoto copyWithPath(String path) => ImportedPhoto(
    originalName: originalName,
    storedPath: path,
    sha256: sha256,
    width: width,
    height: height,
    originalOrder: originalOrder,
    exifMake: exifMake,
    exifModel: exifModel,
    exifLensModel: exifLensModel,
    exifFocalLengthMm: exifFocalLengthMm,
  );

  Map<String, Object?> toJson() => {
    'originalName': originalName,
    'storedPath': storedPath,
    'sha256': sha256,
    'width': width,
    'height': height,
    'originalOrder': originalOrder,
    'exifMake': exifMake,
    'exifModel': exifModel,
    'exifLensModel': exifLensModel,
    'exifFocalLengthMm': exifFocalLengthMm,
  };

  factory ImportedPhoto.fromJson(Map<String, Object?> json) => ImportedPhoto(
    originalName: json['originalName']! as String,
    storedPath: json['storedPath']! as String,
    sha256: json['sha256']! as String,
    width: json['width']! as int,
    height: json['height']! as int,
    originalOrder: json['originalOrder']! as int,
    exifMake: json['exifMake'] as String?,
    exifModel: json['exifModel'] as String?,
    exifLensModel: json['exifLensModel'] as String?,
    exifFocalLengthMm: (json['exifFocalLengthMm'] as num?)?.toDouble(),
  );
}
