import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:doc_scanner/data/models/quad.dart';
import 'package:doc_scanner/services/cv/cv_ops.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:opencv_core/opencv.dart' as cv;

/// Detection accuracy against scenes with a known page outline.
///
/// Every case here is one that a grayscale-only, first-strategy-wins detector
/// gets wrong: paper on a surface of similar brightness, a steep angle, a
/// shadow falling across the sheet.

const _sceneWidth = 720;
const _sceneHeight = 960;

/// How far, on average, each detected corner may sit from the truth —
/// as a fraction of the frame.
const _tolerance = 0.035;

/// Desk colours. The wood tones are the interesting ones: in grayscale a light
/// oak desk and a white page are nearly the same brightness, but their
/// saturation is completely different.
const _darkWood = [34, 44, 58]; // BGR
const _lightOak = [150, 186, 214];
const _greyTable = [186, 188, 190];
const _tealCloth = [140, 120, 40];

/// A bright saturated surface with roughly the same luminance as paper. In
/// grayscale it is nearly invisible against the page; in colour it is obvious.
const _yellowDesk = [40, 226, 240];

/// Builds the page content: paper with text lines and a coloured stamp.
cv.Mat _pageContent() {
  const width = 600;
  const height = 800;
  final bytes = Uint8List(width * height * 3);

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var b = 240, g = 242, r = 244; // slightly cool white paper

      // Body text.
      if (y > 90 && y < height - 120 && y % 34 < 5 && x > 60 && x < width - 70) {
        b = 60;
        g = 58;
        r = 56;
      }
      // Heading.
      if (y > 40 && y < 58 && x > 60 && x < 380) {
        b = 30;
        g = 28;
        r = 26;
      }
      // A red stamp, so colour handling is observable.
      final dx = x - 470.0;
      final dy = y - 700.0;
      if (dx * dx + dy * dy < 55 * 55 && dx * dx + dy * dy > 38 * 38) {
        b = 48;
        g = 40;
        r = 196;
      }

      final i = (y * width + x) * 3;
      bytes[i] = b;
      bytes[i + 1] = g;
      bytes[i + 2] = r;
    }
  }
  return cv.Mat.fromList(height, width, cv.MatType.CV_8UC3, bytes);
}

/// Composes a photo: the page warped onto a desk, then lit unevenly.
cv.Mat buildScene({
  required Quad page,
  required List<int> desk,
  bool woodGrain = true,
  bool shadow = false,
}) {
  const w = _sceneWidth;
  const h = _sceneHeight;

  final content = _pageContent();
  final source = cv.VecPoint.fromList([
    cv.Point(0, 0),
    cv.Point(content.cols - 1, 0),
    cv.Point(content.cols - 1, content.rows - 1),
    cv.Point(0, content.rows - 1),
  ]);
  final target = cv.VecPoint.fromList([
    for (final corner in page.toPixels(Size(w.toDouble(), h.toDouble())))
      cv.Point(corner.dx.round(), corner.dy.round()),
  ]);
  final transform = cv.getPerspectiveTransform(source, target);

  final warped = cv.warpPerspective(content, transform, (w, h));
  final solid = cv.Mat.fromList(
    content.rows,
    content.cols,
    cv.MatType.CV_8UC1,
    Uint8List(content.rows * content.cols)..fillRange(0, content.rows * content.cols, 255),
  );
  final mask = cv.warpPerspective(solid, transform, (w, h));

  final warpedData = warped.data;
  final maskData = mask.data;
  final out = Uint8List(w * h * 3);

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final flat = y * w + x;
      final i = flat * 3;

      int b, g, r;
      if (maskData[flat] != 0) {
        b = warpedData[i];
        g = warpedData[i + 1];
        r = warpedData[i + 2];
      } else {
        final grain = woodGrain ? ((y ~/ 7) % 5) * 6 - 12 : 0;
        b = (desk[0] + grain).clamp(0, 255);
        g = (desk[1] + grain).clamp(0, 255);
        r = (desk[2] + grain).clamp(0, 255);
      }

      var light = 1.04 - 0.22 * (x / w) - 0.14 * (y / h);
      if (shadow && x / w + y / h > 1.15) light *= 0.55;

      out[i] = (b * light).clamp(0, 255).round();
      out[i + 1] = (g * light).clamp(0, 255).round();
      out[i + 2] = (r * light).clamp(0, 255).round();
    }
  }

  content.dispose();
  source.dispose();
  target.dispose();
  transform.dispose();
  warped.dispose();
  solid.dispose();
  mask.dispose();
  return cv.Mat.fromList(h, w, cv.MatType.CV_8UC3, out);
}

/// Mean distance between corresponding corners, in frame fractions.
double cornerError(Quad found, Quad truth) {
  var sum = 0.0;
  for (var i = 0; i < 4; i++) {
    sum += (found.corners[i] - truth.corners[i]).distance;
  }
  return sum / 4;
}

/// A page filling most of the frame, shot square on.
const _square = Quad(
  Offset(0.12, 0.10),
  Offset(0.88, 0.10),
  Offset(0.88, 0.90),
  Offset(0.12, 0.90),
);

