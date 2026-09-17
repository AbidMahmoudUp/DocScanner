import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../data/models/enhance_settings.dart';
import '../../data/models/quad.dart';
import '../../data/models/scan_document.dart';
import '../../services/cv/cv_worker.dart';
import '../../viewmodels/preview_viewmodel.dart';
import '../../viewmodels/scan_session_viewmodel.dart';
import '../../services/export/export_service.dart';
import '../widgets/app_feedback.dart';
import '../widgets/image_sizing.dart';
import '../widgets/quad_overlay.dart';
import '../widgets/scan_reveal.dart';
import 'widgets/save_sheet.dart';

/// What the preview screen decided, handed back to the camera.
enum PreviewAction { saved, addAnother, discarded }

class PreviewOutcome {
  const PreviewOutcome(this.action, {this.document});
  final PreviewAction action;
  final ScanDocument? document;
}

/// Screen 3 — confirm the crop, pick an enhancement, then save or add a page.
class PreviewView extends StatelessWidget {
  const PreviewView({
    super.key,
    required this.sourcePath,
    required this.detectedQuad,
    required this.pageNumber,
  });

  final String sourcePath;
  final Quad? detectedQuad;
  final int pageNumber;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (context) => PreviewViewModel(
          worker: context.read<CvWorker>(),
          sourcePath: sourcePath,
          detectedQuad: detectedQuad,
        )..init(),
        child: _PreviewScaffold(pageNumber: pageNumber),
      );
}

enum _Stage { crop, enhance }

class _PreviewScaffold extends StatefulWidget {
  const _PreviewScaffold({required this.pageNumber});
  final int pageNumber;

  @override
  State<_PreviewScaffold> createState() => _PreviewScaffoldState();
}

class _PreviewScaffoldState extends State<_PreviewScaffold> {
  // Cropping and enhancing want the whole canvas each, so they take turns
  // rather than sharing a cramped split view.
  //
  // Starts on Enhance because that is where the scan lands: the sweep shows
  // the result, and cropping is a correction you make to it afterwards.
  _Stage _stage = _Stage.enhance;
  bool _adjustmentsOpen = true;
  Future<Size>? _sourceSize;

  /// The sweep plays once, when the first rendered result arrives.
  bool _revealPending = true;
  bool _revealing = false;

  /// Set once this page has been handed to the session. A failed save leaves
  /// the page in the session so Retry can re-run it — without this flag the
  /// retry would append a second copy of the same page.
  bool _handedToSession = false;

  @override
  void initState() {
    super.initState();
    final path = context.read<PreviewViewModel>().sourcePath;
    // Only the aspect ratio matters here, and ResizeImage preserves it, so
    // decode a thumbnail instead of a 12MP bitmap just to read two numbers.
    _sourceSize = resolveImageSize(ResizeImage(FileImage(File(path)), width: 256));
  }

