import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../data/models/scan_document.dart';
import '../../data/repositories/document_repository.dart';
import '../../services/export/export_service.dart';
import '../../viewmodels/document_viewmodel.dart';
import '../../viewmodels/scan_session_viewmodel.dart';
import '../camera/camera_view.dart';
import '../home/widgets/document_card.dart' show formatScanDate;
import '../widgets/app_feedback.dart';

/// Screen 4 — one document: page viewer, metadata, exports and destructive
/// actions. Pops with a [DeletedDocument] when the user deletes it, so the
/// home screen can offer undo.
class DetailsView extends StatelessWidget {
  const DetailsView({super.key, required this.document});

  final ScanDocument document;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (context) => DocumentViewModel(
          repository: context.read<DocumentRepository>(),
          exportService: context.read<ExportService>(),
          document: document,
        ),
        child: const _DetailsScaffold(),
      );
}

class _DetailsScaffold extends StatefulWidget {
  const _DetailsScaffold();

  @override
  State<_DetailsScaffold> createState() => _DetailsScaffoldState();
}

class _DetailsScaffoldState extends State<_DetailsScaffold> {
  late final PageController _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _runExport(Future<ExportOutcome> Function() action) async {
    final outcome = await action();
    if (!mounted) return;
    if (outcome.failed) {
      AppFeedback.error(context, outcome.message, onRetry: () => _runExport(action));
    } else {
      AppFeedback.show(context, outcome.message);
    }
  }

  Future<void> _rename() async {
    final viewModel = context.read<DocumentViewModel>();
    viewModel.beginRename();
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: viewModel,
        child: const _RenameDialog(),
      ),
    );
    if (saved == true && mounted) AppFeedback.show(context, 'Renamed');
  }

  Future<void> _delete() async {
    final viewModel = context.read<DocumentViewModel>();
    final confirmed = await confirmDialog(
      context,
      title: 'Delete “${viewModel.document.name}”?',
      message: '${viewModel.document.pageCount} page'
          '${viewModel.document.pageCount == 1 ? '' : 's'} will be removed from this device.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final deleted = await viewModel.deleteDocument();
    if (!mounted) return;
    // The home screen owns the undo snackbar — it outlives this route.
    Navigator.of(context).pop(deleted);
  }

  Future<void> _deletePage() async {
    final viewModel = context.read<DocumentViewModel>();
    if (viewModel.document.pageCount <= 1) {
      AppFeedback.show(context, 'A document needs at least one page — delete the document instead');
      return;
    }
    final confirmed = await confirmDialog(
      context,
      title: 'Delete page ${viewModel.pageIndex + 1}?',
      message: 'The other pages stay in this document.',
      confirmLabel: 'Delete page',
      destructive: true,
    );
    if (!confirmed) return;
    await viewModel.deleteCurrentPage();
    if (mounted) _pageController.jumpToPage(viewModel.pageIndex);
  }

  Future<void> _addPages() async {
    final viewModel = context.read<DocumentViewModel>();
    final session = context.read<ScanSessionViewModel>();
    session.begin(appendTo: viewModel.document);

    // The return value is the saved document, but this screen already shows
    // it — it reloads from the repository below instead.
    await Navigator.of(context).push<ScanDocument>(
      MaterialPageRoute(builder: (_) => const CameraView()),
    );
    if (!mounted) return;

    final refreshed = await context.read<DocumentRepository>().findById(viewModel.document.id);
    if (refreshed != null && mounted) viewModel.adoptDocument(refreshed);
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<DocumentViewModel>();
    final document = viewModel.document;
    final tones = context.tones;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          document.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.ios_share),
            onPressed: viewModel.isBusy ? null : () => _runExport(viewModel.sharePdf),
          ),
          PopupMenuButton<String>(
            onSelected: (value) => switch (value) {
              'rename' => _rename(),
              'addPages' => _addPages(),
              'deletePage' => _deletePage(),
              'shareImages' => _runExport(viewModel.shareImages),
              _ => null,
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'addPages', child: Text('Add pages')),
              PopupMenuItem(value: 'shareImages', child: Text('Share as images')),
              PopupMenuItem(value: 'deletePage', child: Text('Delete this page')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: document.pages.isEmpty
                ? Center(child: Text('This document has no pages', style: TextStyle(color: tones.fg3)))
                : PageView.builder(
                    controller: _pageController,
                    itemCount: document.pageCount,
                    onPageChanged: viewModel.setPage,
                    itemBuilder: (context, index) => _PageCanvas(path: document.pages[index].filePath),
                  ),
          ),
          if (document.pageCount > 1) _PageDots(count: document.pageCount, active: viewModel.pageIndex),
          _MetaRow(document: document),
          _ActionBar(
            busy: viewModel.isBusy,
            onRename: _rename,
            onGallery: () => _runExport(viewModel.saveToGallery),
            onPdf: () => _runExport(viewModel.sharePdf),
            onAddPages: _addPages,
            onDelete: _delete,
          ),
        ],
      ),
    );
  }
}

