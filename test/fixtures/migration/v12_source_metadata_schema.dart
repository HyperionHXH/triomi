import 'v1_schema.dart';

/// Media and chapter tables kept their v2 layout through v12. Use frozen
/// historical DDL when a test reconstructs a released database from newer data.
List<String> restoreV12SourceMetadataStatements() => [
  for (final (table, columns) in const [
    (
      'media_items',
      'source_id, remote_id, type, title, cover_url, author, description, '
          'tags_json, rating, status, detail_json, cached_at, url',
    ),
    (
      'chapters',
      'source_id, remote_id, item_source_id, item_remote_id, title, number, '
          'sort_index, volume_title, release_date, locked, content_json, url',
    ),
  ]) ...[
    'ALTER TABLE "$table" RENAME TO "generated_current_$table"',
    v1CreateTableStatements.singleWhere(
      (sql) => sql.startsWith('CREATE TABLE "$table"'),
    ),
    'ALTER TABLE "$table" ADD COLUMN url TEXT NULL',
    'INSERT INTO "$table" ($columns) '
        'SELECT $columns FROM "generated_current_$table"',
    'DROP TABLE "generated_current_$table"',
  ],
];
