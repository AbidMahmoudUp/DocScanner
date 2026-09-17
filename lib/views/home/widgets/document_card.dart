import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../data/models/scan_document.dart';

/// Thumbnail tile in the recent-scans grid.
class DocumentCard extends StatelessWidget {
  const DocumentCard({
    super.key,
    required this.document,
    required this.onTap,
    required this.onLongPress,
    this.selected = false,
    this.selectionMode = false,
  });

  final ScanDocument document;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selected;
  final bool selectionMode;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tones = context.tones;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(12),
      // The thumbnail takes whatever the two text lines leave, rather than
      // claiming a fixed 3:4 of the cell. With a fixed ratio the labels had to
      // fit exactly the remainder left by childAspectRatio, so any difference
      // in font scale or locale overflowed the card.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _Thumbnail(document: document),
                ),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: _Badge(text: '${document.pageCount}p'),
                ),
                if (selectionMode && selected)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: colors.primary.withValues(alpha: 0.34),
                    ),
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: CircleAvatar(
                          radius: 12,
                          backgroundColor: colors.primary,
                          child: Icon(Icons.check, size: 15, color: colors.onPrimary),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            document.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 3),
          Text(
            formatScanDate(document.updatedAt),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: tones.fg3),
          ),
        ],
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.document});

  final ScanDocument document;

  @override
  Widget build(BuildContext context) {
    final page = document.coverPage;
    final file = page == null ? null : File(page.thumbPath);
    if (file == null || !file.existsSync()) {
      return ColoredBox(
        color: context.tones.surf3,
        child: Icon(Icons.description_outlined, color: context.tones.fg3),
      );
    }
    return Image.file(
      file,
      fit: BoxFit.cover,
      // The thumbnail path never changes content, so let Flutter cache it.
      gaplessPlayback: true,
      errorBuilder: (context, error, stack) => ColoredBox(
        color: context.tones.surf3,
        child: Icon(Icons.broken_image_outlined, color: context.tones.fg3),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xCC0A0E1A),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 10,
            color: Color(0xFFF2F1ED),
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      );
}

/// Relative for the last day, absolute after that — the way people actually
/// look for a scan they just took.
String formatScanDate(DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(date.year, date.month, date.day);
  String two(int n) => n.toString().padLeft(2, '0');

  if (day == today) return 'Today, ${two(date.hour)}:${two(date.minute)}';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';

  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final label = '${date.day} ${months[date.month - 1]}';
  return date.year == now.year ? label : '$label ${date.year}';
}
