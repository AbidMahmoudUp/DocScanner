/// The enhancement presets offered on the preview screen.
enum ScanFilter {
  /// Straight off the camera, perspective-corrected only.
  original('Original'),

  /// The default: shadows removed, paper white, text sharpened, colour kept.
  ///
  /// Colour is the default because throwing it away is destructive and cannot
  /// be undone from the saved page — a stamp, a signature, a highlighted line
  /// or a coloured logo is often the point of keeping the document at all.
  magicColor('Colour'),

  /// The same correction rendered mono, for plain text.
  document('Mono'),

  grayscale('Grayscale'),

  /// Pure black on white, for dense text and for OCR later.
  blackWhite('B&W text');

  const ScanFilter(this.label);
  final String label;

  static ScanFilter fromName(String? name) =>
      ScanFilter.values.firstWhere((f) => f.name == name, orElse: () => ScanFilter.original);
}

/// Everything the OpenCV pipeline needs to turn a raw capture into a page.
class EnhanceSettings {
  const EnhanceSettings({
    this.filter = ScanFilter.magicColor,
    this.brightness = 0,
    this.contrast = 0,
    this.rotationQuarterTurns = 0,
  });

  final ScanFilter filter;

  /// -50..50, mapped to an additive offset in the pipeline.
  final int brightness;

  /// -50..50, mapped to a multiplicative gain in the pipeline.
  final int contrast;

  /// Clockwise quarter turns applied after the perspective warp.
  final int rotationQuarterTurns;

  bool get isDefault =>
      filter == ScanFilter.magicColor &&
      brightness == 0 &&
      contrast == 0 &&
      rotationQuarterTurns == 0;

  EnhanceSettings copyWith({
    ScanFilter? filter,
    int? brightness,
    int? contrast,
    int? rotationQuarterTurns,
  }) => EnhanceSettings(
    filter: filter ?? this.filter,
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    rotationQuarterTurns: rotationQuarterTurns ?? this.rotationQuarterTurns,
  );

  Map<String, dynamic> toMap() => {
    'filter': filter.name,
    'brightness': brightness,
    'contrast': contrast,
    'rotation': rotationQuarterTurns,
  };

  factory EnhanceSettings.fromMap(Map<String, dynamic> map) => EnhanceSettings(
    filter: ScanFilter.fromName(map['filter'] as String?),
    brightness: (map['brightness'] as int?) ?? 0,
    contrast: (map['contrast'] as int?) ?? 0,
    rotationQuarterTurns: (map['rotation'] as int?) ?? 0,
  );

  @override
  bool operator ==(Object other) =>
      other is EnhanceSettings &&
      other.filter == filter &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.rotationQuarterTurns == rotationQuarterTurns;

  @override
  int get hashCode => Object.hash(filter, brightness, contrast, rotationQuarterTurns);
}
