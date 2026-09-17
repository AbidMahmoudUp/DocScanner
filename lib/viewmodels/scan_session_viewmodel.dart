import 'package:flutter/foundation.dart';

import '../data/local/file_storage.dart';
import '../data/models/scan_document.dart';
import '../data/repositories/document_repository.dart';

/// The pages captured since the user opened the camera, before they are saved.
///
/// Lives above the camera and preview screens so "Add another page" can bounce
/// between them without losing what was already captured.
class ScanSessionViewModel extends ChangeNotifier {
  ScanSessionViewModel({
    required DocumentRepository repository,
    required FileStorage storage,
  })  : _repository = repository,
        _storage = storage;

  final DocumentRepository _repository;
  final FileStorage _storage;

  final List<PendingPage> _pages = [];
  ScanDocument? _appendTarget;
  bool _saving = false;
  int _savedPages = 0;

  List<PendingPage> get pages => List.unmodifiable(_pages);
  int get pageCount => _pages.length;
  bool get isSaving => _saving;
  int get savedPages => _savedPages;
  bool get isEmpty => _pages.isEmpty;

  /// Set when the session is adding pages to a document that already exists.
  ScanDocument? get appendTarget => _appendTarget;

  /// Starts a fresh capture session, discarding anything left over.
  void begin({ScanDocument? appendTo}) {
    _discardFiles();
    _pages.clear();
    _appendTarget = appendTo;
    _saving = false;
    _savedPages = 0;
    notifyListeners();
  }

  void addPage(PendingPage page) {
    _pages.add(page);
    notifyListeners();
  }

  void replacePage(int index, PendingPage page) {
    _pages[index] = page;
    notifyListeners();
  }

  void removePage(int index) {
    final removed = _pages.removeAt(index);
    _storage.deleteFileIfExists(removed.sourcePath);
    notifyListeners();
  }

  /// Renders and stores everything captured so far.
  ///
  /// Returns the saved document; the raw captures are deleted only after the
  /// save succeeds, so a failure leaves the session intact and retryable.
  Future<ScanDocument> save({required String name, String tag = 'Untagged'}) async {
    if (_pages.isEmpty) throw StateError('Nothing to save');
    _saving = true;
    _savedPages = 0;
    notifyListeners();

    try {
      void progress(int done, int total) {
        _savedPages = done;
        notifyListeners();
      }

      final target = _appendTarget;
      final document = target == null
          ? await _repository.createDocument(
              name: name,
              tag: tag,
              pages: _pages,
              onProgress: progress,
            )
          : await _repository.appendPages(target, _pages, onProgress: progress);

      _discardFiles();
      _pages.clear();
      _appendTarget = null;
      return document;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  /// Throws the session away, including the raw captures on disk.
  void cancel() {
    _discardFiles();
    _pages.clear();
    _appendTarget = null;
    notifyListeners();
  }

  void _discardFiles() {
    for (final page in _pages) {
      _storage.deleteFileIfExists(page.sourcePath);
    }
  }

  /// A sensible default document name: the date, which is what people
  /// recognise a scan by before they rename it.
  String suggestedName() {
    final now = DateTime.now();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return 'Scan ${now.day} ${months[now.month - 1]} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }
}
