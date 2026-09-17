import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:opencv_core/opencv.dart' as cv;

import '../../data/models/enhance_settings.dart';
import '../../data/models/quad.dart';

/// One proposed page outline, and whether it came from a measured polygon or
/// from the rotated-rectangle fallback.
class _Candidate {
  const _Candidate(this.quad, {required this.isFallback});
  final Quad quad;
  final bool isFallback;
}

/// Pure OpenCV work. Every function here is synchronous, allocates and frees
/// its own Mats, and is safe to call from a background isolate — nothing in
/// this file touches Flutter bindings.
abstract final class CvOps {
  /// Longest edge used for detection. Accuracy plateaus well before full
  /// resolution, and the quad is normalized anyway.
  static const detectionMaxSide = 640;

  /// Longest edge of a saved page.
  ///
  /// 2400px is roughly 300 DPI across A4 — the standard scan resolution, and
  /// past the point where more pixels make a document more readable. Capping
  /// here also bounds peak memory: a 12MP capture would otherwise hold the
  /// decoded source, the warp and the filter output simultaneously, which is
  /// where mid-range phones run out of heap.
  static const outputMaxSide = 2400;

  /// A page must cover at least this fraction of the frame to count. Below it,
  /// we are almost certainly locking onto a logo or a photo on the page.
  static const _minAreaFraction = 0.10;

  /// Minimum score for an outline to be offered at all. Tuned so that a page
  /// with one weakly lit edge still passes, while a table edge or a shadow
  /// line does not.
  static const _minScore = 0.05;

  /// ...and no more than this. Blurring and morphology both extend past the
  /// image boundary, which leaves an artificial edge all the way around the
  /// frame; that border traces a perfect rectangle covering everything, and
  /// being the largest contour it would beat the real page every time.
  /// Anything this close to the full frame is that artifact, not a document.
  static const _maxAreaFraction = 0.97;

  /// ── detection ──────────────────────────────────────────────────────────
  ///
  /// Finds the page outline by proposing candidates from several independent
  /// segmentations and then scoring them all against one shared edge map.
  ///
  /// A single strategy is never reliable across real scenes: Canny finds crisp
  /// borders on a contrasting surface but disappears on white-on-white, Otsu
  /// handles low contrast but smears when the lighting is uneven, and neither
  /// notices that a brown desk and white paper are obviously different colours.
  /// Taking the first strategy that returns anything — which is what this used
  /// to do — means a poor answer from an early strategy beats a good answer
  /// from a later one. Proposing and then scoring fixes the ordering problem.
  ///
  /// Returns null when nothing scores well enough, which the camera surfaces
  /// as "no edges detected" rather than guessing.
  static Quad? detectQuad(cv.Mat gray) {
    final work = _fitTo(gray, detectionMaxSide);
    try {
      return _detectIn(work, null);
    } finally {
      if (!identical(work, gray)) work.dispose();
    }
  }

  /// Detection with the colour image available.
  ///
  /// Worth a separate entry point because colour is the strongest cue there
  /// is: paper is bright *and* almost unsaturated, which separates it from a
  /// wooden desk or a patterned surface that looks nearly identical in
  /// grayscale. Live preview frames only carry luma, so they cannot use this —
  /// but the capture can, and the capture is what defines the crop.
  static Quad? detectQuadInColour(cv.Mat bgr) {
    final work = _fitTo(bgr, detectionMaxSide);
    final gray = cv.cvtColor(work, cv.COLOR_BGR2GRAY);
    try {
      return _detectIn(gray, work);
    } finally {
      gray.dispose();
      if (!identical(work, bgr)) work.dispose();
    }
  }

  static Quad? _detectIn(cv.Mat gray, cv.Mat? colour) {
    final size = Size(gray.cols.toDouble(), gray.rows.toDouble());

    // Remove the lighting falloff first. Without this, a global threshold
    // cannot separate a white page from a light desk: the page in shadow ends
    // up darker than the desk in the light, so no single cutoff exists.
    final flat = _flattenGradient(gray);

    // One reference edge map scores every candidate, whichever strategy
    // proposed it. Otherwise scores are not comparable across strategies.
    final reference = _referenceEdges(flat, colour);
    final proposals = <cv.Mat>[
      _cannyEdges(gray),
      _otsuEdges(flat),
      if (colour != null) _paperMask(colour, flat),
      if (colour != null) _unsaturatedMask(colour),
    ];

    try {
      // Measured outlines and rotated-rectangle fallbacks are ranked
      // separately. A minimum-area rectangle cannot represent perspective, so
      // on a page shot at an angle it always overshoots the near edge — and it
      // can still out-score the true outline, because the extra area it covers
      // happens to run along other structure. Letting it win only when no
      // measured outline is acceptable keeps it as the safety net it is meant
      // to be, rather than a competitor.
      Quad? measured;
      var measuredScore = 0.0;
      Quad? fallback;
      var fallbackScore = 0.0;

      for (final map in proposals) {
        for (final candidate in _candidatesFrom(map, size)) {
          final score = _scoreQuad(candidate.quad, reference, size);
          if (candidate.isFallback) {
            if (score > fallbackScore) {
              fallbackScore = score;
              fallback = candidate.quad;
            }
          } else if (score > measuredScore) {
            measuredScore = score;
            measured = candidate.quad;
          }
        }
      }

      if (measuredScore >= _minScore) return measured;
      // Below this the "page" is usually a table edge or a shadow line.
      return fallbackScore < _minScore ? null : fallback;
    } finally {
      flat.dispose();
      reference.dispose();
      for (final map in proposals) {
        map.dispose();
      }
    }
  }

