import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Offset;
import 'package:permission_handler/permission_handler.dart';

import '../data/local/file_storage.dart';
import '../data/models/quad.dart';
import '../services/cv/cv_ops.dart';
import '../services/cv/cv_worker.dart';
import '../services/cv/luma_frame.dart';

enum CameraStatus { idle, requestingPermission, permissionDenied, starting, ready, failed }

enum CaptureMode { auto, manual }

/// What the camera hands to the preview screen after a shot.
class CaptureResult {
  const CaptureResult({required this.path, required this.quad});
  final String path;

  /// The outline detected on the full-resolution capture, or null when the
  /// detector found nothing and the preview should fall back to full frame.
  final Quad? quad;
}

/// Drives the live camera: permission, preview, continuous edge detection,
/// flash, and auto or manual capture.
class CameraViewModel extends ChangeNotifier {
  CameraViewModel({required CvWorker worker, required FileStorage storage})
      : _worker = worker,
        _storage = storage;

  final CvWorker _worker;
  final FileStorage _storage;

  /// How long the outline must hold still before auto-capture fires. Short
  /// enough to feel instant, long enough that a moving hand does not trigger it.
  static const _autoCaptureHold = Duration(milliseconds: 900);

  /// Mean luma below this reads as "too dark to scan well".
  static const _lowLightThreshold = 62;

  CameraController? _controller;
  CameraStatus _status = CameraStatus.idle;
  CaptureMode _mode = CaptureMode.auto;
  FlashMode _flashMode = FlashMode.off;
  Quad? _quad;
  bool _lowLight = false;
  bool _capturing = false;
  String? _errorMessage;

  bool _detecting = false;
  bool _streaming = false;

  /// Auto-capture disarms itself after every shot and only re-arms once the
  /// camera is looking at something else. Without this, a page left under a
  /// steady camera is photographed again the moment the preview resumes,
  /// which turns cancelling a page into an inescapable capture loop.
  bool _autoArmed = true;
  Quad? _lastCapturedQuad;
  Offset? _focusPoint;
  Timer? _focusReticleTimer;
  Quad? _stableSince;
  DateTime? _stableAt;
  Timer? _autoCaptureTimer;
  int _sessionPageNumber = 1;

  CameraController? get controller => _controller;
  CameraStatus get status => _status;
  CaptureMode get mode => _mode;
  FlashMode get flashMode => _flashMode;
  Quad? get quad => _quad;
  bool get hasEdges => _quad != null;
  bool get isLowLight => _lowLight;
  bool get isCapturing => _capturing;
  String? get errorMessage => _errorMessage;
  int get sessionPageNumber => _sessionPageNumber;

  /// Where to draw the focus reticle, for a second after the tap.
  Offset? get focusPoint => _focusPoint;

  /// True when auto mode is on but waiting for a new page before it will fire
  /// again — the camera screen says so rather than looking broken.
  bool get isWaitingForNewPage =>
      _mode == CaptureMode.auto && !_autoArmed && _quad != null;
  bool get isReady => _status == CameraStatus.ready && _controller?.value.isInitialized == true;

  /// Quarter turns needed to bring a sensor-oriented frame upright.
  int get _sensorQuarterTurns => (_controller?.description.sensorOrientation ?? 90) ~/ 90;

  set sessionPageNumber(int value) {
    _sessionPageNumber = value;
    notifyListeners();
  }

  /// ── lifecycle ──────────────────────────────────────────────────────────