class _PageCanvas extends StatelessWidget {
  const _PageCanvas({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final file = File(path);
    if (!file.existsSync()) {
      return Center(
        child: Text('This page image is missing', style: TextStyle(color: context.colors.error)),
      );
    }
    return InteractiveViewer(
      maxScale: 4,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.file(file, fit: BoxFit.contain, gaplessPlayback: true),
        ),
      ),
    );
  }
}

class _PageDots extends StatelessWidget {
  const _PageDots({required this.count, required this.active});
  final int count;
  final int active;

  @override
  Widget build(BuildContext context) {
    // Beyond eight pages the dots stop being readable; the metadata row still
    // carries the exact count.
    final shown = count.clamp(0, 8);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < shown; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              margin: const EdgeInsets.symmetric(horizontal: 3.5),
              width: i == active ? 22 : 7,
              height: 7,
              decoration: BoxDecoration(
                color: i == active ? context.colors.primary : context.tones.line,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.document});
  final ScanDocument document;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: context.colors.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                document.tag,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.colors.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${document.pageCount} page${document.pageCount == 1 ? '' : 's'} · '
                '${formatScanDate(document.updatedAt)}',
                style: TextStyle(fontSize: 12, color: context.tones.fg3),
              ),
            ),
          ],
        ),
      );
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.busy,
    required this.onRename,
    required this.onGallery,
    required this.onPdf,
    required this.onAddPages,
    required this.onDelete,
  });

  final bool busy;
  final VoidCallback onRename;
  final VoidCallback onGallery;
  final VoidCallback onPdf;
  final VoidCallback onAddPages;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.tones.line)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            _Action(icon: Icons.drive_file_rename_outline, label: 'Rename', onTap: busy ? null : onRename),
            const SizedBox(width: 7),
            _Action(icon: Icons.photo_library_outlined, label: 'Gallery', onTap: busy ? null : onGallery),
            const SizedBox(width: 7),
            _Action(icon: Icons.picture_as_pdf_outlined, label: 'PDF', onTap: busy ? null : onPdf),
            const SizedBox(width: 7),
            _Action(icon: Icons.add_a_photo_outlined, label: 'Pages', onTap: busy ? null : onAddPages),
            const SizedBox(width: 10),
            SizedBox(
              width: 56,
              height: 56,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  foregroundColor: colors.error,
                  side: BorderSide(color: colors.error),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: busy ? null : onDelete,
                child: const Icon(Icons.delete_outline, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Expanded(
        child: SizedBox(
          height: 56,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.zero,
              foregroundColor: context.colors.onSurface,
              side: BorderSide(color: context.tones.line),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: onTap,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 19),
                const SizedBox(height: 4),
                Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
      );
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog();

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: context.read<DocumentViewModel>().draftName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<DocumentViewModel>();
    return AlertDialog(
      title: const Text('Rename document',
          style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.3)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: 'Document name',
          errorText: viewModel.nameError,
          helperText: viewModel.nameError == null ? 'Used as the PDF filename.' : null,
          border: const OutlineInputBorder(),
        ),
        onChanged: viewModel.updateDraftName,
        onSubmitted: (_) => _save(viewModel),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel', style: TextStyle(color: context.tones.fg2)),
        ),
        FilledButton(
          onPressed: viewModel.canSaveName ? () => _save(viewModel) : null,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save(DocumentViewModel viewModel) async {
    final saved = await viewModel.commitRename();
    if (saved && mounted) Navigator.of(context).pop(true);
  }
}
