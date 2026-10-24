enum ExportFormat {
  png('PNG（无损）', 'png'),
  tiff('TIFF（无损，大图自动 BigTIFF）', 'tif'),
  jpeg('JPEG（有损，质量 90）', 'jpg'),
  jpegXl('JPEG XL（有损）', 'jxl');

  const ExportFormat(this.label, this.extension);

  final String label;
  final String extension;
  String get shortLabel => switch (this) {
    ExportFormat.png => 'PNG',
    ExportFormat.tiff => 'TIFF',
    ExportFormat.jpeg => 'JPEG',
    ExportFormat.jpegXl => 'JPEG XL',
  };
  bool get supportedOnMobile => true;
  bool get supportedOnAndroid => true;

  static ExportFormat fromSavedValue(Object? value) => switch (value) {
    'tiff' || 'tif' => ExportFormat.tiff,
    'jpeg' || 'jpg' => ExportFormat.jpeg,
    'jpegXl' || 'jpeg-xl' || 'jxl' => ExportFormat.jpegXl,
    _ => ExportFormat.png,
  };

  static ExportFormat fromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.tif') || lower.endsWith('.tiff')) {
      return ExportFormat.tiff;
    }
    if (lower.endsWith('.jxl')) return ExportFormat.jpegXl;
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return ExportFormat.jpeg;
    }
    return ExportFormat.png;
  }
}

enum SeamBlendMode {
  feather,
  deghost;

  static SeamBlendMode fromSavedValue(Object? value) => switch (value) {
    'deghost' => SeamBlendMode.deghost,
    _ => SeamBlendMode.feather,
  };
}
