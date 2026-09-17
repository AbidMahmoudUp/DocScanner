import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:opencv_core/opencv.dart' as cv;

import '../../data/models/enhance_settings.dart';
import '../../data/models/quad.dart';
import 'cv_ops.dart';
import 'luma_frame.dart';

/// Names of the jobs the worker isolate understands.
abstract final class _Job {
  static const detectLuma = 'detectLuma';
  static const detectFile = 'detectFile';
  static const previewEnhance = 'previewEnhance';
  static const renderPage = 'renderPage';
}

/// The result of committing one page to disk.
class RenderedPage {
  const RenderedPage({required this.width, required this.height});
  final int width;
  final int height;
}

/// A long-lived isolate that owns all OpenCV work.
///
/// One persistent isolate rather than a `compute()` per frame: live edge
/// detection runs several times a second, and paying isolate spawn cost on
/// every frame would eat the budget the detection itself needs. Jobs are
/// queued and answered by id, so callers just await a Future.
class CvWorker {
  CvWorker._(this._toIsolate, this._isolate, this._fromIsolate);

  final SendPort _toIsolate;
  final Isolate _isolate;
  final ReceivePort _fromIsolate;
  final _pending = <int, Completer<Object?>>{};
  var _nextId = 0;
  var _closed = false;

  static Future<CvWorker> spawn() async {
    final fromIsolate = ReceivePort();
    final ready = Completer<SendPort>();
    late final CvWorker worker;

    final isolate = await Isolate.spawn(_isolateMain, fromIsolate.sendPort, debugName: 'cv-worker');

    fromIsolate.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      final (int id, Object? result, String? error) = message as (int, Object?, String?);
      final completer = worker._pending.remove(id);
      if (completer == null) return;
      if (error != null) {
        completer.completeError(CvWorkerException(error));
      } else {
        completer.complete(result);
      }
    });

    final toIsolate = await ready.future;
    return worker = CvWorker._(toIsolate, isolate, fromIsolate);
  }

  Future<Object?> _send(String job, Map<String, Object?> args) {
    if (_closed) return Future.error(StateError('CvWorker is closed'));
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _toIsolate.send((id, job, args));
    return completer.future;
  }

  /// Detects a page outline in a camera preview frame.
  ///
  /// [quarterTurns] rotates the sensor-oriented frame upright first, so the
  /// returned quad shares the preview widget's coordinate space.
  Future<Quad?> detectInLumaFrame(LumaFrame frame, {required int quarterTurns}) async {
    final result = await _send(_Job.detectLuma, {
      'bytes': frame.bytes,
      'width': frame.width,
      'height': frame.height,
      'quarterTurns': quarterTurns,
    });
    return result == null ? null : Quad.fromFlatList((result as List).cast<double>());
  }

  /// Detects a page outline in a captured JPEG on disk.
  Future<Quad?> detectInFile(String path) async {
    final result = await _send(_Job.detectFile, {'path': path});
    return result == null ? null : Quad.fromFlatList((result as List).cast<double>());
  }

  /// Renders a downscaled enhanced preview as JPEG bytes — small enough to
  /// re-run on every slider tick without stalling the UI.
  Future<Uint8List> renderPreview({
    required String sourcePath,
    required Quad quad,
    required EnhanceSettings settings,
    int maxSide = 1280,
  }) async {
    final result = await _send(_Job.previewEnhance, {
      'path': sourcePath,
      'quad': quad.toFlatList(),
      'settings': settings.toMap(),
      'maxSide': maxSide,
    });
    return result! as Uint8List;
  }

  /// Renders the full-resolution page plus its thumbnail and writes both.
  Future<RenderedPage> renderPage({
    required String sourcePath,
    required Quad quad,
    required EnhanceSettings settings,
    required String outputPath,
    required String thumbnailPath,
  }) async {
    final result = await _send(_Job.renderPage, {
      'path': sourcePath,
      'quad': quad.toFlatList(),
      'settings': settings.toMap(),
      'outputPath': outputPath,
      'thumbnailPath': thumbnailPath,
    }) as List;
    return RenderedPage(width: result[0] as int, height: result[1] as int);
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    for (final completer in _pending.values) {
      completer.completeError(StateError('CvWorker disposed'));
    }
    _pending.clear();
    _isolate.kill(priority: Isolate.immediate);
    _fromIsolate.close();
  }
}

class CvWorkerException implements Exception {
  const CvWorkerException(this.message);
  final String message;
  @override
  String toString() => 'CvWorkerException: $message';
}

