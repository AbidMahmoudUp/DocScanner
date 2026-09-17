import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../data/local/file_storage.dart';
import '../../services/cv/cv_worker.dart';
import '../../viewmodels/camera_viewmodel.dart';
import '../../viewmodels/scan_session_viewmodel.dart';
import '../preview/preview_view.dart';
import '../scan_flow.dart';
import '../widgets/app_feedback.dart';
import '../widgets/quad_overlay.dart';
import 'widgets/shutter_button.dart';

/// Screen 2 — the live camera with continuous page detection.
class CameraView extends StatelessWidget {
  const CameraView({super.key});

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (context) => CameraViewModel(
          worker: context.read<CvWorker>(),
          storage: context.read<FileStorage>(),
        )..start(),
        child: const _CameraScaffold(),
      );
}

class _CameraScaffold extends StatefulWidget {
  const _CameraScaffold();

  @override
  State<_CameraScaffold> createState() => _CameraScaffoldState();
}

class _CameraScaffoldState extends State<_CameraScaffold>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final AnimationController _ticker;
  bool _navigating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Repaints the shutter ring while the auto-capture countdown runs; the
    // countdown itself lives in the view model.
    _ticker = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<CameraViewModel>().onAutoCapture = _capture;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final viewModel = context.read<CameraViewModel>();
    // Android reclaims the camera when the app goes to the background; hold
    // the stream only while we are actually visible.
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      viewModel.pause();
    } else if (state == AppLifecycleState.resumed) {
      viewModel.resume();
    }
  }

  Future<void> _capture() async {
    if (_navigating) return;
    final viewModel = context.read<CameraViewModel>();
    final session = context.read<ScanSessionViewModel>();
    _navigating = true;

    try {
      final capture = await viewModel.capture();
      if (!mounted) return;
      if (capture == null) {
        final message = viewModel.errorMessage ?? 'The capture failed';
        AppFeedback.error(context, message, onRetry: _capture);
        await viewModel.resume();
        return;
      }

      final outcome = await ScanFlow.reviewPage(
        context,
        sourcePath: capture.path,
        detectedQuad: capture.quad,
        pageNumber: session.pageCount + 1,
      );
      if (!mounted) return;

      switch (outcome?.action) {
        case PreviewAction.saved:
          // The session is stored; hand the saved document back so whoever
          // started the scan can open it.
          Navigator.of(context).pop(outcome?.document);
        case PreviewAction.addAnother:
          viewModel.sessionPageNumber = session.pageCount + 1;
          await viewModel.resume();
        case PreviewAction.discarded:
        case null:
          await viewModel.resume();
      }
    } finally {
      _navigating = false;
    }
  }

  /// Imports a photo into the session already in progress, so it lands
  /// alongside anything captured so far rather than starting over.
  Future<void> _importFromGallery() async {
    if (_navigating) return;
    _navigating = true;
    final viewModel = context.read<CameraViewModel>();
    try {
      await viewModel.pause();
      if (!mounted) return;
      await ScanFlow.importFromGallery(context, startNewSession: false);
      if (!mounted) return;
      await viewModel.resume();
    } finally {
      _navigating = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<CameraViewModel>();

    return Scaffold(
      backgroundColor: AppColors.cameraBg,
      body: switch (viewModel.status) {
        CameraStatus.permissionDenied => _PermissionDenied(viewModel: viewModel),
        CameraStatus.failed => _CameraFailed(viewModel: viewModel),
        CameraStatus.ready => _LivePreview(
            viewModel: viewModel,
            ticker: _ticker,
            onCapture: _capture,
            onImport: _importFromGallery,
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _LivePreview extends StatelessWidget {
  const _LivePreview({
    required this.viewModel,
    required this.ticker,
    required this.onCapture,
    required this.onImport,
  });

  final CameraViewModel viewModel;
  final Listenable ticker;
  final Future<void> Function() onCapture;
  final Future<void> Function() onImport;

  @override
  Widget build(BuildContext context) {
    final controller = viewModel.controller;
    final session = context.watch<ScanSessionViewModel>();
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return SafeArea(
      child: Column(
        children: [
          _TopBar(viewModel: viewModel),
          Expanded(
            child: Center(
              child: AspectRatio(
                // The controller reports the sensor's landscape ratio; the
                // preview is locked to portrait, so invert it.
                aspectRatio: 1 / controller.value.aspectRatio,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Tap anywhere on the feed to pin focus and exposure.
                    LayoutBuilder(
                      builder: (context, constraints) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (details) => viewModel.focusAt(
                          Offset(
                            details.localPosition.dx / constraints.maxWidth,
                            details.localPosition.dy / constraints.maxHeight,
                          ),
                        ),
                        child: CameraPreview(controller),
                      ),
                    ),
                    if (viewModel.focusPoint != null)
                      _FocusReticle(point: viewModel.focusPoint!),
                    if (viewModel.quad != null)
                      CustomPaint(
                        painter: QuadPainter(
                          quad: viewModel.quad!,
                          color: context.colors.primary,
                          scrimOpacity: 0,
                          fillOpacity: 0.14,
                          handleRadius: 6,
                        ),
                      ),
                    if (viewModel.isLowLight)
                      const Positioned(
                        left: 12,
                        right: 12,
                        top: 12,
                        child: _Banner(
                          icon: Icons.wb_sunny_outlined,
                          text: 'Low light — hold steady or turn on the flash',
                        ),
                      ),
                    if (!viewModel.hasEdges)
                      const Positioned(
                        left: 0,
                        right: 0,
                        bottom: 18,
                        child: _Hint(text: 'No edges detected — tap to capture the full frame'),
                      )
                    else if (viewModel.isWaitingForNewPage)
                      const Positioned(
                        left: 0,
                        right: 0,
                        bottom: 18,
                        child: _Hint(text: 'Page already captured — move to the next one, or tap to shoot again'),
                      ),
                    if (viewModel.isCapturing)
                      const ColoredBox(
                        color: Color(0x66000000),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                  ],
                ),
              ),
            ),
          ),
          _BottomBar(
            viewModel: viewModel,
            ticker: ticker,
            onCapture: onCapture,
            onImport: onImport,
            pageNumber: session.pageCount + 1,
          ),
        ],
      ),
    );
  }
}

/// The square that flashes where the user tapped to focus.
///
/// Painted rather than positioned: a [Positioned] has to be a direct child of
/// the [Stack], which rules out wrapping it in a [LayoutBuilder] to get the
/// preview's size.
class _FocusReticle extends StatelessWidget {
  const _FocusReticle({required this.point});
  final Offset point;

  @override
  Widget build(BuildContext context) => Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(painter: _ReticlePainter(point)),
        ),
      );
}

class _ReticlePainter extends CustomPainter {
  const _ReticlePainter(this.point);
  final Offset point;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(point.dx * size.width, point.dy * size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: centre, width: 72, height: 72),
        const Radius.circular(8),
      ),
      Paint()
        ..color = AppColors.shutter
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_ReticlePainter old) => old.point != point;
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.viewModel});
  final CameraViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 60,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Color(0xFFF2F1ED)),
            tooltip: 'Close camera',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const Spacer(),
          _ModeToggle(viewModel: viewModel),
          const Spacer(),
          _FlashButton(viewModel: viewModel),
        ],
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.viewModel});
  final CameraViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0x1AF2F1ED),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final mode in CaptureMode.values)
            GestureDetector(
              onTap: () => viewModel.setMode(mode),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: viewModel.mode == mode ? const Color(0xFFF2F1ED) : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  mode.name[0].toUpperCase() + mode.name.substring(1),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: viewModel.mode == mode
                        ? const Color(0xFF0A0E1A)
                        : const Color(0xFFF2F1ED),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FlashButton extends StatelessWidget {
  const _FlashButton({required this.viewModel});
  final CameraViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final label = switch (viewModel.flashMode) {
      FlashMode.off => 'OFF',
      FlashMode.auto => 'AUTO',
      FlashMode.always => 'ON',
      FlashMode.torch => 'TORCH',
    };
    final active = viewModel.flashMode != FlashMode.off;
    return InkWell(
      onTap: viewModel.cycleFlash,
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        width: 56,
        height: 56,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              active ? Icons.flash_on : Icons.flash_off,
              color: active ? AppColors.shutter : const Color(0xFFA8AEC4),
              size: 21,
            ),
            Text(
              label,
              style: TextStyle(
                fontSize: 8,
                letterSpacing: 1,
                color: active ? AppColors.shutter : const Color(0xFFA8AEC4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.viewModel,
    required this.ticker,
    required this.onCapture,
    required this.onImport,
    required this.pageNumber,
  });

  final CameraViewModel viewModel;
  final Listenable ticker;
  final Future<void> Function() onCapture;
  final Future<void> Function() onImport;
  final int pageNumber;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 150,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Semantics(
            button: true,
            label: 'Import a photo from the gallery',
            child: InkWell(
              onTap: onImport,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0x1AF2F1ED),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x8CF2F1ED), width: 1.5),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.photo_library_outlined, color: Color(0xFFF2F1ED), size: 20),
                    SizedBox(height: 2),
                    Text('Import', style: TextStyle(fontSize: 8, color: Color(0xFFA8AEC4))),
                  ],
                ),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: ticker,
            builder: (context, _) => ShutterButton(
              progress: viewModel.autoCaptureProgress,
              enabled: !viewModel.isCapturing,
              onPressed: onCapture,
            ),
          ),
          SizedBox(
            width: 56,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0x24F2F1ED),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'Page $pageNumber',
                    style: const TextStyle(fontSize: 11, color: Color(0xFFF2F1ED)),
                  ),
                ),
                if (viewModel.mode == CaptureMode.auto) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'AUTO\nCAPTURE',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 8,
                      height: 1.3,
                      letterSpacing: 1,
                      color: AppColors.shutter,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xEBFFB547),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: const Color(0xFF2A1B02)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF2A1B02),
                ),
              ),
            ),
          ],
        ),
      );
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});
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
              color: Color(0xFFA8AEC4),
            ),
          ),
        ),
      );
}