/// Shot from the side, so the far edge is noticeably shorter.
const _skewed = Quad(
  Offset(0.20, 0.14),
  Offset(0.86, 0.08),
  Offset(0.92, 0.88),
  Offset(0.11, 0.80),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('page detection', () {
    void expectDetected(
      String label, {
      required Quad truth,
      required List<int> desk,
      bool woodGrain = true,
      bool shadow = false,
      double tolerance = _tolerance,
    }) {
      final scene = buildScene(
        page: truth,
        desk: desk,
        woodGrain: woodGrain,
        shadow: shadow,
      );
      addTearDown(scene.dispose);

      final found = CvOps.detectQuadInColour(scene);
      expect(found, isNotNull, reason: '$label: no page found at all');

      final error = cornerError(found!, truth);
      String show(Quad q) => q.corners
          .map((c) => '(${c.dx.toStringAsFixed(2)},${c.dy.toStringAsFixed(2)})')
          .join(' ');
      // ignore: avoid_print
      print('DETECT $label error=${(error * 100).toStringAsFixed(2)}%');
      if (error >= tolerance) {
        // ignore: avoid_print
        print('  found ${show(found)}');
        // ignore: avoid_print
        print('  truth ${show(truth)}');
      }
      expect(error, lessThan(tolerance),
          reason: '$label: corners off by ${(error * 100).toStringAsFixed(1)}% of the frame');
    }

    test('page on a dark desk', () {
      expectDetected('dark wood', truth: _square, desk: _darkWood);
    });

    test('page on light oak — little brightness contrast, lots of colour contrast', () {
      // The case a grayscale-only detector cannot see.
      expectDetected('light oak', truth: _square, desk: _lightOak);
    });

    test('page on a grey table — very low contrast either way', () {
      expectDetected('grey table', truth: _square, desk: _greyTable, woodGrain: false);
    });

    test('page on coloured cloth', () {
      expectDetected('teal cloth', truth: _square, desk: _tealCloth, woodGrain: false);
    });

    test('page shot at a steep angle', () {
      expectDetected('skewed', truth: _skewed, desk: _darkWood);
    });

    test('page with a shadow falling across it', () {
      expectDetected('shadowed', truth: _square, desk: _darkWood, shadow: true);
    });

    test('skewed page on light oak with a shadow — everything at once', () {
      expectDetected('worst case', truth: _skewed, desk: _lightOak, shadow: true);
    });

    test('nothing is reported when there is no page', () {
      // An empty desk must not produce a confident outline, or auto-capture
      // would fire at nothing.
      final bytes = Uint8List(_sceneWidth * _sceneHeight * 3);
      for (var i = 0; i < _sceneWidth * _sceneHeight; i++) {
        final grain = ((i ~/ _sceneWidth ~/ 7) % 5) * 6 - 12;
        bytes[i * 3] = (_darkWood[0] + grain).clamp(0, 255);
        bytes[i * 3 + 1] = (_darkWood[1] + grain).clamp(0, 255);
        bytes[i * 3 + 2] = (_darkWood[2] + grain).clamp(0, 255);
      }
      final scene = cv.Mat.fromList(_sceneHeight, _sceneWidth, cv.MatType.CV_8UC3, bytes);
      addTearDown(scene.dispose);

      expect(CvOps.detectQuadInColour(scene), isNull,
          reason: 'an empty desk should not look like a page');
    });

    test('page on an equiluminant coloured desk', () {
      // Same brightness as the paper, so only colour can separate them.
      expectDetected('yellow desk', truth: _square, desk: _yellowDesk, woodGrain: false);
    });

    test('colour earns its place on an equiluminant desk', () {
      // Reported, not asserted as a fixed margin, so the numbers stay honest
      // if tuning shifts later.
      final scene = buildScene(page: _square, desk: _yellowDesk, woodGrain: false);
      final gray = cv.cvtColor(scene, cv.COLOR_BGR2GRAY);
      addTearDown(scene.dispose);
      addTearDown(gray.dispose);

      final luma = CvOps.detectQuad(gray);
      final colour = CvOps.detectQuadInColour(scene);

      final lumaError = luma == null ? double.nan : cornerError(luma, _square);
      final colourError = colour == null ? double.nan : cornerError(colour, _square);
      // ignore: avoid_print
      print('DETECT yellow desk: luma=${luma == null ? "not found" : "${(lumaError * 100).toStringAsFixed(2)}%"} '
          'colour=${colour == null ? "not found" : "${(colourError * 100).toStringAsFixed(2)}%"}');

      expect(colour, isNotNull, reason: 'colour detection should handle an equiluminant desk');
      expect(colourError, lessThan(_tolerance));
    });

    test('the luma-only path used by the live preview still works', () {
      // Live frames carry no colour, so this path has to stand on its own.
      final scene = buildScene(page: _square, desk: _darkWood);
      final gray = cv.cvtColor(scene, cv.COLOR_BGR2GRAY);
      addTearDown(scene.dispose);
      addTearDown(gray.dispose);

      final found = CvOps.detectQuad(gray);
      expect(found, isNotNull, reason: 'live path found no page on an easy scene');
      final error = cornerError(found!, _square);
      // ignore: avoid_print
      print('DETECT luma-only error=${(error * 100).toStringAsFixed(2)}% of frame');
      expect(error, lessThan(_tolerance));
    });
  });

  group('sanity', () {
    test('cornerError measures what it claims to', () {
      expect(cornerError(_square, _square), closeTo(0, 1e-9));
      final shifted = Quad(
        _square.topLeft + const Offset(0.1, 0),
        _square.topRight + const Offset(0.1, 0),
        _square.bottomRight + const Offset(0.1, 0),
        _square.bottomLeft + const Offset(0.1, 0),
      );
      expect(cornerError(shifted, _square), closeTo(0.1, 1e-9));
    });
  });
}
