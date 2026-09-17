import 'dart:math' as math;
import 'dart:typed_data';

/// A packed 8-bit grayscale frame, ready to hand to the detector.
///
/// Camera preview frames arrive as a Y (luma) plane with row padding. On a
/// real device at 1080p that is ~2MB per frame, and every frame would be
/// copied twice — once out of the reused platform buffer, once across the
/// isolate boundary. Detection runs on a downscaled copy anyway, so the
/// decimation happens here, before either copy.
class LumaFrame {
  const LumaFrame({required this.bytes, required this.width, required this.height});

  final Uint8List bytes;
  final int width;
  final int height;

  /// Packs and decimates a camera Y plane so its longest side is at most
  /// [maxSide].
  ///
  /// Nearest-neighbour sampling rather than averaging: the detector blurs the
  /// frame as its first step regardless, so paying for a box filter here would
  /// buy nothing.
  factory LumaFrame.fromPlane(
    Uint8List source,
    int width,
    int height,
    int bytesPerRow, {
    int maxSide = 640,
  }) {
    final step = math.max(1, (math.max(width, height) / maxSide).ceil());
    final outWidth = (width + step - 1) ~/ step;
    final outHeight = (height + step - 1) ~/ step;
    final out = Uint8List(outWidth * outHeight);

    var target = 0;
    for (var y = 0; y < outHeight; y++) {
      final rowStart = y * step * bytesPerRow;
      if (step == 1) {
        // Nothing to drop horizontally — one bulk copy per row beats a
        // per-pixel loop by a wide margin.
        out.setRange(target, target + outWidth, source, rowStart);
        target += outWidth;
        continue;
      }
      for (var x = 0; x < outWidth; x++) {
        out[target++] = source[rowStart + x * step];
      }
    }

    return LumaFrame(bytes: out, width: outWidth, height: outHeight);
  }

  /// Mean intensity, used for the low-light warning.
  ///
  /// Computed on the already-decimated frame, so it costs a fraction of what
  /// sampling the full plane would.
  int get meanLuma {
    if (bytes.isEmpty) return 255;
    var sum = 0;
    for (var i = 0; i < bytes.length; i++) {
      sum += bytes[i];
    }
    return sum ~/ bytes.length;
  }
}
