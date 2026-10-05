class PerformanceOptions {
  const PerformanceOptions({
    this.parallelMatching = true,
    this.parallelRendering = true,
    this.useSourceCache = true,
    this.useAlignmentCache = true,
    this.fourNeighborFirst = false,
    this.fastRegistration = false,
    this.flannMatching = false,
    this.orbFeatures = false,
  });

  final bool parallelMatching;
  final bool parallelRendering;
  final bool useSourceCache;
  final bool useAlignmentCache;
  final bool fourNeighborFirst;
  final bool fastRegistration;
  final bool flannMatching;
  final bool orbFeatures;

  PerformanceOptions copyWith({
    bool? parallelMatching,
    bool? parallelRendering,
    bool? useSourceCache,
    bool? useAlignmentCache,
    bool? fourNeighborFirst,
    bool? fastRegistration,
    bool? flannMatching,
    bool? orbFeatures,
  }) => PerformanceOptions(
    parallelMatching: parallelMatching ?? this.parallelMatching,
    parallelRendering: parallelRendering ?? this.parallelRendering,
    useSourceCache: useSourceCache ?? this.useSourceCache,
    useAlignmentCache: useAlignmentCache ?? this.useAlignmentCache,
    fourNeighborFirst: fourNeighborFirst ?? this.fourNeighborFirst,
    fastRegistration: fastRegistration ?? this.fastRegistration,
    flannMatching: flannMatching ?? this.flannMatching,
    orbFeatures: orbFeatures ?? this.orbFeatures,
  );

  Map<String, Object?> toJson() => {
    'parallelMatching': parallelMatching,
    'parallelRendering': parallelRendering,
    'useSourceCache': useSourceCache,
    'useAlignmentCache': useAlignmentCache,
    'fourNeighborFirst': fourNeighborFirst,
    'fastRegistration': fastRegistration,
    'flannMatching': effectiveFlannMatching,
    'orbFeatures': orbFeatures,
  };

  factory PerformanceOptions.fromJson(Map<String, Object?>? json) {
    if (json == null) return const PerformanceOptions();
    return PerformanceOptions(
      parallelMatching: json['parallelMatching'] as bool? ?? true,
      parallelRendering: json['parallelRendering'] as bool? ?? true,
      useSourceCache: json['useSourceCache'] as bool? ?? true,
      useAlignmentCache: json['useAlignmentCache'] as bool? ?? true,
      fourNeighborFirst: json['fourNeighborFirst'] as bool? ?? false,
      fastRegistration: json['fastRegistration'] as bool? ?? false,
      flannMatching:
          (json['flannMatching'] as bool? ?? false) &&
          !(json['orbFeatures'] as bool? ?? false),
      orbFeatures: json['orbFeatures'] as bool? ?? false,
    );
  }

  String get featureType => orbFeatures ? 'orb' : 'sift';
  String get matcherType => flannMatching && !orbFeatures ? 'flann' : 'bf';
  bool get effectiveFlannMatching => flannMatching && !orbFeatures;
  double get registrationMegapixels => fastRegistration ? 0.6 : 2.0;
  String get neighborMode => fourNeighborFirst ? 'adaptive' : 'eight';
  PerformanceOptions get normalized =>
      orbFeatures && flannMatching ? copyWith(flannMatching: false) : this;
}
