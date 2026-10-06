enum ExportFormat {
  png('PNG', 'png'),
  tiff('TIFF（大图自动 BigTIFF）', 'tif'),
  jpegXl('JPEG XL（无损）', 'jxl');

  const ExportFormat(this.label, this.extension);

  final String label;
  final String extension;
  String get shortLabel => name.toUpperCase();
  bool get supportedOnMobile => true;
  bool get supportedOnAndroid => true;

  static ExportFormat fromSavedValue(Object? value) => switch (value) {
    'tiff' || 'tif' => ExportFormat.tiff,
    'jpegXl' || 'jpeg-xl' || 'jxl' => ExportFormat.jpegXl,
    _ => ExportFormat.png,
  };

  static ExportFormat fromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.tif') || lower.endsWith('.tiff')) {
      return ExportFormat.tiff;
    }
    if (lower.endsWith('.jxl')) return ExportFormat.jpegXl;
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
