import 'dart:async';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../data/models/enhance_settings.dart';
import '../data/models/quad.dart';
import '../data/repositories/document_repository.dart';
import '../services/cv/cv_worker.dart';

/// Edits one captured page: the crop quad, the filter, and the tone sliders.
///
/// Every change re-renders a downscaled preview off the main thread. Renders
/// are debounced and coalesced so dragging a slider never queues up work the
/// user has already moved past.
class PreviewViewModel extends ChangeNotifier {
  PreviewViewModel({
    required CvWorker worker,
    required String sourcePath,
    Quad? detectedQuad,
    EnhanceSettings settings = const EnhanceSettings(),
  })  : _worker = worker,
        _sourcePath = sourcePath,
        _detectedQuad = detectedQuad,
        _quad = detectedQuad ?? Quad.full,
        _settings = settings,
        _edgesDetected = detectedQuad != null;

  final CvWorker _worker;
  final String _sourcePath;
  final Quad? _detectedQuad;

  /// How long to wait after the last change before re-rendering. One frame of
  /// slider movement is not worth a full pipeline pass.
  static const _debounce = Duration(milliseconds: 180);

  Quad _quad;
  EnhanceSettings _settings;
  Uint8List? _previewBytes;
  bool _processing = false;
  bool _dirty = false;
  final bool _edgesDetected;
  int? _draggingCorner;
  String? _error;

  Timer? _debounceTimer;
  bool _rendering = false;
  bool _renderQueued = false;
  bool _disposed = false;

  String get sourcePath => _sourcePath;
  Quad get quad => _quad;
  EnhanceSettings get settings => _settings;
  Uint8List? get previewBytes => _previewBytes;
  bool get isProcessing => _processing;

  /// True once the user has changed anything — gates the discard prompt.
  bool get isDirty => _dirty;
  bool get edgesDetected => _edgesDetected;
  int? get draggingCorner => _draggingCorner;
  String? get error => _error;

  Future<void> init() => _render();

  /// ── crop ───────────────────────────────────────────────────────────────

  void beginDrag(int cornerIndex) {
    _draggingCorner = cornerIndex;
    notifyListeners();
  }

  /// Moves a corner during a drag. The preview is not re-rendered mid-drag —
  /// only the outline moves — so the gesture stays at display frame rate.
  void dragCornerTo(Offset normalizedPosition) {
    final corner = _draggingCorner;
    if (corner == null) return;
    _quad = _quad.withCorner(corner, normalizedPosition);
    _dirty = true;
    notifyListeners();
  }

  void endDrag() {
    if (_draggingCorner == null) return;
    _draggingCorner = null;
    _scheduleRender();
  }

  void resetToFullFrame() {
    _quad = Quad.full;
    _dirty = true;
    _scheduleRender();
  }

  /// Puts back the outline the detector found, if there was one.
  void resetToDetected() {
    final detected = _detectedQuad;
    if (detected == null) return;
    _quad = detected;
    _dirty = true;
    _scheduleRender();
  }

  bool get canResetToDetected => _detectedQuad != null;

  /// ── enhancement ────────────────────────────────────────────────────────

  void setFilter(ScanFilter filter) {
    if (_settings.filter == filter) return;
    _settings = _settings.copyWith(filter: filter);
    _dirty = true;
    _scheduleRender(immediate: true);
  }

  void setBrightness(int value) {
    if (_settings.brightness == value) return;
    _settings = _settings.copyWith(brightness: value);
    _dirty = true;
    _scheduleRender();
  }

  void setContrast(int value) {
    if (_settings.contrast == value) return;
    _settings = _settings.copyWith(contrast: value);
    _dirty = true;
    _scheduleRender();
  }

  void rotateClockwise() {
    _settings = _settings.copyWith(
      rotationQuarterTurns: (_settings.rotationQuarterTurns + 1) % 4,
    );
    _dirty = true;
    _scheduleRender(immediate: true);
  }

  void resetAdjustments() {
    _settings = _settings.copyWith(brightness: 0, contrast: 0);
    _dirty = true;
    _scheduleRender(immediate: true);
  }

  /// ── rendering ──────────────────────────────────────────────────────────

  void _scheduleRender({bool immediate = false}) {
    notifyListeners();
    _debounceTimer?.cancel();
    if (immediate) {
      unawaited(_render());
    } else {
      _debounceTimer = Timer(_debounce, () => unawaited(_render()));
    }
  }

  Future<void> _render() async {
    // Collapse overlapping requests: the newest settings win, and at most one
    // extra pass runs after the current one.
    if (_rendering) {
      _renderQueued = true;
      return;
    }
    _rendering = true;
    _processing = true;
    _error = null;
    _safeNotify();

    try {
      final bytes = await _worker.renderPreview(
        sourcePath: _sourcePath,
        quad: _quad,
        settings: _settings,
      );
      if (_disposed) return;
      _previewBytes = bytes;
    } catch (error) {
      if (_disposed) return;
      _error = 'Could not apply the filter: $error';
    } finally {
      _rendering = false;
      _processing = false;
      _safeNotify();
      if (_renderQueued && !_disposed) {
        _renderQueued = false;
        unawaited(_render());
      }
    }
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  /// The edited page, ready to hand back to the scan session.
  PendingPage toPendingPage() =>
      PendingPage(sourcePath: _sourcePath, quad: _quad, settings: _settings);

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    super.dispose();
  }
}