/// ── isolate side ─────────────────────────────────────────────────────────

void _isolateMain(SendPort toMain) {
  final fromMain = ReceivePort();
  toMain.send(fromMain.sendPort);

  fromMain.listen((message) {
    final (int id, String job, Map<String, Object?> args) =
        message as (int, String, Map<String, Object?>);
    try {
      toMain.send((id, _runJob(job, args), null));
    } catch (error, stack) {
      toMain.send((id, null, '$error\n$stack'));
    }
  });
}

Object? _runJob(String job, Map<String, Object?> args) {
  switch (job) {
    case _Job.detectLuma:
      return _detectLuma(args);
    case _Job.detectFile:
      return _detectFile(args);
    case _Job.previewEnhance:
      return _previewEnhance(args);
    case _Job.renderPage:
      return _renderPage(args);
    default:
      throw ArgumentError('Unknown job: $job');
  }
}

List<double>? _detectLuma(Map<String, Object?> args) {
  // Already packed and decimated on the sender's side.
  final gray = CvOps.grayFromPackedLuma(
    args['bytes']! as Uint8List,
    args['width']! as int,
    args['height']! as int,
  );
  try {
    final turns = (args['quarterTurns']! as int) % 4;
    final upright = turns == 0 ? gray : _rotateGray(gray, turns);
    try {
      return CvOps.detectQuad(upright)?.toFlatList();
    } finally {
      if (!identical(upright, gray)) upright.dispose();
    }
  } finally {
    gray.dispose();
  }
}

cv.Mat _rotateGray(cv.Mat gray, int quarterTurns) {
  const codes = {
    1: cv.ROTATE_90_CLOCKWISE,
    2: cv.ROTATE_180,
    3: cv.ROTATE_90_COUNTERCLOCKWISE,
  };
  return cv.rotate(gray, codes[quarterTurns]!);
}

List<double>? _detectFile(Map<String, Object?> args) {
  final bgr = _readImage(args['path']! as String);
  try {
    // The capture defines the crop, so it gets the colour-aware detector.
    return CvOps.detectQuadInColour(bgr)?.toFlatList();
  } finally {
    bgr.dispose();
  }
}

Uint8List _previewEnhance(Map<String, Object?> args) {
  final bgr = _readImage(args['path']! as String);
  try {
    // Downscale *before* enhancing: filters on a 12MP frame take seconds, and
    // the preview only ever shows a phone-screen-sized image.
    final small = CvOps.fitTo(bgr, args['maxSide']! as int);
    try {
      final enhanced = CvOps.warpAndEnhance(
        small,
        Quad.fromFlatList((args['quad']! as List).cast<double>()),
        EnhanceSettings.fromMap((args['settings']! as Map).cast<String, dynamic>()),
      );
      try {
        return CvOps.encodeJpeg(enhanced, quality: 85);
      } finally {
        enhanced.dispose();
      }
    } finally {
      small.dispose();
    }
  } finally {
    bgr.dispose();
  }
}

List<int> _renderPage(Map<String, Object?> args) {
  final bgr = _readImage(args['path']! as String);
  try {
    // Bound the working size before the pipeline runs; see
    // CvOps.outputMaxSide for why 300 DPI is the right ceiling.
    final source = CvOps.fitTo(bgr, CvOps.outputMaxSide);
    try {
      final enhanced = CvOps.warpAndEnhance(
        source,
        Quad.fromFlatList((args['quad']! as List).cast<double>()),
        EnhanceSettings.fromMap((args['settings']! as Map).cast<String, dynamic>()),
      );
      try {
        File(args['outputPath']! as String).writeAsBytesSync(CvOps.encodeJpeg(enhanced));
        final thumb = CvOps.fitTo(enhanced, 480);
        try {
          File(args['thumbnailPath']! as String)
              .writeAsBytesSync(CvOps.encodeJpeg(thumb, quality: 80));
        } finally {
          thumb.dispose();
        }
        return [enhanced.cols, enhanced.rows];
      } finally {
        enhanced.dispose();
      }
    } finally {
      source.dispose();
    }
  } finally {
    bgr.dispose();
  }
}

/// Decodes from disk. `imread` applies the EXIF orientation tag, so a portrait
/// capture arrives upright without us tracking the sensor rotation.
cv.Mat _readImage(String path) {
  final mat = cv.imread(path, flags: cv.IMREAD_COLOR);
  if (mat.isEmpty) {
    mat.dispose();
    throw CvWorkerException('Could not decode image at $path');
  }
  return mat;
}
