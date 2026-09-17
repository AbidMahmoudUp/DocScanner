import 'package:flutter/foundation.dart';

import '../data/models/scan_document.dart';
import '../data/models/scan_page.dart';
import '../data/repositories/document_repository.dart';
import '../services/export/export_service.dart';

/// The outcome of an export, so the view can show the right snackbar without
/// knowing how exporting works.
class ExportOutcome {
  const ExportOutcome.success(this.message) : failed = false;
  const ExportOutcome.failure(this.message) : failed = true;
  final String message;
  final bool failed;
}

/// Details screen state: the open document, which page is showing, renaming,
/// and the export actions.
class DocumentViewModel extends ChangeNotifier {
  DocumentViewModel({
    required DocumentRepository repository,
    required ExportService exportService,
    required ScanDocument document,
  })  : _repository = repository,
        _exportService = exportService,
        _document = document;

  final DocumentRepository _repository;
  final ExportService _exportService;

  ScanDocument _document;
  int _pageIndex = 0;
  bool _busy = false;
  String _draftName = '';
  bool _nameTouched = false;
  String? _nameError;

  ScanDocument get document => _document;
  int get pageIndex => _pageIndex.clamp(0, _document.pages.isEmpty ? 0 : _document.pages.length - 1);
  ScanPage? get currentPage =>
      _document.pages.isEmpty ? null : _document.pages[pageIndex];
  bool get isBusy => _busy;
  String get draftName => _draftName;
  String? get nameError => _nameTouched ? _nameError : null;
  bool get canSaveName => _nameError == null && _draftName.trim().isNotEmpty;

  void setPage(int index) {
    if (index < 0 || index >= _document.pages.length || index == _pageIndex) return;
    _pageIndex = index;
    notifyListeners();
  }

  /// ── rename ─────────────────────────────────────────────────────────────

  void beginRename() {
    _draftName = _document.name;
    _nameTouched = false;
    _nameError = null;
    notifyListeners();
  }

  /// Validates as the user types. The duplicate check hits the database, so
  /// the result can land after another keystroke — the guard below drops
  /// stale answers rather than flashing an error for text already replaced.
  Future<void> updateDraftName(String value) async {
    _draftName = value;
    _nameTouched = true;
    final trimmed = value.trim();

    if (trimmed.isEmpty) {
      _nameError = 'Name can\'t be empty';
      notifyListeners();
      return;
    }

    notifyListeners();
    final taken = await _repository.isNameTaken(trimmed, excludingId: _document.id);
    if (_draftName != value) return;
    _nameError = taken ? 'A document with this name already exists' : null;
    notifyListeners();
  }

  Future<bool> commitRename() async {
    final trimmed = _draftName.trim();
    if (!canSaveName) {
      _nameTouched = true;
      notifyListeners();
      return false;
    }
    _document = await _repository.rename(_document, trimmed);
    notifyListeners();
    return true;
  }

  Future<void> setTag(String tag) async {
    _document = await _repository.setTag(_document, tag);
    notifyListeners();
  }

  /// ── pages ──────────────────────────────────────────────────────────────

  Future<void> deleteCurrentPage() async {
    final page = currentPage;
    if (page == null) return;
    _document = await _repository.deletePage(_document, page);
    _pageIndex = _pageIndex.clamp(0, _document.pages.isEmpty ? 0 : _document.pages.length - 1);
    notifyListeners();
  }

  Future<void> reorderPage(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    _document = await _repository.reorderPages(_document, oldIndex, newIndex);
    notifyListeners();
  }

  /// Called after the scan session appends pages, so the view reflects them.
  void adoptDocument(ScanDocument document) {
    _document = document;
    notifyListeners();
  }

  Future<DeletedDocument> deleteDocument() => _repository.delete(_document);

  /// ── exports ────────────────────────────────────────────────────────────

  /// Builds the PDF and hands it straight to the share sheet.
  ///
  /// The file lands in app-private storage, which the user cannot browse to,
  /// so building without offering to send it would produce a file they can
  /// never reach.
  Future<ExportOutcome> sharePdf() => _guard(() async {
        await _exportService.sharePdf(_document);
        return const ExportOutcome.success('Shared as PDF');
      });

  Future<ExportOutcome> shareImages() => _guard(() async {
        await _exportService.shareImages(_document);
        return const ExportOutcome.success('Shared as images');
      });

  Future<ExportOutcome> saveToGallery() => _guard(() async {
        final count = await _exportService.saveToGallery(_document);
        return ExportOutcome.success(
          'Saved $count image${count == 1 ? '' : 's'} to Gallery',
        );
      });

  /// Runs an export with a busy flag and turns any failure into a message the
  /// view can retry — an export must never fail silently.
  Future<ExportOutcome> _guard(Future<ExportOutcome> Function() action) async {
    if (_busy) return const ExportOutcome.failure('Another export is still running');
    _busy = true;
    notifyListeners();
    try {
      return await action();
    } on ExportException catch (error) {
      return ExportOutcome.failure(error.message);
    } catch (error) {
      return ExportOutcome.failure('Export failed: $error');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
