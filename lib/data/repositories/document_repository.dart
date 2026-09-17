import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../services/cv/cv_worker.dart';
import '../local/app_database.dart';
import '../local/file_storage.dart';
import '../models/enhance_settings.dart';
import '../models/quad.dart';
import '../models/scan_document.dart';
import '../models/scan_page.dart';

/// One captured-but-not-yet-saved page: the raw file plus the crop and filter
/// the user chose for it.
class PendingPage {
  const PendingPage({
    required this.sourcePath,
    required this.quad,
    required this.settings,
  });

  final String sourcePath;
  final Quad quad;
  final EnhanceSettings settings;

  PendingPage copyWith({Quad? quad, EnhanceSettings? settings}) => PendingPage(
    sourcePath: sourcePath,
    quad: quad ?? this.quad,
    settings: settings ?? this.settings,
  );
}

/// A deleted document held in the trash so the undo snackbar can put it back.
class DeletedDocument {
  const DeletedDocument(this._document, this._trashDir, this._repository);

  final ScanDocument _document;
  final String _trashDir;
  final DocumentRepository _repository;

  ScanDocument get document => _document;

  Future<ScanDocument> restore() => _repository._restore(this);

  /// Drops the files for good. Safe to call twice.
  Future<void> purge() async {
    final dir = Directory(_trashDir);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}

/// The single source of truth for stored scans.
///
/// View models never touch sqflite, the file system or OpenCV directly — they
/// call this, which keeps rendering, rows and files consistent with each other.
class DocumentRepository {
  DocumentRepository({
    required AppDatabase database,
    required FileStorage storage,
    required CvWorker worker,
  })  : _db = database.db,
        _storage = storage,
        _worker = worker;

  final Database _db;
  final FileStorage _storage;
  final CvWorker _worker;

  /// ── reads ──────────────────────────────────────────────────────────────

  Future<List<ScanDocument>> loadAll() async {
    final documentRows = await _db.query('documents', orderBy: 'updated_at DESC');
    if (documentRows.isEmpty) return const [];

    // One query for every page, grouped in Dart — avoids N+1 round trips when
    // the library grows.
    final pageRows = await _db.query('pages', orderBy: 'document_id, page_index');
    final pagesByDocument = <String, List<ScanPage>>{};
    for (final row in pageRows) {
      final page = ScanPage.fromRow(row);
      pagesByDocument.putIfAbsent(page.documentId, () => []).add(page);
    }

    return [
      for (final row in documentRows)
        ScanDocument.fromRow(row, pages: pagesByDocument[row['id']] ?? const []),
    ];
  }

