import 'package:flutter/material.dart';

import '../../data/models/quad.dart';

/// Draws a detected or user-adjusted page outline: everything outside the quad
/// is dimmed, the edges are stroked, and the corners carry grab handles.
class QuadPainter extends CustomPainter {
  const QuadPainter({
    required this.quad,
    required this.color,
    this.showHandles = false,
    this.handleRadius = 8,
    this.scrimOpacity = 0.45,
    this.fillOpacity = 0.12,
    this.activeCorner,
  });

  final Quad quad;
  final Color color;
  final bool showHandles;
  final double handleRadius;
  final double scrimOpacity;
  final double fillOpacity;
  final int? activeCorner;

  @override
  void paint(Canvas canvas, Size size) {
    final points = quad.toPixels(size);
    final path = Path()..addPolygon(points, true);

    if (scrimOpacity > 0) {
      // Even-odd against the full rect punches the page out of the scrim in a
      // single draw — cheaper and cleaner than four trapezoid fills.
      final scrim = Path()
        ..addRect(Offset.zero & size)
        ..addPath(path, Offset.zero)
        ..fillType = PathFillType.evenOdd;
      canvas.drawPath(scrim, Paint()..color = Colors.black.withValues(alpha: scrimOpacity));
    }

    if (fillOpacity > 0) {
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: fillOpacity));
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );

    for (var i = 0; i < points.length; i++) {
      final active = activeCorner == i;
      final radius = showHandles ? handleRadius * (active ? 1.5 : 1) : handleRadius * 0.6;
      if (showHandles) {
        canvas.drawCircle(points[i], radius, Paint()..color = Colors.white);
      }
      canvas.drawCircle(
        points[i],
        showHandles ? radius - 2.5 : radius,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(QuadPainter old) =>
      old.quad != quad ||
      old.color != color ||
      old.showHandles != showHandles ||
      old.activeCorner != activeCorner;
}

/// The crop editor: an image with four draggable corners.
///
/// Coordinates are normalized, so the quad the user leaves here applies
/// unchanged to the full-resolution original.
class CropEditor extends StatelessWidget {
  const CropEditor({
    super.key,
    required this.quad,
    required this.child,
    required this.onCornerGrabbed,
    required this.onCornerMoved,
    required this.onReleased,
    this.activeCorner,
    this.enabled = true,
  });

  final Quad quad;
  final Widget child;
  final void Function(int cornerIndex) onCornerGrabbed;
  final void Function(Offset normalized) onCornerMoved;
  final VoidCallback onReleased;
  final int? activeCorner;
  final bool enabled;

  /// Fingers are wider than the dot, so accept a grab anywhere within this
  /// radius in logical pixels.
  static const _grabRadius = 36.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: enabled ? (details) => _grab(details.localPosition, size) : null,
          onPanUpdate: enabled
              ? (details) => onCornerMoved(_normalize(details.localPosition, size))
              : null,
          onPanEnd: enabled ? (_) => onReleased() : null,
          onPanCancel: enabled ? onReleased : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              child,
              CustomPaint(
                painter: QuadPainter(
                  quad: quad,
                  color: Theme.of(context).colorScheme.primary,
                  showHandles: enabled,
                  activeCorner: activeCorner,
                  scrimOpacity: 0.5,
                  fillOpacity: 0,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _grab(Offset position, Size size) {
    final points = quad.toPixels(size);
    var nearest = 0;
    var nearestDistance = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final distance = (points[i] - position).distance;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = i;
      }
    }
    if (nearestDistance <= _grabRadius) {
      onCornerGrabbed(nearest);
      onCornerMoved(_normalize(position, size));
    }
  }

  static Offset _normalize(Offset position, Size size) => Offset(
        (position.dx / size.width).clamp(0.0, 1.0),
        (position.dy / size.height).clamp(0.0, 1.0),
      );
}
