import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Owns the SQLite connection and schema.
///
/// Only metadata lives here — page bitmaps are files on disk, addressed by the
/// paths in the `pages` table. That keeps the database small and makes the
/// scans inspectable and portable.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const _fileName = 'doc_scanner.db';
  static const _version = 1;

  static Future<AppDatabase> open() async {
    final path = p.join(await getDatabasesPath(), _fileName);
    final db = await openDatabase(
      path,
      version: _version,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: _createSchema,
    );
    return AppDatabase._(db);
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE documents (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        tag TEXT NOT NULL DEFAULT 'Untagged',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE pages (
        id TEXT PRIMARY KEY,
        document_id TEXT NOT NULL,
        page_index INTEGER NOT NULL,
        file_path TEXT NOT NULL,
        thumb_path TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (document_id) REFERENCES documents (id) ON DELETE CASCADE
      )
    ''');
    // The home list sorts by recency and the detail view walks pages in order;
    // both are hot paths worth an index.
    await db.execute('CREATE INDEX idx_documents_updated ON documents (updated_at DESC)');
    await db.execute('CREATE INDEX idx_pages_document ON pages (document_id, page_index)');
  }

  Future<void> close() => db.close();
}
