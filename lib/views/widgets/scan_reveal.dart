import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../data/models/quad.dart';
import 'quad_overlay.dart';

/// The scanner sweep: reads the original photo, then hands over the result.
///
/// Two phases in one timeline. First a bar travels down the captured photo
/// with the detected outline drawn on it — the "reading" the user just asked
/// the app to do. Then the photo gives way to the finished page.
///
/// The two images are *not* cross-dissolved under the bar, which would be the
/// obvious implementation: the capture still has the desk in it and the result
/// is cropped and deskewed, so the two never line up and a wipe between them
/// reads as a glitch rather than a scan. Sweeping first and swapping second
/// keeps both images honest.
class ScanReveal extends StatefulWidget {
  const ScanReveal({
    super.key,
    required this.original,
    required this.result,
    required this.onComplete,
    this.quad,
    this.duration = const Duration(milliseconds: 1900),
  });

  final ImageProvider original;
  final ImageProvider result;

  /// Called once the sweep has finished, or as soon as the user taps to skip.
  final VoidCallback onComplete;

  /// The detected outline, drawn during the reading phase.
  final Quad? quad;

  final Duration duration;

  @override
  State<ScanReveal> createState() => _ScanRevealState();
}

class _ScanRevealState extends State<ScanReveal> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// Where the sweep ends and the handover begins.
  static const _sweepEnd = 0.62;

  var _finished = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _finish();
      })
      ..forward();
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    widget.onComplete();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.tones.shutter;

    return GestureDetector(
      // Nobody wants to watch this twice. A tap anywhere goes straight to the
      // editable result.
      onTap: _finish,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          final sweep = (t / _sweepEnd).clamp(0.0, 1.0);
          final handover = ((t - _sweepEnd) / (1 - _sweepEnd)).clamp(0.0, 1.0);
          final eased = Curves.easeInOutCubic.transform(handover);

          return Stack(
            fit: StackFit.expand,
            children: [
              Opacity(
                opacity: 1 - eased,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image(image: widget.original, fit: BoxFit.contain),
                    if (widget.quad != null)
                      CustomPaint(
                        painter: QuadPainter(
                          quad: widget.quad!,
                          color: Theme.of(context).colorScheme.primary,
                          scrimOpacity: 0.35,
                          fillOpacity: 0.08,
                          handleRadius: 5,
                        ),
                      ),
                    if (sweep < 1)
                      CustomPaint(painter: _SweepPainter(progress: sweep, colour: accent)),
                  ],
                ),
              ),
              if (eased > 0)
                Opacity(
                  opacity: eased,
                  child: Transform.scale(
                    // A slight settle as the page lands, so the handover reads
                    // as the result arriving rather than a hard cut.
                    scale: 0.96 + 0.04 * eased,
                    child: Image(image: widget.result, fit: BoxFit.contain),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 12,
                child: Opacity(
                  opacity: 1 - eased,
                  child: _Caption(
                    text: sweep < 1 ? 'Reading the page…' : 'Enhancing…',
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The travelling bar: a bright line with light pooled behind it.
class _SweepPainter extends CustomPainter {
  const _SweepPainter({required this.progress, required this.colour});

  final double progress;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * progress;
    const trail = 120.0;

    // Everything already swept keeps a faint wash, so the bar looks like it is
    // leaving something behind rather than just sliding over the picture.
    final washTop = (y - trail).clamp(0.0, size.height);
    canvas.drawRect(
      Rect.fromLTRB(0, 0, size.width, washTop),
      Paint()..color = colour.withValues(alpha: 0.05),
    );

    final glow = Rect.fromLTRB(0, washTop, size.width, y);
    canvas.drawRect(
      glow,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [colour.withValues(alpha: 0.0), colour.withValues(alpha: 0.30)],
        ).createShader(glow),
    );

    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = colour
        ..strokeWidth = 2.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.progress != progress;
}

class _Caption extends StatelessWidget {
  const _Caption({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xB80A0E1A),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
              color: Color(0xFFF2F1ED),
            ),
          ),
        ),
      );
}