class _PermissionDenied extends StatelessWidget {
  const _PermissionDenied({required this.viewModel});
  final CameraViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return _RecoveryScaffold(
      icon: Icons.no_photography_outlined,
      title: 'Camera access is off',
      message: 'ScanFlow needs the camera to capture pages. '
          'Your existing scans are still available on the home screen.',
      footnote: 'Opens Settings › Apps › ScanFlow › Permissions',
      primaryLabel: 'Open settings',
      onPrimary: viewModel.openSystemSettings,
      secondaryLabel: 'Back to my scans',
      iconColor: colors.onErrorContainer,
      iconBackground: colors.errorContainer,
    );
  }
}

class _CameraFailed extends StatelessWidget {
  const _CameraFailed({required this.viewModel});
  final CameraViewModel viewModel;

  @override
  Widget build(BuildContext context) => _RecoveryScaffold(
        icon: Icons.videocam_off_outlined,
        title: 'The camera could not start',
        message: viewModel.errorMessage ?? 'Something went wrong while opening the camera.',
        primaryLabel: 'Try again',
        onPrimary: viewModel.start,
        secondaryLabel: 'Back to my scans',
        iconColor: context.colors.onErrorContainer,
        iconBackground: context.colors.errorContainer,
      );
}

class _RecoveryScaffold extends StatelessWidget {
  const _RecoveryScaffold({
    required this.icon,
    required this.title,
    required this.message,
    required this.primaryLabel,
    required this.onPrimary,
    required this.secondaryLabel,
    required this.iconColor,
    required this.iconBackground,
    this.footnote,
  });

  final IconData icon;
  final String title;
  final String message;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String secondaryLabel;
  final Color iconColor;
  final Color iconBackground;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Color(0xFFF2F1ED)),
              onPressed: () => Navigator.of(context).pop(),
            ),
            const Spacer(),
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: iconBackground,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: iconColor, size: 28),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              style: const TextStyle(
                fontSize: 26,
                height: 1.2,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.5,
                color: Color(0xFFF2F1ED),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              style: const TextStyle(fontSize: 15, height: 1.55, color: Color(0xFFA8AEC4)),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: onPrimary,
                child: Text(primaryLabel),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  foregroundColor: const Color(0xFFF2F1ED),
                  side: const BorderSide(color: Color(0xFF3D4670)),
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(secondaryLabel),
              ),
            ),
            if (footnote != null) ...[
              const SizedBox(height: 16),
              Text(
                footnote!,
                style: const TextStyle(fontSize: 12, height: 1.5, color: Color(0xFF6E7596)),
              ),
            ],
            const Spacer(flex: 2),
          ],
        ),
      ),
    );
  }
}
