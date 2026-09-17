import 'dart:typed_data';

import 'package:doc_scanner/services/cv/luma_frame.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a Y plane whose every byte encodes its own (x, y), with [padding]
/// junk bytes per row — the row stride Android adds on real devices.
Uint8List planeOf(int width, int height, {int padding = 0}) {
  final bytesPerRow = width + padding;
  final plane = Uint8List(bytesPerRow * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      plane[y * bytesPerRow + x] = (y * width + x) % 251;
    }
    for (var pad = 0; pad < padding; pad++) {
      plane[y * bytesPerRow + width + pad] = 255;
    }
  }
  return plane;
}

void main() {
  group('LumaFrame.fromPlane', () {
    test('copies a padded plane without picking up the row padding', () {
      final plane = planeOf(8, 4, padding: 6);
      final frame = LumaFrame.fromPlane(plane, 8, 4, 14, maxSide: 640);

      expect(frame.width, 8);
      expect(frame.height, 4);
      expect(frame.bytes.length, 32);
      // Padding bytes are 255; none should have survived.
      expect(frame.bytes.contains(255), isFalse);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 8; x++) {
          expect(frame.bytes[y * 8 + x], (y * 8 + x) % 251);
        }
      }
    });

    test('leaves a frame that already fits untouched in size', () {
      final frame = LumaFrame.fromPlane(planeOf(320, 240), 320, 240, 320, maxSide: 640);
      expect(frame.width, 320);
      expect(frame.height, 240);
    });

    test('decimates a 1080p plane to within the detection budget', () {
      final frame = LumaFrame.fromPlane(planeOf(1920, 1080), 1920, 1080, 1920, maxSide: 640);

      // step = ceil(1920 / 640) = 3
      expect(frame.width, 640);
      expect(frame.height, 360);
      expect(frame.bytes.length, 640 * 360);
      // The whole point: the buffer that crosses the isolate boundary is a
      // fraction of the 2MB plane.
      expect(frame.bytes.length, lessThan(1920 * 1080 ~/ 8));
    });

    test('samples the expected pixels when decimating', () {
      final plane = planeOf(9, 9);
      final frame = LumaFrame.fromPlane(plane, 9, 9, 9, maxSide: 3);

      // step = ceil(9 / 3) = 3, so rows/cols 0, 3 and 6 are kept.
      expect(frame.width, 3);
      expect(frame.height, 3);
      for (var y = 0; y < 3; y++) {
        for (var x = 0; x < 3; x++) {
          expect(frame.bytes[y * 3 + x], ((y * 3) * 9 + x * 3) % 251);
        }
      }
    });

    test('handles sizes that are not a multiple of the step', () {
      final frame = LumaFrame.fromPlane(planeOf(10, 7), 10, 7, 10, maxSide: 4);
      // step = ceil(10 / 4) = 3 → ceil(10/3) = 4 wide, ceil(7/3) = 3 tall.
      expect(frame.width, 4);
      expect(frame.height, 3);
      expect(frame.bytes.length, 12);
    });
  });

  group('meanLuma', () {
    test('averages the decimated frame', () {
      final frame = LumaFrame(bytes: Uint8List.fromList([0, 100, 200, 60]), width: 2, height: 2);
      expect(frame.meanLuma, 90);
    });

    test('reads as bright when there is nothing to measure', () {
      // A dark reading would fire the low-light banner on an empty frame.
      final frame = LumaFrame(bytes: Uint8List(0), width: 0, height: 0);
      expect(frame.meanLuma, 255);
    });
  });
}