  /// Starts the sweep the moment there is a result to reveal.
  void _maybeStartReveal(PreviewViewModel viewModel) {
    if (!_revealPending || viewModel.previewBytes == null) return;
    _revealPending = false;
    // The build that noticed the bytes is the one that would show the overlay,
    // so the flag has to be flipped after it, not during it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _revealing = true);
    });
  }

  Future<bool> _confirmDiscard() async {
    final viewModel = context.read<PreviewViewModel>();
    if (!viewModel.isDirty) return true;
    return confirmDialog(
      context,
      title: 'Discard this page?',
      message: 'Your crop and filter for this page will be lost.',
      confirmLabel: 'Discard',
      destructive: true,
    );
  }

  Future<void> _cancel() async {
    if (!await _confirmDiscard() || !mounted) return;
    Navigator.of(context).pop(const PreviewOutcome(PreviewAction.discarded));
  }

  void _addAnotherPage() {
    if (_handedToSession) return;
    final session = context.read<ScanSessionViewModel>();
    session.addPage(context.read<PreviewViewModel>().toPendingPage());
    _handedToSession = true;
    Navigator.of(context).pop(const PreviewOutcome(PreviewAction.addAnother));
  }

  Future<void> _done() async {
    final session = context.read<ScanSessionViewModel>();
    final viewModel = context.read<PreviewViewModel>();
    if (!_handedToSession) {
      session.addPage(viewModel.toPendingPage());
      _handedToSession = true;
    }

    final appendTarget = session.appendTarget;
    final choice = await showSaveSheet(
      context,
      suggestedName: appendTarget?.name ?? session.suggestedName(),
      pageCount: session.pageCount,
      appendingTo: appendTarget?.name,
    );
    // Dismissing the sheet is a change of mind about saving, not about the
    // page — the session keeps it so Done can be pressed again.
    if (choice == null || !mounted) return;

    await _saveWith(choice);
  }

  Future<void> _saveWith(SaveChoice choice) async {
    final session = context.read<ScanSessionViewModel>();
    final exporter = context.read<ExportService>();

    final ScanDocument document;
    try {
      document = await session.save(name: choice.name);
    } catch (error) {
      if (!mounted) return;
      // The page is still in the session, so Retry re-runs the same save.
      AppFeedback.error(
        context,
        'Could not save the document: $error',
        onRetry: () => _saveWith(choice),
      );
      return;
    }

    // The document is safely stored by this point. Extra copies are a bonus,
    // so a failure here is reported without taking the save down with it.
    final failures = <String>[];
    if (choice.toGallery) {
      try {
        await exporter.saveToGallery(document);
      } on ExportException catch (error) {
        failures.add(error.message);
      }
    }
    if (choice.toPdf) {
      try {
        await exporter.sharePdf(document);
      } on ExportException catch (error) {
        failures.add(error.message);
      }
    }

    if (!mounted) return;
    if (failures.isNotEmpty) {
      AppFeedback.error(context, 'Saved, but: ${failures.join(' · ')}');
    }
    Navigator.of(context).pop(PreviewOutcome(PreviewAction.saved, document: document));
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<PreviewViewModel>();
    final session = context.watch<ScanSessionViewModel>();
    final tones = context.tones;
    _maybeStartReveal(viewModel);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          leadingWidth: 90,
          leading: TextButton(
            onPressed: session.isSaving || _revealing ? null : _cancel,
            child: Text('Cancel', style: TextStyle(color: tones.fg2, fontSize: 15)),
          ),
          centerTitle: true,
          title: Text(
            'Page ${widget.pageNumber}',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
              color: tones.fg3,
            ),
          ),
          actions: [
            TextButton(
              onPressed: session.isSaving || _revealing ? null : _done,
              child: const Text(
                'Done',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: IgnorePointer(
                ignoring: _revealing,
                child: AnimatedOpacity(
                  opacity: _revealing ? 0.4 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: _StageToggle(
                    stage: _stage,
                    onChanged: (stage) => setState(() => _stage = stage),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _stage == _Stage.crop
                          ? _CropStage(viewModel: viewModel, sourceSize: _sourceSize)
                          : _EnhanceStage(viewModel: viewModel),
                    ),
                    if (_revealing && viewModel.previewBytes != null)
                      Positioned.fill(
                        child: ColoredBox(
                          color: Theme.of(context).colorScheme.surface,
                          child: ScanReveal(
                            original: ResizeImage(
                              FileImage(File(viewModel.sourcePath)),
                              width: 900,
                            ),
                            result: MemoryImage(viewModel.previewBytes!),
                            quad: viewModel.edgesDetected ? viewModel.quad : null,
                            onComplete: () {
                              if (mounted) setState(() => _revealing = false);
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            _BottomPanel(
              stage: _stage,
              viewModel: viewModel,
              adjustmentsOpen: _adjustmentsOpen,
              onToggleAdjustments: () => setState(() => _adjustmentsOpen = !_adjustmentsOpen),
              onAddPage: session.isSaving || _revealing ? null : _addAnotherPage,
              savingProgress: session.isSaving
                  ? '${session.savedPages}/${session.pageCount}'
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _StageToggle extends StatelessWidget {
  const _StageToggle({required this.stage, required this.onChanged});

  final _Stage stage;
  final ValueChanged<_Stage> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<_Stage>(
        segments: const [
          ButtonSegment(
            value: _Stage.crop,
            label: Text('Crop'),
            icon: Icon(Icons.crop_free, size: 18),
          ),
          ButtonSegment(
            value: _Stage.enhance,
            label: Text('Enhance'),
            icon: Icon(Icons.auto_fix_high_outlined, size: 18),
          ),
        ],
        selected: {stage},
        showSelectedIcon: false,
        onSelectionChanged: (selection) => onChanged(selection.first),
      );
}

class _CropStage extends StatelessWidget {
  const _CropStage({required this.viewModel, required this.sourceSize});

  final PreviewViewModel viewModel;
  final Future<Size>? sourceSize;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: FutureBuilder<Size>(
            future: sourceSize,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final size = snapshot.data!;
              return Center(
                child: AspectRatio(
                  aspectRatio: size.width / size.height,
                  child: CropEditor(
                    quad: viewModel.quad,
                    activeCorner: viewModel.draggingCorner,
                    onCornerGrabbed: viewModel.beginDrag,
                    onCornerMoved: viewModel.dragCornerTo,
                    onReleased: viewModel.endDrag,
                    child: Image.file(
                      File(viewModel.sourcePath),
                      fit: BoxFit.fill,
                      // Decoding the full capture for a phone-sized canvas is
                      // wasted memory; 1200px is more than the screen shows.
                      cacheWidth: 1200,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: viewModel.resetToFullFrame,
              icon: const Icon(Icons.fullscreen, size: 18),
              label: const Text('Full frame'),
            ),
            const SizedBox(width: 8),
            if (viewModel.canResetToDetected)
              OutlinedButton.icon(
                onPressed: viewModel.resetToDetected,
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('Detected'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (!viewModel.edgesDetected)
          Text(
            'No page edges were found — drag the corners to set the crop.',
            style: TextStyle(fontSize: 12, color: context.tones.fg3),
          ),
      ],
    );
  }
}

class _EnhanceStage extends StatelessWidget {
  const _EnhanceStage({required this.viewModel});
  final PreviewViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final bytes = viewModel.previewBytes;
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              color: context.tones.surf2,
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: bytes == null
                ? const Center(child: CircularProgressIndicator())
                : Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
          ),
        ),
        Positioned(
          right: 8,
          top: 8,
          child: IconButton.filledTonal(
            tooltip: 'Rotate 90°',
            onPressed: viewModel.rotateClockwise,
            icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
          ),
        ),
        if (viewModel.isProcessing && bytes != null)
          Positioned(
            left: 12,
            bottom: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xB80A0E1A),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFF2F1ED)),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Applying ${viewModel.settings.filter.label}…',
                    style: const TextStyle(fontSize: 11, color: Color(0xFFF2F1ED)),
                  ),
                ],
              ),
            ),
          ),
        if (viewModel.error != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Material(
              color: context.colors.errorContainer,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  viewModel.error!,
                  style: TextStyle(fontSize: 12, color: context.colors.onErrorContainer),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _BottomPanel extends StatelessWidget {
  const _BottomPanel({
    required this.stage,
    required this.viewModel,
    required this.adjustmentsOpen,
    required this.onToggleAdjustments,
    required this.onAddPage,
    required this.savingProgress,
  });

  final _Stage stage;
  final PreviewViewModel viewModel;
  final bool adjustmentsOpen;
  final VoidCallback onToggleAdjustments;
  final VoidCallback? onAddPage;
  final String? savingProgress;

  @override
  Widget build(BuildContext context) {
    final tones = context.tones;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: tones.surf2,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.only(top: 10, bottom: 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (stage == _Stage.enhance) ...[
              _FilterStrip(viewModel: viewModel),
              TextButton.icon(
                onPressed: onToggleAdjustments,
                icon: Icon(adjustmentsOpen ? Icons.expand_more : Icons.tune, size: 18),
                label: Text(adjustmentsOpen ? 'Hide adjustments' : 'Adjust brightness & contrast'),
              ),
              if (adjustmentsOpen) _Adjustments(viewModel: viewModel),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: savingProgress == null
                  ? OutlinedButton.icon(
                      onPressed: onAddPage,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        side: BorderSide(color: tones.line),
                      ),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add another page'),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Text('Saving pages $savingProgress…'),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterStrip extends StatelessWidget {
  const _FilterStrip({required this.viewModel});
  final PreviewViewModel viewModel;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 48,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          itemCount: ScanFilter.values.length,
          separatorBuilder: (_, index) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final filter = ScanFilter.values[index];
            return ChoiceChip(
              label: Text(filter.label),
              selected: viewModel.settings.filter == filter,
              onSelected: (_) => viewModel.setFilter(filter),
            );
          },
        ),
      );
}

class _Adjustments extends StatelessWidget {
  const _Adjustments({required this.viewModel});
  final PreviewViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final settings = viewModel.settings;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Column(
        children: [
          _Slider(
            label: 'Brightness',
            value: settings.brightness,
            onChanged: viewModel.setBrightness,
          ),
          _Slider(
            label: 'Contrast',
            value: settings.contrast,
            onChanged: viewModel.setContrast,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: viewModel.resetAdjustments,
              child: const Text('Reset'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider({required this.label, required this.value, required this.onChanged});

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500, color: context.tones.fg2)),
              Text(
                value > 0 ? '+$value' : '$value',
                style: TextStyle(fontSize: 12, color: context.tones.fg2),
              ),
            ],
          ),
          Slider(
            value: value.toDouble(),
            min: -50,
            max: 50,
            divisions: 20,
            onChanged: (next) => onChanged(next.round()),
          ),
        ],
      );
}