  Future<ScanDocument?> findById(String id) async {
    final rows = await _db.query('documents', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    final pageRows = await _db.query(
      'pages',
      where: 'document_id = ?',
      whereArgs: [id],
      orderBy: 'page_index',
    );
    return ScanDocument.fromRow(rows.first, pages: pageRows.map(ScanPage.fromRow).toList());
  }

  /// ── writes ─────────────────────────────────────────────────────────────

  /// Renders every pending page and stores the result as a new document.
  ///
  /// Rendering happens before the transaction so a slow warp cannot hold a
  /// write lock; if a page fails to render the whole save is abandoned and the
  /// partial files are cleaned up, rather than leaving a half-saved document.
  Future<ScanDocument> createDocument({
    required String name,
    required String tag,
    required List<PendingPage> pages,
    void Function(int done, int total)? onProgress,
  }) async {
    if (pages.isEmpty) throw ArgumentError('A document needs at least one page');

    final documentId = _storage.newId();
    final directory = await _storage.documentDir(documentId);
    final now = DateTime.now();

    try {
      final rendered = await _renderPages(
        documentId: documentId,
        directory: directory,
        pages: pages,
        startIndex: 0,
        onProgress: onProgress,
      );

      final document = ScanDocument(
        id: documentId,
        name: name,
        tag: tag,
        createdAt: now,
        updatedAt: now,
        pages: rendered,
      );

      await _db.transaction((txn) async {
        await txn.insert('documents', document.toRow());
        for (final page in rendered) {
          await txn.insert('pages', page.toRow());
        }
      });
      return document;
    } catch (_) {
      await _storage.deleteDocumentDir(documentId);
      rethrow;
    }
  }

  /// Appends pages to an existing document and bumps its updated timestamp.
  Future<ScanDocument> appendPages(
    ScanDocument document,
    List<PendingPage> pages, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (pages.isEmpty) return document;
    final directory = await _storage.documentDir(document.id);
    final rendered = await _renderPages(
      documentId: document.id,
      directory: directory,
      pages: pages,
      startIndex: document.pageCount,
      onProgress: onProgress,
    );
    final updatedAt = DateTime.now();

    await _db.transaction((txn) async {
      for (final page in rendered) {
        await txn.insert('pages', page.toRow());
      }
      await txn.update(
        'documents',
        {'updated_at': updatedAt.millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [document.id],
      );
    });

    return document.copyWith(
      pages: [...document.pages, ...rendered],
      updatedAt: updatedAt,
    );
  }

  Future<List<ScanPage>> _renderPages({
    required String documentId,
    required String directory,
    required List<PendingPage> pages,
    required int startIndex,
    void Function(int done, int total)? onProgress,
  }) async {
    final result = <ScanPage>[];
    for (var i = 0; i < pages.length; i++) {
      final pending = pages[i];
      final pageId = _storage.newId();
      final filePath = _storage.pagePath(directory, pageId);
      final thumbPath = _storage.thumbnailPath(directory, pageId);

      await _worker.renderPage(
        sourcePath: pending.sourcePath,
        quad: pending.quad,
        settings: pending.settings,
        outputPath: filePath,
        thumbnailPath: thumbPath,
      );

      result.add(ScanPage(
        id: pageId,
        documentId: documentId,
        pageIndex: startIndex + i,
        filePath: filePath,
        thumbPath: thumbPath,
        createdAt: DateTime.now(),
      ));
      onProgress?.call(i + 1, pages.length);
    }
    return result;
  }

  Future<ScanDocument> rename(ScanDocument document, String name) async {
    final updatedAt = DateTime.now();
    await _db.update(
      'documents',
      {'name': name, 'updated_at': updatedAt.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [document.id],
    );
    return document.copyWith(name: name, updatedAt: updatedAt);
  }

  Future<ScanDocument> setTag(ScanDocument document, String tag) async {
    final updatedAt = DateTime.now();
    await _db.update(
      'documents',
      {'tag': tag, 'updated_at': updatedAt.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [document.id],
    );
    return document.copyWith(tag: tag, updatedAt: updatedAt);
  }

  /// True when another document already uses [name] — drives the inline
  /// validation on the rename dialog.
  Future<bool> isNameTaken(String name, {String? excludingId}) async {
    final rows = await _db.query(
      'documents',
      where: excludingId == null ? 'name = ? COLLATE NOCASE' : 'name = ? COLLATE NOCASE AND id != ?',
      whereArgs: excludingId == null ? [name] : [name, excludingId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<ScanDocument> deletePage(ScanDocument document, ScanPage page) async {
    final remaining = document.pages.where((p) => p.id != page.id).toList();
    final reindexed = [
      for (var i = 0; i < remaining.length; i++) remaining[i].copyWith(pageIndex: i),
    ];
    final updatedAt = DateTime.now();

    await _db.transaction((txn) async {
      await txn.delete('pages', where: 'id = ?', whereArgs: [page.id]);
      for (final p in reindexed) {
        await txn.update('pages', {'page_index': p.pageIndex}, where: 'id = ?', whereArgs: [p.id]);
      }
      await txn.update(
        'documents',
        {'updated_at': updatedAt.millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [document.id],
      );
    });

    await _storage.deleteFileIfExists(page.filePath);
    await _storage.deleteFileIfExists(page.thumbPath);
    return document.copyWith(pages: reindexed, updatedAt: updatedAt);
  }

  Future<ScanDocument> reorderPages(ScanDocument document, int oldIndex, int newIndex) async {
    final pages = List<ScanPage>.of(document.pages);
    final moved = pages.removeAt(oldIndex);
    pages.insert(newIndex, moved);
    final reindexed = [
      for (var i = 0; i < pages.length; i++) pages[i].copyWith(pageIndex: i),
    ];
    final updatedAt = DateTime.now();

    await _db.transaction((txn) async {
      for (final page in reindexed) {
        await txn.update(
          'pages',
          {'page_index': page.pageIndex},
          where: 'id = ?',
          whereArgs: [page.id],
        );
      }
      await txn.update(
        'documents',
        {'updated_at': updatedAt.millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [document.id],
      );
    });
    return document.copyWith(pages: reindexed, updatedAt: updatedAt);
  }

  /// Deletes a document, moving its files to a trash folder so the undo
  /// snackbar can bring them back. Call [DeletedDocument.purge] once undo is
  /// no longer offered.
  Future<DeletedDocument> delete(ScanDocument document) async {
    final source = Directory(p.join(_storage.scansDir, document.id));
    final trashDir = p.join(_storage.scansDir, '.trash', document.id);

    await _db.delete('documents', where: 'id = ?', whereArgs: [document.id]);

    if (source.existsSync()) {
      await Directory(p.dirname(trashDir)).create(recursive: true);
      final trash = Directory(trashDir);
      if (trash.existsSync()) await trash.delete(recursive: true);
      // A rename is atomic within the same volume, so undo never has to copy
      // megabytes of page images back.
      await source.rename(trashDir);
    }
    return DeletedDocument(document, trashDir, this);
  }

  Future<ScanDocument> _restore(DeletedDocument deleted) async {
    final trash = Directory(deleted._trashDir);
    if (trash.existsSync()) {
      final target = Directory(p.join(_storage.scansDir, deleted._document.id));
      if (target.existsSync()) await target.delete(recursive: true);
      await trash.rename(target.path);
    }
    await _db.transaction((txn) async {
      await txn.insert(
        'documents',
        deleted._document.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final page in deleted._document.pages) {
        await txn.insert('pages', page.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    return deleted._document;
  }

  /// Deletes many documents at once (multi-select on the home screen).
  Future<List<DeletedDocument>> deleteAll(Iterable<ScanDocument> documents) async {
    final deleted = <DeletedDocument>[];
    for (final document in documents) {
      deleted.add(await delete(document));
    }
    return deleted;
  }

  /// Every tag currently in use, for the filter chips.
  Future<List<String>> allTags() async {
    final rows = await _db.rawQuery('SELECT DISTINCT tag FROM documents ORDER BY tag COLLATE NOCASE');
    return [for (final row in rows) row['tag']! as String];
  }
}
