import 'dart:io';

/// One enhanced page belonging to a [ScanDocument].
///
/// Image bytes live on disk; only paths and metadata are stored in SQLite.
class ScanPage {
  const ScanPage({
    required this.id,
    required this.documentId,
    required this.pageIndex,
    required this.filePath,
    required this.thumbPath,
    required this.createdAt,
  });

  final String id;
  final String documentId;
  final int pageIndex;
  final String filePath;
  final String thumbPath;
  final DateTime createdAt;

  File get file => File(filePath);
  File get thumbFile => File(thumbPath);

  ScanPage copyWith({int? pageIndex, String? filePath, String? thumbPath}) => ScanPage(
    id: id,
    documentId: documentId,
    pageIndex: pageIndex ?? this.pageIndex,
    filePath: filePath ?? this.filePath,
    thumbPath: thumbPath ?? this.thumbPath,
    createdAt: createdAt,
  );

  Map<String, Object?> toRow() => {
    'id': id,
    'document_id': documentId,
    'page_index': pageIndex,
    'file_path': filePath,
    'thumb_path': thumbPath,
    'created_at': createdAt.millisecondsSinceEpoch,
  };

  factory ScanPage.fromRow(Map<String, Object?> row) => ScanPage(
    id: row['id']! as String,
    documentId: row['document_id']! as String,
    pageIndex: row['page_index']! as int,
    filePath: row['file_path']! as String,
    thumbPath: row['thumb_path']! as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int),
  );
}
