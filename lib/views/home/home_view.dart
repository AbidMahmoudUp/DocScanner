import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../data/models/scan_document.dart';
import '../../data/repositories/document_repository.dart';
import '../../services/export/export_service.dart';
import '../../viewmodels/library_viewmodel.dart';
import '../../viewmodels/settings_viewmodel.dart';
import '../details/details_view.dart';
import '../scan_flow.dart';
import '../widgets/app_feedback.dart';
import 'widgets/document_card.dart';

/// Screen 1 — the library. Hero card for the most recent scan, a grid of the
/// rest, search and tag filters, multi-select, and the scan entry point.
class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  final _searchController = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    await _afterScan(await ScanFlow.startCameraScan(context));
  }

  Future<void> _importFromGallery() async {
    await _afterScan(await ScanFlow.importFromGallery(context));
  }

  /// Refreshes the library and, when a scan was actually saved, opens it.
  Future<void> _afterScan(ScanDocument? saved) async {
    if (!mounted) return;
    await context.read<LibraryViewModel>().load();
    if (!mounted || saved == null) return;
    await _openDocument(saved);
  }

  Future<void> _openDocument(ScanDocument document) async {
    final deleted = await Navigator.of(context).push<DeletedDocument>(
      MaterialPageRoute(builder: (_) => DetailsView(document: document)),
    );
    if (!mounted) return;
    final library = context.read<LibraryViewModel>();
    // The details screen can rename, delete or add pages, so reload rather
    // than trying to guess what changed.
    await library.load();
    if (!mounted || deleted == null) return;

    // Undo lives here, not on the details screen, because that route is gone
    // by the time the snackbar appears.
    AppFeedback.show(
      context,
      'Document deleted',
      actionLabel: 'Undo',
      onAction: () async {
        await library.undoDelete([deleted]);
        if (mounted) AppFeedback.show(context, 'Delete undone');
      },
      onDismissed: () => library.purge([deleted]),
    );
  }

  Future<void> _deleteSelected() async {
    final library = context.read<LibraryViewModel>();
    final targets = library.selectedDocuments;
    if (targets.isEmpty) return;

    final confirmed = await confirmDialog(
      context,
      title: targets.length == 1 ? 'Delete “${targets.first.name}”?' : 'Delete ${targets.length} documents?',
      message: 'The pages will be removed from this device.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    final deleted = await library.delete(targets);
    if (!mounted) return;
    AppFeedback.show(
      context,
      targets.length == 1 ? 'Document deleted' : '${targets.length} documents deleted',
      actionLabel: 'Undo',
      onAction: () async {
        await library.undoDelete(deleted);
        if (mounted) AppFeedback.show(context, 'Delete undone');
      },
      // Once the snackbar is gone the undo offer is over, so the files can go.
      onDismissed: () => library.purge(deleted),
    );
  }

  Future<void> _shareSelected() async {
    final library = context.read<LibraryViewModel>();
    final exporter = context.read<ExportService>();
    final targets = library.selectedDocuments;
    if (targets.isEmpty) return;
    library.clearSelection();
    try {
      await exporter.shareMany(targets);
    } on ExportException catch (error) {
      if (mounted) AppFeedback.error(context, error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryViewModel>();
    final tones = context.tones;

    return Scaffold(
      appBar: _buildAppBar(library),
      floatingActionButton: library.selectionMode
          ? null
          : FloatingActionButton.extended(
              onPressed: _startScan,
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Scan New Document'),
            ),
      bottomNavigationBar: library.selectionMode ? _SelectionBar(
        onShare: _shareSelected,
        onDelete: _deleteSelected,
      ) : null,
      body: Builder(
        builder: (context) {
          if (library.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (library.error != null) {
            return _ErrorState(
              message: library.error!,
              onRetry: () => context.read<LibraryViewModel>().load(),
            );
          }
          if (library.isEmpty) return _EmptyState(onImport: _importFromGallery);

          final documents = library.visibleDocuments;
          return RefreshIndicator(
            onRefresh: () => context.read<LibraryViewModel>().load(),
            child: CustomScrollView(
              slivers: [
                if (library.tags.length > 1)
                  SliverToBoxAdapter(child: _TagFilters(library: library)),
                if (documents.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Text(
                        'No scans match “${library.query}”',
                        style: TextStyle(color: tones.fg3),
                      ),
                    ),
                  )
                else ...[
                  if (!library.selectionMode && library.query.isEmpty && library.activeTag == null)
                    SliverToBoxAdapter(
                      child: _HeroCard(
                        document: documents.first,
                        onTap: () => _openDocument(documents.first),
                      ),
                    ),
                  SliverToBoxAdapter(child: _SectionHeader(count: documents.length)),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
                    sliver: SliverGrid(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 16,
                        childAspectRatio: 0.63,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final document = documents[index];
                          return DocumentCard(
                            document: document,
                            selectionMode: library.selectionMode,
                            selected: library.selectedIds.contains(document.id),
                            onTap: () => library.selectionMode
                                ? library.toggleSelection(document)
                                : _openDocument(document),
                            onLongPress: () => library.beginSelection(document),
                          );
                        },
                        childCount: documents.length,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(LibraryViewModel library) {
    if (library.selectionMode) {
      return AppBar(
        backgroundColor: context.tones.surf2,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Exit selection',
          onPressed: library.clearSelection,
        ),
        title: Text('${library.selectedCount} selected'),
      );
    }

    if (_searching) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Close search',
          onPressed: () {
            _searchController.clear();
            library.setQuery('');
            setState(() => _searching = false);
          },
        ),
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search scans',
            border: InputBorder.none,
          ),
          onChanged: library.setQuery,
        ),
      );
    }

    return AppBar(
      titleSpacing: 20,
      title: const Text(
        'ScanFlow',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -0.4),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.photo_library_outlined),
          tooltip: 'Import from gallery',
          onPressed: _importFromGallery,
        ),
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Search documents',
          onPressed: () => setState(() => _searching = true),
        ),
        IconButton(
          icon: Icon(context.watch<SettingsViewModel>().isDark
              ? Icons.light_mode_outlined
              : Icons.dark_mode_outlined),
          tooltip: 'Toggle theme',
          onPressed: context.read<SettingsViewModel>().toggleTheme,
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

class _TagFilters extends StatelessWidget {
  const _TagFilters({required this.library});
  final LibraryViewModel library;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 52,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: library.tags.length,
          separatorBuilder: (context, index) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final tag = library.tags[index];
            return FilterChip(
              label: Text(tag),
              selected: library.activeTag == tag,
              onSelected: (_) => library.setTagFilter(tag),
            );
          },
        ),
      );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 22, 18, 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            const Text('Recent scans',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            Text(
              '$count document${count == 1 ? '' : 's'}',
              style: TextStyle(fontSize: 11, color: context.tones.fg3),
            ),
          ],
        ),
      );
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.document, required this.onTap});

  final ScanDocument document;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tones = context.tones;
    final cover = document.coverPage;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Material(
        color: tones.surf3,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 82,
                    height: 106,
                    child: cover != null && File(cover.thumbPath).existsSync()
                        ? Image.file(File(cover.thumbPath), fit: BoxFit.cover)
                        : ColoredBox(color: tones.surf2),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'LAST SCANNED',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w600,
                          color: colors.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        document.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${document.pageCount} page${document.pageCount == 1 ? '' : 's'} · '
                        '${formatScanDate(document.updatedAt)}',
                        style: TextStyle(fontSize: 13, color: tones.fg2),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Open',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: colors.primary)),
                          const SizedBox(width: 6),
                          Icon(Icons.arrow_forward, size: 15, color: colors.primary),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.onShare, required this.onDelete});

  final VoidCallback onShare;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: 78,
      decoration: BoxDecoration(
        color: context.tones.surf2,
        border: Border(top: BorderSide(color: context.tones.line)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _SelectionAction(icon: Icons.ios_share, label: 'Share', onTap: onShare),
            _SelectionAction(
              icon: Icons.delete_outline,
              label: 'Delete',
              color: colors.error,
              onTap: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectionAction extends StatelessWidget {
  const _SelectionAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: color)),
            ],
          ),
        ),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onImport});
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tones = context.tones;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                color: colors.surfaceContainer,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: tones.line, style: BorderStyle.solid),
              ),
              child: Icon(Icons.document_scanner_outlined, size: 60, color: colors.primary),
            ),
            const SizedBox(height: 22),
            const Text(
              'Scan your first document',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -0.4),
            ),
            const SizedBox(height: 8),
            Text(
              'Point the camera at a page. ScanFlow finds the edges, '
              'straightens it and saves it here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.55, color: tones.fg3),
            ),
            const SizedBox(height: 18),
            TextButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.photo_library_outlined, size: 18),
              label: const Text('Or import a photo from your gallery'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 40, color: context.colors.error),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      );
}
