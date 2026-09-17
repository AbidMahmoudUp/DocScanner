import 'package:doc_scanner/core/app_theme.dart';
import 'package:doc_scanner/data/models/scan_document.dart';
import 'package:doc_scanner/data/models/scan_page.dart';
import 'package:doc_scanner/views/home/widgets/document_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The recent-scans grid sizes its cells by aspect ratio, so the labels get
/// whatever the thumbnail leaves. That is a standing invitation to overflow on
/// a device with a different font scale or a narrower screen, which is exactly
/// what happened, so it is worth pinning down.

ScanDocument _document({String name = 'Insurance claim', int pages = 4}) {
  final now = DateTime(2026, 9, 17, 9, 24);
  return ScanDocument(
    id: 'doc-1',
    name: name,
    tag: 'Insurance',
    createdAt: now,
    updatedAt: now,
    pages: [
      for (var i = 0; i < pages; i++)
        ScanPage(
          id: 'page-$i',
          documentId: 'doc-1',
          pageIndex: i,
          // Deliberately missing: the card must fall back, not throw.
          filePath: '/nonexistent/page_$i.jpg',
          thumbPath: '/nonexistent/thumb_$i.jpg',
          createdAt: now,
        ),
    ],
  );
}

/// Renders one card in a cell the same shape the home grid produces.
Widget _grid(ScanDocument document, {required double textScale}) {
  return MaterialApp(
    theme: AppTheme.dark(),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: GridView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 16,
              childAspectRatio: 0.63,
            ),
            children: [
              DocumentCard(
                document: document,
                onTap: () {},
                onLongPress: () {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Sizes the test surface like a real phone.
///
/// The default 800x600 surface makes the grid cells far roomier than any
/// handset, so the labels always fit and the very bug this file exists for
/// cannot reproduce.
void useScreen(WidgetTester tester, {double width = 411, double height = 891}) {
  const ratio = 2.625;
  tester.view.physicalSize = Size(width * ratio, height * ratio);
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('DocumentCard layout', () {
    for (final scale in const [1.0, 1.15, 1.3, 1.5, 2.0]) {
      testWidgets('does not overflow at text scale $scale', (tester) async {
        useScreen(tester);
        await tester.pumpWidget(_grid(_document(), textScale: scale));
        expect(
          tester.takeException(),
          isNull,
          reason: 'the card overflowed its grid cell at text scale $scale',
        );
      });
    }

    testWidgets('does not overflow on a narrow screen', (tester) async {
      // A small phone makes the cells shorter, which squeezes the labels
      // hardest.
      useScreen(tester, width: 320, height: 640);
      await tester.pumpWidget(_grid(_document(), textScale: 1.3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long name is truncated rather than wrapped', (tester) async {
      useScreen(tester);
      await tester.pumpWidget(_grid(
        _document(name: 'Extremely long scanned document name that will not fit'),
        textScale: 1.0,
      ));
      expect(tester.takeException(), isNull);

      final name = tester.widget<Text>(
        find.text('Extremely long scanned document name that will not fit'),
      );
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);
    });

    testWidgets('falls back gracefully when the thumbnail file is gone', (tester) async {
      useScreen(tester);
      await tester.pumpWidget(_grid(_document(), textScale: 1.0));
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.description_outlined), findsOneWidget);
      expect(find.text('4p'), findsOneWidget);
    });
  });
}
