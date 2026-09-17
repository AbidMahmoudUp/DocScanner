import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/file_storage.dart';
import '../data/models/quad.dart';
import '../data/models/scan_document.dart';
import '../services/cv/cv_worker.dart';
import '../services/import/image_import_service.dart';
import '../viewmodels/scan_session_viewmodel.dart';
import 'camera/camera_view.dart';
import 'preview/preview_view.dart';
import 'widgets/app_feedback.dart';

/// Navigation for the capture → review → save flow, shared by the home screen
/// (which starts a session) and the camera screen (which adds to one).
///
/// Both entry points funnel into [reviewPage], so an imported photo and a
/// fresh capture go through exactly the same detection, crop and enhancement.
abstract final class ScanFlow {
  /// Opens the review screen for one page.
  static Future<PreviewOutcome?> reviewPage(
    BuildContext context, {
    required String sourcePath,
    required Quad? detectedQuad,
    required int pageNumber,
  }) =>
      Navigator.of(context).push<PreviewOutcome>(
        MaterialPageRoute(
          builder: (_) => PreviewView(
            sourcePath: sourcePath,
            detectedQuad: detectedQuad,
            pageNumber: pageNumber,
          ),
        ),
      );

  /// Starts a fresh scan session on the camera.
  ///
  /// Returns the saved document when the session ended in a save, so the
  /// caller can open it — finishing a scan should land you on the thing you
  /// just scanned, not back where you started.
  static Future<ScanDocument?> startCameraScan(
    BuildContext context, {
    ScanDocument? appendTo,
  }) {
    context.read<ScanSessionViewModel>().begin(appendTo: appendTo);
    return Navigator.of(context).push<ScanDocument>(
      MaterialPageRoute(builder: (_) => const CameraView()),
    );
  }

  /// Picks photos from the gallery and reviews each one in turn.
  ///
  /// Every picked image gets its own review screen rather than being imported
  /// blind — an auto-detected crop applied sight-unseen to a batch is exactly
  /// how you end up with a folder of half-cropped pages.
  ///
  /// Pass [startNewSession] false when the camera calls this, so the photo
  /// joins the pages already captured instead of replacing them.
  static Future<ScanDocument?> importFromGallery(
    BuildContext context, {
    ScanDocument? appendTo,
    bool startNewSession = true,
  }) async {
    final session = context.read<ScanSessionViewModel>();
    final importer = context.read<ImageImportService>();
    final worker = context.read<CvWorker>();
    final storage = context.read<FileStorage>();

    final List<String> paths;
    try {
      paths = await importer.pickFromGallery();
    } on ImportException catch (error) {
      if (context.mounted) AppFeedback.error(context, error.message);
      return null;
    }
    if (paths.isEmpty || !context.mounted) return null;

    if (startNewSession) session.begin(appendTo: appendTo);

    var wantsMorePages = false;
    for (final path in paths) {
      if (!context.mounted) return null;

      // Detection on a full-resolution photo takes a moment; say so rather
      // than leaving the picker's dismissal looking like a dropped tap.
      final quad = await _withBusyOverlay(
        context,
        message: 'Finding the page…',
        task: () => worker.detectInFile(path),
      );
      if (!context.mounted) return null;

      final outcome = await reviewPage(
        context,
        sourcePath: path,
        detectedQuad: quad,
        pageNumber: session.pageCount + 1,
      );

      switch (outcome?.action) {
        case PreviewAction.saved:
          return outcome?.document;
        case PreviewAction.addAnother:
          wantsMorePages = true;
        case PreviewAction.discarded:
        case null:
          // Review was abandoned, so the copy we made is dead weight.
          await storage.deleteFileIfExists(path);
          wantsMorePages = false;
      }
    }

    // They asked for another page on the last photo and there are none left,
    // so hand them the camera to finish the document.
    if (wantsMorePages && context.mounted) {
      return Navigator.of(context).push<ScanDocument>(
        MaterialPageRoute(builder: (_) => const CameraView()),
      );
    }
    return null;
  }

  /// Runs [task] behind a dismissal-proof spinner.
  ///
  /// The overlay route is held and removed by identity rather than popped:
  /// popping "whatever is on top" would tear down the review screen if the
  /// dialog had already gone.
  static Future<T> _withBusyOverlay<T>(
    BuildContext context, {
    required String message,
    required Future<T> Function() task,
  }) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
    unawaited(navigator.push(route));

    try {
      return await task();
    } finally {
      if (route.isActive) navigator.removeRoute(route);
    }
  }
}