  /// Divides out a first-order illumination gradient.
  ///
  /// A plane models the falloff across a desk but cannot represent the step
  /// between desk and paper, so fitting one and dividing by it removes the
  /// gradient while leaving the page boundary intact. That is what lets a
  /// global threshold work on a scene it otherwise could not touch.
  static cv.Mat _flattenGradient(cv.Mat gray) {
    final data = gray.data;
    final cols = gray.cols;
    final rows = gray.rows;

    // Least-squares fit of z = ax + by + c over a sampled grid.
    var sxx = 0.0, sxy = 0.0, syy = 0.0, sx = 0.0, sy = 0.0, n = 0.0;
    var sxz = 0.0, syz = 0.0, sz = 0.0;
    const step = 5;
    for (var y = 0; y < rows; y += step) {
      for (var x = 0; x < cols; x += step) {
        final z = data[y * cols + x].toDouble();
        final fx = x.toDouble();
        final fy = y.toDouble();
        sxx += fx * fx;
        sxy += fx * fy;
        syy += fy * fy;
        sx += fx;
        sy += fy;
        n += 1;
        sxz += fx * z;
        syz += fy * z;
        sz += z;
      }
    }

    // Cramer's rule on the 3x3 normal equations.
    final m = [
      [sxx, sxy, sx],
      [sxy, syy, sy],
      [sx, sy, n],
    ];
    final rhs = [sxz, syz, sz];
    final determinant = _determinant3(m);
    final out = Uint8List(cols * rows);

    if (determinant.abs() < 1e-6) {
      // Degenerate (a one-pixel image, say) — nothing to correct.
      out.setRange(0, out.length, data);
      return cv.Mat.fromList(rows, cols, cv.MatType.CV_8UC1, out);
    }

    final a = _determinant3(_replaceColumn(m, 0, rhs)) / determinant;
    final b = _determinant3(_replaceColumn(m, 1, rhs)) / determinant;
    final c = _determinant3(_replaceColumn(m, 2, rhs)) / determinant;

    // Rescale by the plane's average so overall brightness is preserved and
    // the result still spans a useful part of the 8-bit range.
    final meanPlane = a * (cols - 1) / 2 + b * (rows - 1) / 2 + c;
    if (meanPlane.abs() < 1e-6) {
      out.setRange(0, out.length, data);
      return cv.Mat.fromList(rows, cols, cv.MatType.CV_8UC1, out);
    }

    for (var y = 0; y < rows; y++) {
      final rowBase = y * cols;
      final planeRow = b * y + c;
      for (var x = 0; x < cols; x++) {
        final plane = a * x + planeRow;
        // A plane can dip to zero or below on a steep gradient; clamp so the
        // division stays sane rather than exploding into noise.
        final safe = plane < 1 ? 1.0 : plane;
        final corrected = data[rowBase + x] * meanPlane / safe;
        out[rowBase + x] = corrected < 0 ? 0 : (corrected > 255 ? 255 : corrected.round());
      }
    }
    return cv.Mat.fromList(rows, cols, cv.MatType.CV_8UC1, out);
  }

