import 'dart:math' as math;
import 'dart:ui';

/// A document outline: four corners in **normalized** image space (0..1),
/// ordered top-left, top-right, bottom-right, bottom-left.
///
/// Normalized so a quad detected on a downscaled preview frame can be applied
/// to the full-resolution capture without rescaling.
class Quad {
  const Quad(this.topLeft, this.topRight, this.bottomRight, this.bottomLeft);

  final Offset topLeft;
  final Offset topRight;
  final Offset bottomRight;
  final Offset bottomLeft;

  /// The whole frame, inset slightly so the handles stay grabbable.
  static const full = Quad(
    Offset(0.02, 0.02),
    Offset(0.98, 0.02),
    Offset(0.98, 0.98),
    Offset(0.02, 0.98),
  );

  List<Offset> get corners => [topLeft, topRight, bottomRight, bottomLeft];

  Quad withCorner(int index, Offset value) {
    final next = List<Offset>.of(corners)..[index] = _clamp(value);
    return Quad(next[0], next[1], next[2], next[3]);
  }

  /// Rotates the quad 90° clockwise inside a unit square — keeps the corner
  /// ordering valid after a page rotation.
  Quad rotatedCw() => Quad(
    _rot(bottomLeft),
    _rot(topLeft),
    _rot(topRight),
    _rot(bottomRight),
  );

  static Offset _rot(Offset p) => Offset(1 - p.dy, p.dx);

  static Offset _clamp(Offset p) => Offset(p.dx.clamp(0.0, 1.0), p.dy.clamp(0.0, 1.0));

  /// Scales into pixel space for an image of [size].
  List<Offset> toPixels(Size size) =>
      corners.map((c) => Offset(c.dx * size.width, c.dy * size.height)).toList();

  /// Fraction of the frame this quad covers — used to reject junk detections.
  double get areaFraction {
    final pts = corners;
    var sum = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % 4];
      sum += a.dx * b.dy - b.dx * a.dy;
    }
    return (sum / 2).abs();
  }

  /// True when every corner sits within [tolerance] of [other] — lets the live
  /// overlay ignore sub-pixel jitter between frames.
  bool isCloseTo(Quad other, {double tolerance = 0.01}) {
    for (var i = 0; i < 4; i++) {
      if ((corners[i] - other.corners[i]).distance > tolerance) return false;
    }
    return true;
  }

  /// Eases toward [target] so the on-screen outline glides instead of snapping.
  Quad lerpTo(Quad target, double t) => Quad(
    Offset.lerp(topLeft, target.topLeft, t)!,
    Offset.lerp(topRight, target.topRight, t)!,
    Offset.lerp(bottomRight, target.bottomRight, t)!,
    Offset.lerp(bottomLeft, target.bottomLeft, t)!,
  );

  List<double> toFlatList() => [
    topLeft.dx, topLeft.dy,
    topRight.dx, topRight.dy,
    bottomRight.dx, bottomRight.dy,
    bottomLeft.dx, bottomLeft.dy,
  ];

  factory Quad.fromFlatList(List<double> v) => Quad(
    Offset(v[0], v[1]),
    Offset(v[2], v[3]),
    Offset(v[4], v[5]),
    Offset(v[6], v[7]),
  );

  /// Orders four arbitrary points into TL, TR, BR, BL.
  ///
  /// Sorting by angle around the centroid is stable for any convex quad,
  /// including strongly skewed ones where the usual sum/difference trick fails.
  factory Quad.fromUnorderedPoints(List<Offset> points) {
    assert(points.length == 4);
    final cx = points.map((p) => p.dx).reduce((a, b) => a + b) / 4;
    final cy = points.map((p) => p.dy).reduce((a, b) => a + b) / 4;
    final sorted = List<Offset>.of(points)
      ..sort((a, b) => math.atan2(a.dy - cy, a.dx - cx)
          .compareTo(math.atan2(b.dy - cy, b.dx - cx)));
    // atan2 puts the smallest angle just after "9 o'clock"; rotate so the
    // point that is highest-and-leftmost leads.
    var start = 0;
    var best = double.infinity;
    for (var i = 0; i < 4; i++) {
      final score = sorted[i].dx + sorted[i].dy;
      if (score < best) {
        best = score;
        start = i;
      }
    }
    final o = List.generate(4, (i) => sorted[(start + i) % 4]);
    return Quad(o[0], o[1], o[2], o[3]);
  }

  @override
  String toString() => 'Quad($topLeft, $topRight, $bottomRight, $bottomLeft)';
}
