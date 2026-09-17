
import 'package:doc_scanner/data/models/quad.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Quad.fromUnorderedPoints', () {
    test('orders an axis-aligned rectangle as TL, TR, BR, BL', () {
      final quad = Quad.fromUnorderedPoints(const [
        Offset(0.8, 0.9),
        Offset(0.2, 0.1),
        Offset(0.8, 0.1),
        Offset(0.2, 0.9),
      ]);

      expect(quad.topLeft, const Offset(0.2, 0.1));
      expect(quad.topRight, const Offset(0.8, 0.1));
      expect(quad.bottomRight, const Offset(0.8, 0.9));
      expect(quad.bottomLeft, const Offset(0.2, 0.9));
    });

    test('orders a strongly skewed page, where sum/difference sorting fails', () {
      // A page tilted so the top-right corner sits lower than the bottom-left.
      final quad = Quad.fromUnorderedPoints(const [
        Offset(0.15, 0.30),
        Offset(0.70, 0.10),
        Offset(0.90, 0.75),
        Offset(0.30, 0.95),
      ]);

      expect(quad.topLeft, const Offset(0.15, 0.30));
      expect(quad.topRight, const Offset(0.70, 0.10));
      expect(quad.bottomRight, const Offset(0.90, 0.75));
      expect(quad.bottomLeft, const Offset(0.30, 0.95));
    });
  });

  group('areaFraction', () {
    test('reports the covered share of the frame', () {
      const quad = Quad(
        Offset(0, 0),
        Offset(0.5, 0),
        Offset(0.5, 0.5),
        Offset(0, 0.5),
      );
      expect(quad.areaFraction, closeTo(0.25, 1e-9));
    });

    test('is positive regardless of winding direction', () {
      const clockwise = Quad(
        Offset(0, 0),
        Offset(1, 0),
        Offset(1, 1),
        Offset(0, 1),
      );
      const counterClockwise = Quad(
        Offset(0, 0),
        Offset(0, 1),
        Offset(1, 1),
        Offset(1, 0),
      );
      expect(clockwise.areaFraction, closeTo(1.0, 1e-9));
      expect(counterClockwise.areaFraction, closeTo(1.0, 1e-9));
    });
  });

  group('rotatedCw', () {
    test('keeps corner ordering valid after a quarter turn', () {
      const quad = Quad(
        Offset(0.1, 0.2),
        Offset(0.9, 0.2),
        Offset(0.9, 0.8),
        Offset(0.1, 0.8),
      );
      final rotated = quad.rotatedCw();

      // The old bottom-left becomes the new top-left.
      expect(rotated.topLeft.dx, closeTo(1 - quad.bottomLeft.dy, 1e-9));
      expect(rotated.topLeft.dy, closeTo(quad.bottomLeft.dx, 1e-9));
      // Area is preserved by a rotation.
      expect(rotated.areaFraction, closeTo(quad.areaFraction, 1e-9));
    });

    test('four turns return to the original', () {
      const quad = Quad(
        Offset(0.12, 0.2),
        Offset(0.88, 0.14),
        Offset(0.91, 0.79),
        Offset(0.09, 0.85),
      );
      final full = quad.rotatedCw().rotatedCw().rotatedCw().rotatedCw();
      for (var i = 0; i < 4; i++) {
        expect(full.corners[i].dx, closeTo(quad.corners[i].dx, 1e-9));
        expect(full.corners[i].dy, closeTo(quad.corners[i].dy, 1e-9));
      }
    });
  });

  group('withCorner', () {
    test('clamps a corner dragged past the frame edge', () {
      final quad = Quad.full.withCorner(0, const Offset(-0.4, 1.8));
      expect(quad.topLeft, const Offset(0, 1));
    });

    test('leaves the other corners untouched', () {
      final quad = Quad.full.withCorner(2, const Offset(0.6, 0.6));
      expect(quad.topLeft, Quad.full.topLeft);
      expect(quad.topRight, Quad.full.topRight);
      expect(quad.bottomLeft, Quad.full.bottomLeft);
      expect(quad.bottomRight, const Offset(0.6, 0.6));
    });
  });

  group('serialisation', () {
    test('survives a round trip through the isolate wire format', () {
      const quad = Quad(
        Offset(0.11, 0.22),
        Offset(0.87, 0.19),
        Offset(0.93, 0.81),
        Offset(0.07, 0.88),
      );
      final restored = Quad.fromFlatList(quad.toFlatList());
      expect(restored.corners, quad.corners);
    });
  });

  group('isCloseTo', () {
    test('accepts jitter inside the tolerance', () {
      const a = Quad(Offset(0.1, 0.1), Offset(0.9, 0.1), Offset(0.9, 0.9), Offset(0.1, 0.9));
      const b = Quad(
        Offset(0.105, 0.1),
        Offset(0.9, 0.104),
        Offset(0.896, 0.9),
        Offset(0.1, 0.897),
      );
      expect(a.isCloseTo(b, tolerance: 0.02), isTrue);
    });

    test('rejects a corner that has genuinely moved', () {
      const a = Quad(Offset(0.1, 0.1), Offset(0.9, 0.1), Offset(0.9, 0.9), Offset(0.1, 0.9));
      const b = Quad(Offset(0.1, 0.1), Offset(0.9, 0.1), Offset(0.9, 0.9), Offset(0.3, 0.9));
      expect(a.isCloseTo(b, tolerance: 0.02), isFalse);
    });
  });
}