  static double _determinant3(List<List<double>> m) =>
      m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
      m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
      m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);

  static List<List<double>> _replaceColumn(
    List<List<double>> m,
    int column,
    List<double> values,
  ) =>
      [
        for (var row = 0; row < 3; row++)
          [
            for (var col = 0; col < 3; col++) col == column ? values[row] : m[row][col],
          ],
      ];

  /// Every plausible outline a single segmentation suggests.
  ///
  /// Each contour gets two chances: a polygon approximation at a few
  /// tolerances, and its minimum-area rectangle. The rectangle is what rescues
  /// pages whose corner is rounded, clipped or resting under a thumb — cases
  /// where `approxPolyDP` returns five or six points and a strict 4-gon filter
  /// throws the page away entirely.
  static List<_Candidate> _candidatesFrom(cv.Mat map, Size size) {
    final (contours, hierarchy) = cv.findContours(map, cv.RETR_LIST, cv.CHAIN_APPROX_SIMPLE);
    final frameArea = size.width * size.height;
    final candidates = <_Candidate>[];

    try {
      for (final contour in contours) {
        if (cv.contourArea(contour) < frameArea * _minAreaFraction) continue;
        final peri = cv.arcLength(contour, true);

        for (final epsilon in const [0.02, 0.04, 0.06]) {
          final approx = cv.approxPolyDP(contour, epsilon * peri, true);
          try {
            if (approx.length != 4) continue;
            candidates.add(_Candidate(
              Quad.fromUnorderedPoints([
                for (final p in approx) Offset(p.x / size.width, p.y / size.height),
              ]),
              isFallback: false,
            ));
            break;
          } finally {
            approx.dispose();
          }
        }

        final rect = cv.minAreaRect(contour);
        final corners = rect.points;
        try {
          candidates.add(_Candidate(
            Quad.fromUnorderedPoints([
              for (final p in corners) Offset(p.x / size.width, p.y / size.height),
            ]),
            isFallback: true,
          ));
        } finally {
          corners.dispose();
        }
      }
      return candidates;
    } finally {
      contours.dispose();
      hierarchy.dispose();
    }
  }

  /// How much this outline looks like a photographed sheet of paper.
  ///
  /// Three independent factors, multiplied so that a candidate has to satisfy
  /// all of them:
  ///  - **edge support**: does real image structure actually run along these
  ///    four lines? This is the factor that separates a page boundary from an
  ///    arbitrary rectangle, and it is weighted hardest.
  ///  - **shape**: opposite sides of a rectangle stay roughly equal under
  ///    perspective, and corners stay roughly square.
  ///  - **size**: bigger is better, but the frame itself is not a page.
  static double _scoreQuad(Quad quad, cv.Mat referenceEdges, Size size) {
    final area = quad.areaFraction;
    if (area < _minAreaFraction || area > _maxAreaFraction) return 0;

    final shape = _shapeScore(quad);
    if (shape <= 0) return 0;

    final support = _edgeSupport(quad, referenceEdges, size);
    // Squared: a candidate with half the edge support is much worse than half
    // as good, so this dominates ties between similarly shaped rectangles.
    return support * support * shape * math.sqrt(area);
  }

  /// Rectangle-likeness from geometry alone, 0..1.
  static double _shapeScore(Quad quad) {
    final p = quad.corners;
    final top = (p[1] - p[0]).distance;
    final right = (p[2] - p[1]).distance;
    final bottom = (p[2] - p[3]).distance;
    final left = (p[3] - p[0]).distance;
    if (top < 0.05 || right < 0.05 || bottom < 0.05 || left < 0.05) return 0;

    // Perspective shortens the far edge but never by a huge factor.
    final widthSymmetry = math.min(top, bottom) / math.max(top, bottom);
    final heightSymmetry = math.min(left, right) / math.max(left, right);

    var cosineSum = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = p[(i + 3) % 4] - p[i];
      final b = p[(i + 1) % 4] - p[i];
      if (a.distance < 1e-6 || b.distance < 1e-6) return 0;
      cosineSum += ((a.dx * b.dx + a.dy * b.dy) / (a.distance * b.distance)).abs();
    }
    final averageCosine = cosineSum / 4;
    // cos 44 degrees is about 0.72 — past that it is a sliver, not a page.
    if (averageCosine > 0.72) return 0;
    final squareness = 1 - averageCosine / 0.72;

    return widthSymmetry * heightSymmetry * squareness;
  }

  /// Fraction of the outline that sits on detected image structure.
  static double _edgeSupport(Quad quad, cv.Mat edges, Size size) {
    const samplesPerEdge = 48;
    final points = quad.toPixels(size);
    final data = edges.data;
    final cols = edges.cols;
    final rows = edges.rows;

    var hits = 0;
    var total = 0;
    for (var edge = 0; edge < 4; edge++) {
      final from = points[edge];
      final to = points[(edge + 1) % 4];
      for (var i = 0; i <= samplesPerEdge; i++) {
        final t = i / samplesPerEdge;
        final x = (from.dx + (to.dx - from.dx) * t).round();
        final y = (from.dy + (to.dy - from.dy) * t).round();
        total++;
        if (x < 0 || y < 0 || x >= cols || y >= rows) continue;
        if (data[y * cols + x] != 0) hits++;
      }
    }
    return total == 0 ? 0 : hits / total;
  }

  /// The edge map candidates are scored against.
  ///
  /// Dilated generously: a candidate corner can be a pixel or two off the true
  /// boundary and should still count as supported.
  static cv.Mat _referenceEdges(cv.Mat flattened, cv.Mat? colour) {
    final luminanceEdges = _cannyLoose(flattened);

    // A page boundary can live entirely in colour: a bright yellow desk has
    // almost the same luminance as paper, so a luma-only reference sees no
    // structure there and scores the correct outline at zero — which is worse
    // than proposing nothing, because it silently discards a good candidate.
    cv.Mat combined = luminanceEdges;
    if (colour != null) {
      final hsv = cv.cvtColor(colour, cv.COLOR_BGR2HSV);
      final channels = cv.split(hsv);
      final saturationEdges = _cannyLoose(channels[1]);
      combined = cv.max(luminanceEdges, saturationEdges);
      hsv.dispose();
      channels.dispose();
      saturationEdges.dispose();
      luminanceEdges.dispose();
    }

    // Dilated generously: a candidate corner can be a pixel or two off the
    // true boundary and should still count as supported.
    final kernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (7, 7));
    final dilated = cv.dilate(combined, kernel);
    combined.dispose();
    kernel.dispose();
    return dilated;
  }

  /// Canny with deliberately low thresholds.
  ///
  /// This feeds the scorer only, so missing a faint page boundary costs far
  /// more than letting some texture through.
  static cv.Mat _cannyLoose(cv.Mat channel) {
    final blurred = cv.gaussianBlur(channel, (5, 5), 0);
    final median = _median(blurred);
    final edges = cv.canny(
      blurred,
      math.max(8.0, 0.25 * median),
      math.max(24.0, 0.80 * median),
    );
    blurred.dispose();
    return edges;
  }

  /// Segments paper by colour: bright and almost unsaturated.
  ///
  /// This is the cue a grayscale pipeline throws away. A white page on a light
  /// wooden desk has almost no luminance contrast but a large saturation
  /// difference, which is exactly the case that used to fail.
  static cv.Mat _paperMask(cv.Mat bgr, cv.Mat flattenedGray) {
    final hsv = cv.cvtColor(bgr, cv.COLOR_BGR2HSV);
    final channels = cv.split(hsv);
    final saturation = channels[1];

    // 40, not 90: light oak measures around 75 here, so the old cutoff called
    // the desk unsaturated too and the mask separated nothing. Paper sits in
    // the single digits, so there is plenty of room below the wood.
    final (_, unsaturated) = cv.threshold(saturation, 40, 255, cv.THRESH_BINARY_INV);
    // Brightness is taken from the gradient-corrected image; using the raw V
    // channel puts the lit part of the desk above the shaded part of the page.
    final (_, bright) =
        cv.threshold(flattenedGray, 0, 255, cv.THRESH_BINARY + cv.THRESH_OTSU);
    final paper = cv.min(unsaturated, bright);

    // Close over text and ruling so the mask is the sheet, not its contents.
    final kernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (9, 9));
    final closed = cv.morphologyEx(paper, cv.MORPH_CLOSE, kernel,
        borderType: cv.BORDER_REPLICATE);
    _clearBorder(closed);

    hsv.dispose();
    channels.dispose();
    unsaturated.dispose();
    bright.dispose();
    paper.dispose();
    kernel.dispose();
    return closed;
  }

  /// Segments paper by saturation alone.
  ///
  /// Saturation is (max - min) / max over the channels, so scaling all three
  /// by the same amount leaves it unchanged — which means it is invariant to
  /// how brightly a region is lit. A shadow falling across half the page
  /// destroys every brightness-based segmentation but leaves this one intact,
  /// and that is the case nothing else here handles.
  ///
  /// It cannot separate paper from a grey desk, which is equally unsaturated;
  /// that is what the other strategies are for.
  static cv.Mat _unsaturatedMask(cv.Mat bgr) {
    final hsv = cv.cvtColor(bgr, cv.COLOR_BGR2HSV);
    final channels = cv.split(hsv);
    final (_, unsaturated) = cv.threshold(channels[1], 40, 255, cv.THRESH_BINARY_INV);
    final kernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (9, 9));
    final closed = cv.morphologyEx(unsaturated, cv.MORPH_CLOSE, kernel,
        borderType: cv.BORDER_REPLICATE);
    _clearBorder(closed);

    hsv.dispose();
    channels.dispose();
    unsaturated.dispose();
    kernel.dispose();
    return closed;
  }

  static cv.Mat _cannyEdges(cv.Mat gray) {
    final blurred = cv.gaussianBlur(gray, (5, 5), 0);
    // Close gaps between text glyphs so contours follow the sheet, not words.
    final kernel = cv.getStructuringElement(cv.MORPH_RECT, (9, 9));
    final closed = cv.morphologyEx(blurred, cv.MORPH_CLOSE, kernel,
        borderType: cv.BORDER_REPLICATE);
    final median = _median(closed);
    final lower = math.max(0.0, 0.66 * median);
    final upper = math.min(255.0, 1.33 * median);
    final edges = cv.canny(closed, lower, upper);
    final smallKernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
    final dilated = cv.dilate(edges, smallKernel);
    _clearBorder(dilated);
    blurred.dispose();
    kernel.dispose();
    smallKernel.dispose();
    closed.dispose();
    edges.dispose();
    return dilated;
  }

  /// Segments the scene into "bright" and "dark" after the gradient has been
  /// removed, which is what makes a white page separable from a light desk.
  static cv.Mat _otsuEdges(cv.Mat flattened) {
    final blurred = cv.gaussianBlur(flattened, (7, 7), 0);
    final (_, binary) = cv.threshold(blurred, 0, 255, cv.THRESH_BINARY + cv.THRESH_OTSU);
    final kernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
    final closed = cv.morphologyEx(binary, cv.MORPH_CLOSE, kernel,
        borderType: cv.BORDER_REPLICATE);
    _clearBorder(closed);
    blurred.dispose();
    binary.dispose();
    kernel.dispose();
    return closed;
  }

  /// Blanks a band around the edge of a binary image.
  ///
  /// Thresholding can leave the whole frame as one blob, whose contour is a
  /// perfect rectangle enclosing everything — and being the largest it would
  /// beat the real page. Erasing the band removes the contour rather than
  /// trying to recognise and reject it afterwards.
  ///
  /// The cost is that a page running off the edge of the frame is detected a
  /// few pixels short, which the crop handles can fix.
  static void _clearBorder(cv.Mat binary, {int band = 6}) {
    cv.rectangle(
      binary,
      cv.Rect(0, 0, binary.cols, binary.rows),
      cv.Scalar.black,
      thickness: band * 2,
    );
  }

  /// ── enhancement ────────────────────────────────────────────────────────
  ///
  /// Warps [quad] to a flat rectangle and applies the chosen filter.
  /// The caller owns the returned Mat.
  static cv.Mat warpAndEnhance(cv.Mat bgr, Quad quad, EnhanceSettings settings) {
    final warped = _warp(bgr, quad);
    try {
      final enhanced = _applyFilter(warped, settings);
      if (settings.rotationQuarterTurns % 4 == 0) return enhanced;
      try {
        return _rotate(enhanced, settings.rotationQuarterTurns);
      } finally {
        enhanced.dispose();
      }
    } finally {
      warped.dispose();
    }
  }

  /// Perspective-corrects the quad. The output size uses the longest opposing
  /// edges, so a page photographed at an angle comes out at its true ratio
  /// instead of being squashed toward the near edge.
  static cv.Mat _warp(cv.Mat src, Quad quad) {
    final size = Size(src.cols.toDouble(), src.rows.toDouble());
    final p = quad.toPixels(size);
    final widthTop = (p[1] - p[0]).distance;
    final widthBottom = (p[2] - p[3]).distance;
    final heightLeft = (p[3] - p[0]).distance;
    final heightRight = (p[2] - p[1]).distance;

    final outWidth = math.max(widthTop, widthBottom).round().clamp(64, 4096);
    final outHeight = math.max(heightLeft, heightRight).round().clamp(64, 4096);

    final srcPts = cv.VecPoint.fromList([
      for (final pt in p) cv.Point(pt.dx.round(), pt.dy.round()),
    ]);
    final dstPts = cv.VecPoint.fromList([
      cv.Point(0, 0),
      cv.Point(outWidth - 1, 0),
      cv.Point(outWidth - 1, outHeight - 1),
      cv.Point(0, outHeight - 1),
    ]);
    final matrix = cv.getPerspectiveTransform(srcPts, dstPts);
    try {
      return cv.warpPerspective(
        src,
        matrix,
        (outWidth, outHeight),
        flags: cv.INTER_CUBIC,
        borderMode: cv.BORDER_REPLICATE,
      );
    } finally {
      srcPts.dispose();
      dstPts.dispose();
      matrix.dispose();
    }
  }

  /// The heart of the scan look.
  ///
  /// A photo of a page is not a scan: it carries the shadow of the phone, a
  /// brightness gradient across the sheet, and grey-ish paper. Every filter
  /// below except [ScanFilter.original] starts by dividing that illumination
  /// out, which is what turns paper white and lets ink stand on its own.
  static cv.Mat _applyFilter(cv.Mat bgr, EnhanceSettings settings) {
    switch (settings.filter) {
      case ScanFilter.original:
        return _applyTone(bgr, settings.brightness, settings.contrast);

      case ScanFilter.document:
        return _documentLook(bgr, settings, colour: false);

      case ScanFilter.magicColor:
        return _documentLook(bgr, settings, colour: true);

      case ScanFilter.grayscale:
        final gray = cv.cvtColor(bgr, cv.COLOR_BGR2GRAY);
        try {
          final toned = _applyTone(gray, settings.brightness, settings.contrast);
          try {
            return cv.cvtColor(toned, cv.COLOR_GRAY2BGR);
          } finally {
            toned.dispose();
          }
        } finally {
          gray.dispose();
        }

      case ScanFilter.blackWhite:
        return _blackWhite(bgr, settings);
    }
  }

  /// Shadow removal, then a level stretch, then sharpening.
  ///
  /// With [colour] the same correction is applied to all three channels from a
  /// single luma-derived background, so stamps, signatures and highlighter
  /// survive; dividing each channel by its own background would neutralise the
  /// colour it is meant to preserve.
  static cv.Mat _documentLook(cv.Mat bgr, EnhanceSettings settings, {required bool colour}) {
    final gray = cv.cvtColor(bgr, cv.COLOR_BGR2GRAY);
    final background = _estimateBackground(gray);
    final flatGray = cv.divide(gray, background, scale: 255);
    // Levels come from the flattened luma either way, so the colour and mono
    // versions agree about where paper and ink sit.
    final lut = _buildLut(flatGray, settings);

    try {
      if (colour) {
        final background3 = cv.cvtColor(background, cv.COLOR_GRAY2BGR);
        final flat = cv.divide(bgr, background3, scale: 255);
        final levelled = cv.LUT(flat, lut);
        final saturated = _boostSaturation(levelled);
        try {
          return _sharpen(saturated);
        } finally {
          background3.dispose();
          flat.dispose();
          levelled.dispose();
          saturated.dispose();
        }
      }

      final levelled = cv.LUT(flatGray, lut);
      final sharpened = _sharpen(levelled);
      try {
        return cv.cvtColor(sharpened, cv.COLOR_GRAY2BGR);
      } finally {
        levelled.dispose();
        sharpened.dispose();
      }
    } finally {
      gray.dispose();
      background.dispose();
      flatGray.dispose();
      lut.dispose();
    }
  }

  /// Pure black on pure white, for text you want to read or OCR later.
  ///
  /// Flattening first means the adaptive threshold only has to separate ink
  /// from paper rather than fight a shadow at the same time — which is exactly
  /// what makes plain adaptive thresholding go blotchy under a phone's own
  /// shadow.
  static cv.Mat _blackWhite(cv.Mat bgr, EnhanceSettings settings) {
    final gray = cv.cvtColor(bgr, cv.COLOR_BGR2GRAY);
    final background = _estimateBackground(gray);
    final flat = cv.divide(gray, background, scale: 255);
    final denoised = cv.medianBlur(flat, 3);
    // Brightness biases the cutoff: negative keeps more faint ink, positive
    // wipes more speckle. That is the control that matters on a B&W scan.
    final bias = 10 - settings.brightness / 4;
    final adaptive = cv.adaptiveThreshold(
      denoised,
      255,
      cv.ADAPTIVE_THRESH_GAUSSIAN_C,
      cv.THRESH_BINARY,
      _oddBlockSize(bgr),
      bias,
    );

    // An adaptive threshold judges each pixel against its neighbours, so the
    // inside of a solid logo — where every neighbour is also ink — reads as
    // "brighter than average" and comes out white. A global floor rescues it:
    // anything this dark after flattening is ink whatever its surroundings say.
    final (_, floor) = cv.threshold(denoised, 110, 255, cv.THRESH_BINARY);
    final binary = cv.min(adaptive, floor);

    final out = cv.cvtColor(binary, cv.COLOR_GRAY2BGR);
    gray.dispose();
    background.dispose();
    flat.dispose();
    denoised.dispose();
    adaptive.dispose();
    floor.dispose();
    binary.dispose();
    return out;
  }

  /// Estimates what the page would look like with no ink on it.
  ///
  /// Done in two stages, because one morphological close cannot satisfy both
  /// requirements at once. A kernel small enough to follow a hard shadow edge
  /// cannot span a solid logo, so the logo's interior is mistaken for paper and
  /// gets divided out — it comes back as a white box with a black outline. A
  /// kernel wide enough to span the logo is too smooth to track the shadow.
  ///
  /// So: use a wide close only to decide *where the ink is*, then rebuild the
  /// illumination across that ink by inpainting from the paper around it. The
  /// estimate then follows the real lighting everywhere paper is visible, and
  /// is interpolated everywhere it is not.
  static cv.Mat _estimateBackground(cv.Mat gray) {
    const workingSide = 256;
    final small = fitTo(gray, workingSide);

    // Wide enough to close over a solid block; far too smooth to be the
    // background itself, which is why it is only used to find ink.
    final coarseSize = _oddFraction(small, 0.20);
    final coarseKernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (coarseSize, coarseSize));
    // BORDER_REPLICATE is not optional here. This binding defaults
    // morphologyEx's borderValue to 0 where OpenCV's C++ default is +inf, so
    // the erode half of the close otherwise darkens a band as wide as the
    // kernel — with a kernel this large that is most of the page, and the ink
    // mask derived from it is wrong everywhere near an edge.
    final coarse = cv.morphologyEx(small, cv.MORPH_CLOSE, coarseKernel,
        borderType: cv.BORDER_REPLICATE);

    // Ink is anything meaningfully darker than the local paper level. The
    // dilate makes the mask overshoot slightly, so anti-aliased glyph edges do
    // not seed the interpolation with half-ink values.
    final inkThreshold = cv.convertScaleAbs(coarse, alpha: 0.88);
    final ink = cv.compare(small, inkThreshold, cv.CMP_LT);
    final spreadKernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (5, 5));
    final inkMask = cv.dilate(ink, spreadKernel);

    final filled = cv.inpaint(small, inkMask, 3, cv.INPAINT_TELEA);
    final smoothed = cv.gaussianBlur(filled, (0, 0), 2);
    final background = cv.resize(
      smoothed,
      (gray.cols, gray.rows),
      interpolation: cv.INTER_LINEAR,
    );

    small.dispose();
    coarseKernel.dispose();
    coarse.dispose();
    inkThreshold.dispose();
    ink.dispose();
    spreadKernel.dispose();
    inkMask.dispose();
    filled.dispose();
    smoothed.dispose();
    return background;
  }

  /// An odd kernel size that is [fraction] of the image's longest side, so the
  /// same setting means the same thing at any working resolution.
  static int _oddFraction(cv.Mat mat, double fraction) {
    final size = (math.max(mat.cols, mat.rows) * fraction).round();
    return math.max(3, size.isEven ? size + 1 : size);
  }

  /// Builds the tone curve: black point, white point, brightness and contrast
  /// in a single 256-entry table.
  ///
  /// One lookup instead of three passes, and no intermediate rounding — which
  /// is where stacked 8-bit operations lose the faint strokes this is meant to
  /// rescue.
  static cv.Mat _buildLut(cv.Mat flatGray, EnhanceSettings settings) {
    var (black, white) = _levels(flatGray);

    // Contrast moves the black and white points rather than applying a gain
    // around mid-grey. After the level stretch ink already sits at 0 and paper
    // at 255, so a mid-tone gain would have almost nothing left to act on;
    // narrowing the span is what actually thickens text and cleans paper, and
    // it is what a scanner's contrast control does.
    final squeeze = (settings.contrast / 50) * 0.25 * (white - black);
    black = (black + squeeze).clamp(0, 254).round();
    white = (white - squeeze).clamp(1, 255).round();
    if (white - black < 16) {
      final middle = (black + white) / 2;
      black = (middle - 8).clamp(0, 239).round();
      white = black + 16;
    }
    final span = math.max(1, white - black);
    final brightness = settings.brightness * 1.6; // -80 .. 80 in 8-bit levels

    final table = Uint8List(256);
    for (var value = 0; value < 256; value++) {
      final normalised = ((value - black) / span).clamp(0.0, 1.0);
      table[value] = (normalised * 255 + brightness).clamp(0.0, 255.0).round();
    }
    return cv.Mat.fromList(1, 256, cv.MatType.CV_8UC1, table);
  }

  /// Picks the black and white points from the histogram.
  ///
  /// Paper dominates a page, so the bright end of the histogram *is* the
  /// paper: clipping the top few percent to pure white removes the last grey
  /// cast, while the low percentile finds the ink without letting a single
  /// dust speck define black.
  static (int black, int white) _levels(cv.Mat gray) {
    final histogram = _histogram(gray);
    final total = histogram.fold<int>(0, (sum, count) => sum + count);
    if (total == 0) return (0, 255);

    var black = 0;
    var seen = 0;
    for (var value = 0; value < 256; value++) {
      seen += histogram[value];
      if (seen >= total * 0.02) {
        black = value;
        break;
      }
    }

    var white = 255;
    seen = 0;
    for (var value = 255; value >= 0; value--) {
      seen += histogram[value];
      if (seen >= total * 0.12) {
        white = value;
        break;
      }
    }

    // Keep a usable span even on a page that is almost entirely one tone.
    if (white - black < 32) return (math.max(0, white - 32), white);
    return (black, white);
  }

  static List<int> _histogram(cv.Mat gray) {
    final histogram = List<int>.filled(256, 0);
    final data = gray.data;
    for (var i = 0; i < data.length; i += 4) {
      histogram[data[i]]++;
    }
    return histogram;
  }

  /// Lifts saturation a little.
  ///
  /// Dividing the illumination out pulls every channel toward the paper's
  /// white point, which desaturates whatever colour was there. A modest boost
  /// puts back what the flattening cost without turning a beige page pink;
  /// paper itself is near-grey, so it is barely affected.
  static cv.Mat _boostSaturation(cv.Mat bgr, {double amount = 1.25}) {
    final hsv = cv.cvtColor(bgr, cv.COLOR_BGR2HSV);
    final channels = cv.split(hsv);
    try {
      final lifted = cv.convertScaleAbs(channels[1], alpha: amount);
      try {
        final merged = cv.merge(cv.VecMat.fromList([channels[0], lifted, channels[2]]));
        try {
          return cv.cvtColor(merged, cv.COLOR_HSV2BGR);
        } finally {
          merged.dispose();
        }
      } finally {
        lifted.dispose();
      }
    } finally {
      hsv.dispose();
      channels.dispose();
    }
  }

  /// Unsharp mask — puts back the edge definition the warp's interpolation
  /// softens, which is most of what makes text read as crisp rather than
  /// merely dark.
  static cv.Mat _sharpen(cv.Mat src, {double amount = 0.6}) {
    final blurred = cv.gaussianBlur(src, (0, 0), 2);
    try {
      return cv.addWeighted(src, 1 + amount, blurred, -amount, 0);
    } finally {
      blurred.dispose();
    }
  }

  /// Adaptive-threshold windows must be odd and should scale with the page,
  /// or the same setting turns blotchy at high resolution.
  static int _oddBlockSize(cv.Mat mat) {
    final side = math.max(mat.cols, mat.rows);
    final block = (side / 40).round();
    return math.max(11, block.isEven ? block + 1 : block);
  }

  static cv.Mat _applyTone(cv.Mat src, int brightness, int contrast) {
    if (brightness == 0 && contrast == 0) return src.clone();
    final alpha = 1 + contrast / 100; // 0.5 .. 1.5
    final beta = brightness * 1.6; // -80 .. 80 in 8-bit levels
    return cv.convertScaleAbs(src, alpha: alpha, beta: beta);
  }

  static cv.Mat _rotate(cv.Mat src, int quarterTurns) {
    final turns = quarterTurns % 4;
    const codes = {
      1: cv.ROTATE_90_CLOCKWISE,
      2: cv.ROTATE_180,
      3: cv.ROTATE_90_COUNTERCLOCKWISE,
    };
    return cv.rotate(src, codes[turns]!);
  }

  /// ── helpers ────────────────────────────────────────────────────────────

  /// Wraps an already-packed 8-bit grayscale buffer as a Mat.
  ///
  /// Unpacking and decimating happens in [LumaFrame] on the sending isolate,
  /// so the buffer that crosses the boundary is small.
  static cv.Mat grayFromPackedLuma(Uint8List bytes, int width, int height) =>
      cv.Mat.fromList(height, width, cv.MatType.CV_8UC1, bytes);

  /// Downscales so the longest side is at most [maxSide]; returns [src]
  /// untouched when it already fits, so callers must check identity before
  /// disposing.
  static cv.Mat _fitTo(cv.Mat src, int maxSide) {
    final longest = math.max(src.cols, src.rows);
    if (longest <= maxSide) return src;
    final scale = maxSide / longest;
    return cv.resize(
      src,
      ((src.cols * scale).round(), (src.rows * scale).round()),
      interpolation: cv.INTER_AREA,
    );
  }

  /// Like [_fitTo] but always hands back a Mat the caller owns.
  static cv.Mat fitTo(cv.Mat src, int maxSide) {
    final fitted = _fitTo(src, maxSide);
    return identical(fitted, src) ? src.clone() : fitted;
  }

  /// Median intensity, used to auto-tune the Canny thresholds per frame.
  static double _median(cv.Mat gray) {
    final histogram = List<int>.filled(256, 0);
    final data = gray.data;
    // Sampling every 4th byte is ~4x faster and moves the median by <1 level.
    var counted = 0;
    for (var i = 0; i < data.length; i += 4) {
      histogram[data[i]]++;
      counted++;
    }
    if (counted == 0) return 128;
    var seen = 0;
    for (var value = 0; value < 256; value++) {
      seen += histogram[value];
      if (seen >= counted / 2) return value.toDouble();
    }
    return 128;
  }

  static Uint8List encodeJpeg(cv.Mat bgr, {int quality = 92}) {
    final params = cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, quality]);
    try {
      final (ok, bytes) = cv.imencode('.jpg', bgr, params: params);
      if (!ok) throw StateError('JPEG encoding failed');
      return bytes;
    } finally {
      params.dispose();
    }
  }
}
