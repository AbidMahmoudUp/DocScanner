import 'package:flutter/foundation.dart';

import '../data/repositories/document_repository.dart';
import '../data/models/scan_document.dart';

/// Home screen state: the library, its search and tag filter, and the
/// multi-select mode layered on top.
class LibraryViewModel extends ChangeNotifier {
  LibraryViewModel(this._repository);

  final DocumentRepository _repository;

  List<ScanDocument> _documents = const [];
  List<String> _tags = const [];
  String _query = '';
  String? _activeTag;
  final Set<String> _selectedIds = {};
  bool _selectionMode = false;
  bool _loading = true;
  String? _error;

  List<ScanDocument> get documents => _documents;
  List<String> get tags => _tags;
  String get query => _query;
  String? get activeTag => _activeTag;
  bool get selectionMode => _selectionMode;
  Set<String> get selectedIds => _selectedIds;
  int get selectedCount => _selectedIds.length;
  bool get isLoading => _loading;
  String? get error => _error;

  /// True only when the library itself is empty — a search that matches
  /// nothing is a different, non-first-run state.
  bool get isEmpty => !_loading && _documents.isEmpty;

  List<ScanDocument> get visibleDocuments {
    final needle = _query.trim().toLowerCase();
    return [
      for (final document in _documents)
        if ((_activeTag == null || document.tag == _activeTag) &&
            (needle.isEmpty ||
                document.name.toLowerCase().contains(needle) ||
                document.tag.toLowerCase().contains(needle)))
          document,
    ];
  }

  List<ScanDocument> get selectedDocuments =>
      [for (final d in _documents) if (_selectedIds.contains(d.id)) d];

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _documents = await _repository.loadAll();
      _tags = await _repository.allTags();
      // A tag filter can outlive the last document carrying it.
      if (_activeTag != null && !_tags.contains(_activeTag)) _activeTag = null;
    } catch (error) {
      _error = 'Could not load your scans: $error';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void setQuery(String value) {
    _query = value;
    notifyListeners();
  }

  void setTagFilter(String? tag) {
    _activeTag = _activeTag == tag ? null : tag;
    notifyListeners();
  }

  /// ── selection ──────────────────────────────────────────────────────────

  void beginSelection(ScanDocument document) {
    _selectionMode = true;
    _selectedIds
      ..clear()
      ..add(document.id);
    notifyListeners();
  }

  void toggleSelection(ScanDocument document) {
    if (!_selectedIds.remove(document.id)) _selectedIds.add(document.id);
    // Deselecting the last item leaves selection mode, matching the way the
    // rest of Android behaves.
    if (_selectedIds.isEmpty) _selectionMode = false;
    notifyListeners();
  }

  void clearSelection() {
    _selectionMode = false;
    _selectedIds.clear();
    notifyListeners();
  }

  /// ── mutations ──────────────────────────────────────────────────────────

  /// Deletes [documents] and hands back an undo token. The caller purges it
  /// once the undo snackbar is gone.
  Future<List<DeletedDocument>> delete(List<ScanDocument> documents) async {
    final deleted = await _repository.deleteAll(documents);
    clearSelection();
    await load();
    return deleted;
  }

  Future<void> undoDelete(List<DeletedDocument> deleted) async {
    for (final entry in deleted) {
      await entry.restore();
    }
    await load();
  }

  Future<void> purge(List<DeletedDocument> deleted) async {
    for (final entry in deleted) {
      await entry.purge();
    }
  }

  /// Replaces one document in place after an edit elsewhere, so returning from
  /// the details screen does not need a full reload.
  void replace(ScanDocument document) {
    final index = _documents.indexWhere((d) => d.id == document.id);
    if (index == -1) return;
    _documents = List<ScanDocument>.of(_documents)..[index] = document;
    notifyListeners();
  }
}