  Future<void> start() async {
    if (_status == CameraStatus.starting || isReady) return;
    _status = CameraStatus.requestingPermission;
    _errorMessage = null;
    notifyListeners();

    final permission = await Permission.camera.request();
    if (!permission.isGranted) {
      _status = CameraStatus.permissionDenied;
      notifyListeners();
      return;
    }

    _status = CameraStatus.starting;
    notifyListeners();

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _fail('No camera was found on this device');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        back,
        // veryHigh keeps text legible after the perspective warp without the
        // memory spikes max resolution causes on mid-range phones.
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      await controller.setFlashMode(_flashMode);
      _controller = controller;
      _status = CameraStatus.ready;
      notifyListeners();
      await _startStream();
    } on CameraException catch (error) {
      _fail(error.description ?? 'The camera could not be started');
    } catch (error) {
      _fail('$error');
    }
  }

  void _fail(String message) {
    _status = CameraStatus.failed;
    _errorMessage = message;
    notifyListeners();
  }

  /// Sends the user to the system settings page for this app — the only way
  /// back once the permission was permanently denied.
  Future<void> openSystemSettings() => openAppSettings();

  Future<void> _startStream() async {
    final controller = _controller;
    if (controller == null || _streaming) return;
    try {
      _streaming = true;
      await controller.startImageStream(_onFrame);
    } on CameraException {
      // Android hands the camera to whatever asked for it last, so coming back
      // from the background (or a phone call) can leave a controller that is
      // "initialized" but no longer owns the device. Rebuild it from scratch.
      _streaming = false;
      await _restart();
    }
  }

  /// Tears the controller down and starts over. The only reliable recovery
  /// when the camera service has revoked our handle.
  Future<void> _restart() async {
    final stale = _controller;
    _controller = null;
    _status = CameraStatus.starting;
    notifyListeners();
    try {
      await stale?.dispose();
    } on CameraException {
      // Nothing useful to do; it is going away either way.
    }
    await start();
  }

  Future<void> _stopStream() async {
    final controller = _controller;
    if (controller == null || !_streaming) return;
    _streaming = false;
    try {
      await controller.stopImageStream();
    } on CameraException {
      // Already stopped, e.g. because the controller is being disposed.
    }
  }

  /// ── live detection ─────────────────────────────────────────────────────

  void _onFrame(CameraImage image) {
    // Frames arrive faster than detection can run. Dropping the ones that
    // arrive while a detection is in flight keeps latency flat instead of
    // building an unbounded backlog.
    if (_detecting || _capturing) return;
    _detecting = true;

    final plane = image.planes.first;
    // Decimate here, on the platform's buffer, before anything is copied: at
    // 1080p the raw Y plane is ~2MB a frame, and it would otherwise be copied
    // once out of the reused buffer and again across the isolate boundary.
    final frame = LumaFrame.fromPlane(
      plane.bytes,
      image.width,
      image.height,
      plane.bytesPerRow,
      maxSide: CvOps.detectionMaxSide,
    );
    _lowLight = frame.meanLuma < _lowLightThreshold;

    unawaited(
      _worker
          .detectInLumaFrame(frame, quarterTurns: _sensorQuarterTurns)
          .then(_onQuadDetected)
          .catchError((_) => _onQuadDetected(null))
          .whenComplete(() => _detecting = false),
    );
  }

  void _onQuadDetected(Quad? detected) {
    if (_capturing) return;
    // Ease toward the new outline so the overlay does not twitch between
    // near-identical detections.
    _quad = detected == null
        ? null
        : (_quad == null ? detected : _quad!.lerpTo(detected, 0.5));
    _trackStability(detected);
    notifyListeners();
  }

  /// Auto-capture fires once the outline has stayed put for [_autoCaptureHold].
  void _trackStability(Quad? detected) {
    if (detected == null) {
      // The page left the frame, so whatever we shot last is behind us.
      _autoArmed = true;
      _lastCapturedQuad = null;
    } else if (!_autoArmed &&
        (_lastCapturedQuad == null || !_lastCapturedQuad!.isCloseTo(detected, tolerance: 0.08))) {
      // A different page, or the same one moved — worth shooting again.
      _autoArmed = true;
      _lastCapturedQuad = null;
    }

    if (_mode != CaptureMode.auto || detected == null || !_autoArmed) {
      _stableSince = null;
      _stableAt = null;
      _autoCaptureTimer?.cancel();
      _autoCaptureTimer = null;
      return;
    }

    final reference = _stableSince;
    if (reference == null || !reference.isCloseTo(detected, tolerance: 0.02)) {
      _stableSince = detected;
      _stableAt = DateTime.now();
      _autoCaptureTimer?.cancel();
      _autoCaptureTimer = Timer(_autoCaptureHold, () {
        if (_mode == CaptureMode.auto && _autoArmed && !_capturing && _quad != null) {
          _autoCaptureRequest?.call();
        }
      });
      return;
    }
    _stableAt ??= DateTime.now();
  }

  /// Progress of the auto-capture countdown, 0..1 — drives the shutter ring.
  double get autoCaptureProgress {
    if (_mode != CaptureMode.auto || !_autoArmed || _stableAt == null || _quad == null) return 0;
    final elapsed = DateTime.now().difference(_stableAt!).inMilliseconds;
    return (elapsed / _autoCaptureHold.inMilliseconds).clamp(0.0, 1.0);
  }

  VoidCallback? _autoCaptureRequest;

  /// The view supplies the callback so auto-capture goes through exactly the
  /// same path as a shutter tap, navigation included.
  set onAutoCapture(VoidCallback? callback) => _autoCaptureRequest = callback;

  /// ── controls ───────────────────────────────────────────────────────────

  void setMode(CaptureMode mode) {
    _mode = mode;
    if (mode == CaptureMode.manual) {
      _autoCaptureTimer?.cancel();
      _stableSince = null;
      _stableAt = null;
    }
    notifyListeners();
  }

  /// Focuses and meters on a point in the preview, given in normalized
  /// coordinates. Close-range pages are exactly the case where a phone's
  /// centre-weighted autofocus hunts, so a tap has to be able to pin it.
  Future<void> focusAt(Offset normalizedPoint) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final point = Offset(
      normalizedPoint.dx.clamp(0.0, 1.0),
      normalizedPoint.dy.clamp(0.0, 1.0),
    );
    try {
      await controller.setFocusPoint(point);
      await controller.setExposurePoint(point);
      _focusPoint = point;
      _focusReticleTimer?.cancel();
      // Hide it on its own timer rather than leaning on detection ticks to
      // rebuild the screen — detection can legitimately go quiet.
      _focusReticleTimer = Timer(const Duration(seconds: 1), () {
        _focusPoint = null;
        notifyListeners();
      });
      notifyListeners();
    } on CameraException {
      // Plenty of devices expose no focus-point control; the tap is simply a
      // no-op there rather than an error worth showing.
    }
  }

  Future<void> cycleFlash() async {
    const order = [FlashMode.off, FlashMode.auto, FlashMode.always];
    _flashMode = order[(order.indexOf(_flashMode) + 1) % order.length];
    notifyListeners();
    try {
      await _controller?.setFlashMode(_flashMode);
    } on CameraException {
      // Some devices refuse torch modes; keep the UI in sync with reality.
      _flashMode = FlashMode.off;
      notifyListeners();
    }
  }

  /// Takes a full-resolution picture, moves it into app storage and re-runs
  /// detection on it — the capture is sharper than the preview frames, so its
  /// outline is the one worth editing.
  Future<CaptureResult?> capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) return null;

    _capturing = true;
    _autoCaptureTimer?.cancel();
    _autoArmed = false;
    _lastCapturedQuad = _quad;
    notifyListeners();

    try {
      await _stopStream();
      final shot = await controller.takePicture();
      final destination = _storage.newCapturePath();
      await File(shot.path).copy(destination);
      await File(shot.path).delete().catchError((_) => File(shot.path));

      final quad = await _worker.detectInFile(destination);
      return CaptureResult(path: destination, quad: quad);
    } on CameraException catch (error) {
      _errorMessage = error.description ?? 'The capture failed';
      notifyListeners();
      return null;
    } catch (error) {
      _errorMessage = '$error';
      notifyListeners();
      return null;
    } finally {
      _capturing = false;
      notifyListeners();
    }
  }

  /// Restarts the live preview after returning from the preview screen.
  Future<void> resume() async {
    _quad = null;
    _stableSince = null;
    _stableAt = null;
    // _autoArmed and _lastCapturedQuad deliberately survive: re-arming is the
    // detector's call once it sees a different page.
    if (_controller?.value.isInitialized == true) {
      await _startStream();
    } else {
      await start();
    }
  }

  Future<void> pause() => _stopStream();

  @override
  void dispose() {
    _autoCaptureTimer?.cancel();
    _focusReticleTimer?.cancel();
    _autoCaptureRequest = null;
    final controller = _controller;
    _controller = null;
    unawaited(() async {
      if (controller == null) return;
      if (_streaming) {
        _streaming = false;
        try {
          await controller.stopImageStream();
        } on CameraException {
          // Ignored: the controller is going away regardless.
        }
      }
      await controller.dispose();
    }());
    super.dispose();
  }
}
