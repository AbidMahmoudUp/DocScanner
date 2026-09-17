import 'dart:math' as math;
import 'dart:typed_data';

import 'package:doc_scanner/data/models/enhance_settings.dart';
import 'package:doc_scanner/data/models/quad.dart';
import 'package:doc_scanner/services/cv/cv_ops.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:opencv_core/opencv.dart' as cv;

/// Runs the real OpenCV pipeline on the device.
///
/// The native library is only built for Android, so a host `flutter test`
/// cannot load it — and a desktop Python equivalent turned out not to predict
/// this binding's behaviour, which is exactly how the morphology border bug
/// slipped through.

const _width = 900;
const _height = 1200;

/// Regions of the synthetic page, as fractions of it. Text is deliberately
/// kept out of the two paper patches so they measure paper and nothing else.
const _logo = Region(0.08, 0.06, 0.34, 0.18);

/// Paper in the brightly lit corner.
const _paperBright = Region(0.55, 0.06, 0.92, 0.17);

/// Paper in the shadowed corner. Shadow removal is judged by how close this
/// ends up to [_paperBright].
const _paperShadowed = Region(0.60, 0.86, 0.95, 0.97);

const _body = Region(0.10, 0.30, 0.90, 0.80);

/// A saturated red stamp, so colour handling is directly observable.
const _stamp = Region(0.62, 0.22, 0.82, 0.28);

class Region {
  const Region(this.left, this.top, this.right, this.bottom);
  final double left, top, right, bottom;

  ({int x0, int y0, int x1, int y1}) pixels(int width, int height) => (
        x0: (left * width).round(),
        y0: (top * height).round(),
        x1: (right * width).round(),
        y1: (bottom * height).round(),
      );
}

/// A page with a solid logo block, body text, grey paper, a brightness
/// gradient and a hard shadow across the lower right — i.e. a phone photo.
///
/// Text stops at 80% height so the bottom band is clean paper under shadow.
cv.Mat buildShadowedPage() {
  final bytes = Uint8List(_width * _height * 3);
  final logo = _logo.pixels(_width, _height);

  for (var y = 0; y < _height; y++) {
    for (var x = 0; x < _width; x++) {
      var value = 236; // paper

      if (x >= logo.x0 && x < logo.x1 && y >= logo.y0 && y < logo.y1) value = 18;

      final stamp = _stamp.pixels(_width, _height);
      final inStamp =
          x >= stamp.x0 && x < stamp.x1 && y >= stamp.y0 && y < stamp.y1;

      final inBodyBand = y > _height * 0.30 && y < _height * 0.80;
      if (inBodyBand && y % 40 < 5 && x > _width * 0.1 && x < _width * 0.9) {
        value = 60;
      }

      var light = 1.05 - 0.40 * (x / _width) - 0.22 * (y / _height);
      if (x / _width + y / _height > 1.25) light *= 0.52;

      final index = (y * _width + x) * 3;
      if (inStamp) {
        // Strong red: low blue and green, high red.
        bytes[index] = (40 * light).clamp(0.0, 255.0).round();
        bytes[index + 1] = (36 * light).clamp(0.0, 255.0).round();
        bytes[index + 2] = (200 * light).clamp(0.0, 255.0).round();
      } else {
        final lit = (value * light).clamp(0.0, 255.0).round();
        bytes[index] = lit;
        bytes[index + 1] = lit;
        bytes[index + 2] = lit;
      }
    }
  }

  return cv.Mat.fromList(_height, _width, cv.MatType.CV_8UC3, bytes);
}

/// Mean brightness of a region of a BGR Mat.
double meanOf(cv.Mat bgr, Region region) {
  final area = region.pixels(bgr.cols, bgr.rows);
  final data = bgr.data;
  var sum = 0;
  var count = 0;
  for (var y = area.y0; y < area.y1; y++) {
    for (var x = area.x0; x < area.x1; x++) {
      sum += data[(y * bgr.cols + x) * 3];
      count++;
    }
  }
  return count == 0 ? 0 : sum / count;
}

/// Mean of one channel (0=B, 1=G, 2=R) over a region.
double meanChannel(cv.Mat bgr, Region region, int channel) {
  final area = region.pixels(bgr.cols, bgr.rows);
  final data = bgr.data;
  var sum = 0;
  var count = 0;
  for (var y = area.y0; y < area.y1; y++) {
    for (var x = area.x0; x < area.x1; x++) {
      sum += data[(y * bgr.cols + x) * 3 + channel];
      count++;
    }
  }
  return count == 0 ? 0 : sum / count;
}

/// How far apart the extreme channels are — how much colour is left.
double colourfulness(cv.Mat bgr, Region region) {
  final b = meanChannel(bgr, region, 0);
  final g = meanChannel(bgr, region, 1);
  final r = meanChannel(bgr, region, 2);
  return math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
}

/// How much brighter lit paper is than shadowed paper. Near zero means the
/// illumination has been divided out.
double shadowResidue(cv.Mat bgr) =>
    (meanOf(bgr, _paperBright) - meanOf(bgr, _paperShadowed)).abs();

