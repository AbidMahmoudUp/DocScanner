import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';

/// The shutter: an amber disc inside a ring that fills as the auto-capture
/// countdown runs, so the automatic shot is never a surprise.
class ShutterButton extends StatelessWidget {
  const ShutterButton({
    super.key,
    required this.onPressed,
    this.progress = 0,
    this.enabled = true,
  });

  final Future<void> Function() onPressed;
  final double progress;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Capture page',
      child: GestureDetector(
        onTap: enabled ? () => onPressed() : null,
        child: SizedBox(
          width: 78,
          height: 78,
          child: CustomPaint(
            painter: _ShutterPainter(progress: progress),
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: enabled ? 62 : 54,
                height: enabled ? 62 : 54,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.shutter.withValues(alpha: enabled ? 1 : 0.6),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x73FFB547),
                      blurRadius: 20,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShutterPainter extends CustomPainter {
  const _ShutterPainter({required this.progress});
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    canvas.drawCircle(
      center,
      36,
      Paint()
        ..color = const Color(0x47F2F1ED)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

    if (progress <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: 32),
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      Paint()
        ..color = AppColors.shutter
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ShutterPainter old) => old.progress != progress;
}
