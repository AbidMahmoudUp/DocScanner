import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Decides where every file the app writes lives.
///
/// Layout under the app's private documents directory:
///
/// ```
///   scans/{documentId}/page_{id}.jpg      full-resolution enhanced page
///   scans/{documentId}/thumb_{id}.jpg     list thumbnail
///   captures/{id}.jpg                     raw camera capture, deleted on save
///   exports/{name}.pdf                    generated for sharing
/// ```
class FileStorage {
  FileStorage._(this._root);

  final Directory _root;
  static const _uuid = Uuid();

  static Future<FileStorage> create() async {
    final root = await getApplicationDocumentsDirectory();
    final storage = FileStorage._(root);
    await Directory(storage.capturesDir).create(recursive: true);
    await Directory(storage.exportsDir).create(recursive: true);
    return storage;
  }

  String get scansDir => p.join(_root.path, 'scans');
  String get capturesDir => p.join(_root.path, 'captures');
  String get exportsDir => p.join(_root.path, 'exports');

  String newId() => _uuid.v4();

  /// Creates (if needed) and returns the folder holding one document's pages.
  Future<String> documentDir(String documentId) async {
    final dir = Directory(p.join(scansDir, documentId));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir.path;
  }

  String pagePath(String documentDir, String pageId) => p.join(documentDir, 'page_$pageId.jpg');

  String thumbnailPath(String documentDir, String pageId) =>
      p.join(documentDir, 'thumb_$pageId.jpg');

  /// A scratch path for the raw camera capture, before crop and enhancement.
  String newCapturePath() => p.join(capturesDir, '${newId()}.jpg');

  String exportPath(String fileName) => p.join(exportsDir, fileName);

  Future<void> deleteDocumentDir(String documentId) async {
    final dir = Directory(p.join(scansDir, documentId));
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  Future<void> deleteFileIfExists(String path) async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }

  /// Clears raw captures left behind by a session the user abandoned.
  ///
  /// Called at startup rather than on every cancel, so a crash mid-scan cannot
  /// silently grow the app's storage footprint.
  Future<void> clearStaleCaptures() async {
    final dir = Directory(capturesDir);
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync()) {
      if (entity is File) {
        try {
          await entity.delete();
        } on FileSystemException {
          // A file still held open by an in-flight capture; it will be caught
          // by the next startup sweep.
        }
      }
    }
  }
}
