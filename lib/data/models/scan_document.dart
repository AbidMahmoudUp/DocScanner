import 'scan_page.dart';

/// A scanned document: a name, a flat tag, and one or more ordered pages.
class ScanDocument {
  const ScanDocument({
    required this.id,
    required this.name,
    required this.tag,
    required this.createdAt,
    required this.updatedAt,
    this.pages = const [],
  });

  final String id;
  final String name;
  final String tag;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ScanPage> pages;

  int get pageCount => pages.length;

  ScanPage? get coverPage => pages.isEmpty ? null : pages.first;

  ScanDocument copyWith({
    String? name,
    String? tag,
    DateTime? updatedAt,
    List<ScanPage>? pages,
  }) => ScanDocument(
    id: id,
    name: name ?? this.name,
    tag: tag ?? this.tag,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    pages: pages ?? this.pages,
  );

  Map<String, Object?> toRow() => {
    'id': id,
    'name': name,
    'tag': tag,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  factory ScanDocument.fromRow(Map<String, Object?> row, {List<ScanPage> pages = const []}) =>
      ScanDocument(
        id: row['id']! as String,
        name: row['name']! as String,
        tag: (row['tag'] as String?) ?? 'Untagged',
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at']! as int),
        pages: pages,
      );
}
