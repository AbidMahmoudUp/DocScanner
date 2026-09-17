import 'dart:convert';

import 'package:doc_scanner/core/app_theme.dart';
import 'package:doc_scanner/data/models/quad.dart';
import 'package:doc_scanner/views/widgets/scan_reveal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The sweep sits between the capture and the editable result, so the one
/// thing it must never do is fail to hand over — a callback that does not fire
/// leaves the user stuck looking at an animation.

/// A 1x1 PNG, so the Image widgets have something real to decode.
final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Widget _host({required VoidCallback onComplete, Quad? quad, Duration? duration}) {
  return MaterialApp(
    theme: AppTheme.dark(),
    home: Scaffold(
      body: SizedBox(
        width: 300,
        height: 400,
        child: ScanReveal(
          original: MemoryImage(_pixel),
          result: MemoryImage(_pixel),
          quad: quad,
          duration: duration ?? const Duration(milliseconds: 900),
          onComplete: onComplete,
        ),
      ),
    ),
  );
}

void main() {
  group('ScanReveal', () {
    testWidgets('hands over once the sweep finishes', (tester) async {
      var completed = 0;
      await tester.pumpWidget(_host(onComplete: () => completed++));

      expect(completed, 0, reason: 'it should not finish before it has played');
      await tester.pump(const Duration(milliseconds: 500));
      expect(completed, 0);

      await tester.pump(const Duration(milliseconds: 500));
      expect(completed, 1, reason: 'the sweep ended but never handed over');
      await tester.pumpAndSettle();
    });

    testWidgets('a tap skips straight to the result', (tester) async {
      var completed = 0;
      await tester.pumpWidget(_host(onComplete: () => completed++));

      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byType(ScanReveal));
      expect(completed, 1, reason: 'tapping should not make you wait it out');

      // Letting the rest of the timeline run must not fire it a second time,
      // which would pop a route that has already gone.
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();
      expect(completed, 1);
    });

    testWidgets('draws the detected outline while it reads', (tester) async {
      await tester.pumpWidget(_host(
        onComplete: () {},
        quad: Quad.full,
      ));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
    });

    testWidgets('works with no detected outline', (tester) async {
      // Detection legitimately returns nothing, and the sweep still has to run.
      await tester.pumpWidget(_host(onComplete: () {}));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
    });

    testWidgets('does not overflow in a tight box', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 120,
            height: 90,
            child: ScanReveal(
              original: MemoryImage(_pixel),
              result: MemoryImage(_pixel),
              onComplete: () {},
              duration: const Duration(milliseconds: 300),
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
    });
  });
}