/// Spread of tones in a region. Rises as ink and paper separate, which is what
/// contrast is for — the mean barely moves, because pushing paper up and ink
/// down cancel out.
double spreadOf(cv.Mat bgr, Region region) {
  final area = region.pixels(bgr.cols, bgr.rows);
  final data = bgr.data;
  final samples = <int>[];
  for (var y = area.y0; y < area.y1; y += 3) {
    for (var x = area.x0; x < area.x1; x += 3) {
      samples.add(data[(y * bgr.cols + x) * 3]);
    }
  }
  if (samples.isEmpty) return 0;
  final mean = samples.reduce((a, b) => a + b) / samples.length;
  final variance =
      samples.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / samples.length;
  return math.sqrt(variance);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('document enhancement', () {
    late cv.Mat source;

    setUp(() => source = buildShadowedPage());
    tearDown(() => source.dispose());

    cv.Mat enhance(ScanFilter filter, {int brightness = 0, int contrast = 0}) {
      final result = CvOps.warpAndEnhance(
        source,
        Quad.full,
        EnhanceSettings(filter: filter, brightness: brightness, contrast: contrast),
      );
      addTearDown(result.dispose);
      return result;
    }

    test('the fixture really is a badly lit photo', () {
      // Guards the test itself: if the fixture stops being shadowed, every
      // assertion below stops meaning anything.
      expect(meanOf(source, _paperBright), lessThan(220),
          reason: 'paper should start off grey, not white');
      expect(shadowResidue(source), greaterThan(60),
          reason: 'the fixture should carry a strong shadow');
      expect(meanOf(source, _logo), lessThan(40), reason: 'the logo should start solid');
    });

    test('Document whitens paper, removes the shadow and keeps solid ink solid', () {
      final result = enhance(ScanFilter.document);

      expect(meanOf(result, _paperBright), greaterThan(245),
          reason: 'lit paper should come out white');
      expect(meanOf(result, _paperShadowed), greaterThan(235),
          reason: 'shadowed paper should come out white too');
      expect(shadowResidue(result), lessThan(12),
          reason: 'the shadow should be gone, not merely lightened');
      // The point of the two-stage background estimate: a solid block must not
      // be mistaken for paper and divided away into a white box.
      expect(meanOf(result, _logo), lessThan(40), reason: 'solid logo was hollowed out');
    });

    test('Magic colour makes the same correction', () {
      final result = enhance(ScanFilter.magicColor);
      expect(meanOf(result, _paperBright), greaterThan(240));
      expect(shadowResidue(result), lessThan(15));
      expect(meanOf(result, _logo), lessThan(40));
    });

    test('B&W gives a clean two-tone page without hollowing the logo', () {
      final result = enhance(ScanFilter.blackWhite);
      expect(meanOf(result, _paperBright), greaterThan(250));
      expect(meanOf(result, _paperShadowed), greaterThan(250));
      // Adaptive thresholding alone turns the inside of a solid block white,
      // because every neighbour there is ink too.
      expect(meanOf(result, _logo), lessThan(40), reason: 'solid logo was hollowed out');
    });

    test('Colour keeps a red stamp red', () {
      // The default filter, and the whole reason it is the default: throwing
      // colour away is destructive and cannot be undone from the saved page.
      final result = enhance(ScanFilter.magicColor);

      expect(colourfulness(result, _stamp), greaterThan(70),
          reason: 'the stamp lost its colour');
      expect(meanChannel(result, _stamp, 2), greaterThan(meanChannel(result, _stamp, 0) + 70),
          reason: 'the stamp should still read as red, not grey');
      // Paper must not pick up a cast from the saturation lift.
      expect(colourfulness(result, _paperBright), lessThan(14),
          reason: 'paper should stay neutral');
    });

    test('Colour keeps more colour than the source had, not less', () {
      // Dividing the illumination out pulls channels toward the paper white
      // point, which desaturates. The saturation lift is there to pay that
      // back, so the stamp should not come out flatter than it went in.
      final before = colourfulness(source, _stamp);
      final after = colourfulness(enhance(ScanFilter.magicColor), _stamp);
      expect(after, greaterThan(before * 0.9),
          reason: 'flattening desaturated the stamp: $before -> $after');
    });

    test('Mono deliberately discards colour', () {
      final result = enhance(ScanFilter.document);
      expect(colourfulness(result, _stamp), lessThan(6),
          reason: 'Mono should be neutral everywhere');
    });

    test('Original is left alone apart from tone', () {
      final result = enhance(ScanFilter.original);
      // No flattening, so the shadow must still be there — this is what makes
      // Original meaningfully different from the rest.
      expect(shadowResidue(result), greaterThan(40));
    });

    test('brightness moves the result in both directions', () {
      final neutral = meanOf(enhance(ScanFilter.document), _body);
      final darker = meanOf(enhance(ScanFilter.document, brightness: -30), _body);
      final brighter = meanOf(enhance(ScanFilter.document, brightness: 30), _body);

      expect(darker, lessThan(neutral - 3), reason: 'negative brightness should darken');
      expect(brighter, greaterThan(neutral), reason: 'positive brightness should lighten');
    });

    test('contrast separates ink from paper without greying the page', () {
      final soft = enhance(ScanFilter.document, contrast: -40);
      final neutral = enhance(ScanFilter.document);
      final punchy = enhance(ScanFilter.document, contrast: 40);

      // Contrast is about separation: the mean hardly moves, because paper
      // rising and ink falling cancel each other out.
      expect(spreadOf(punchy, _body), greaterThan(spreadOf(neutral, _body)),
          reason: 'more contrast should push ink and paper further apart');
      expect(spreadOf(soft, _body), lessThan(spreadOf(neutral, _body)),
          reason: 'less contrast should bring them closer');
      expect(meanOf(punchy, _paperBright), greaterThan(245),
          reason: 'paper should stay white');
    });
  });
}
