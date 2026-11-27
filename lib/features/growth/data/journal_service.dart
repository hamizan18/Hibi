import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../../habits/domain/habit_schedule.dart';
import '../domain/journal_models.dart';

/// Transactional local store for optional Journal & Mood entries.
/// Supports multiple entries per date and hides private entries by default.
class JournalService {
  const JournalService(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<JournalEntry> createEntry({
    required String id,
    required LocalDate localDate,
    String? title,
    String? reflectionText,
    String? gratitudeText,
    JournalMood? mood,
    Iterable<String> tags = const [],
    bool isPrivate = false,
  }) => _db.transaction(() async {
    final nowUtc = _clock.now().toUtc();
    final entry = JournalEntry(
      id: id,
      localDate: localDate,
      title: title,
      reflectionText: reflectionText,
      gratitudeText: gratitudeText,
      mood: mood,
      tags: tags,
      isPrivate: isPrivate,
      createdAtUtc: nowUtc,
      updatedAtUtc: nowUtc,
    );
    final nowUs = nowUtc.microsecondsSinceEpoch;
    await _db.customStatement(
      '''
      INSERT INTO journal_entries (
        id, local_date, title, reflection_text, gratitude_text, mood,
        is_private, is_deleted, created_at_utc_us, updated_at_utc_us
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
      ''',
      [
        entry.id,
        _dateKey(entry.localDate),
        entry.title,
        entry.reflectionText,
        entry.gratitudeText,
        entry.mood?.storageKey,
        entry.isPrivate ? 1 : 0,
        nowUs,
        nowUs,
      ],
    );
    for (final tag in entry.tags) {
      await _db.customStatement(
        'INSERT INTO journal_entry_tags (entry_id, tag) VALUES (?, ?)',
        [entry.id, tag],
      );
    }
    return entry;
  });

  Future<JournalEntry> updateEntry({
    required String id,
    required LocalDate localDate,
    String? title,
    String? reflectionText,
    String? gratitudeText,
    JournalMood? mood,
    Iterable<String> tags = const [],
    bool isPrivate = false,
  }) => _db.transaction(() async {
    final existing = await _readEntryRow(id);
    if (existing == null || existing.read<int>('is_deleted') == 1) {
      throw StateError('Journal entry not found: $id');
    }
    final createdAtUtc = DateTime.fromMicrosecondsSinceEpoch(
      existing.read<int>('created_at_utc_us'),
      isUtc: true,
    );
    final nowUtc = _clock.now().toUtc();
    final updated = JournalEntry(
      id: id,
      localDate: localDate,
      title: title,
      reflectionText: reflectionText,
      gratitudeText: gratitudeText,
      mood: mood,
      tags: tags,
      isPrivate: isPrivate,
      createdAtUtc: createdAtUtc,
      updatedAtUtc: nowUtc,
    );
    await _db.customStatement(
      '''
      UPDATE journal_entries
      SET local_date = ?,
          title = ?,
          reflection_text = ?,
          gratitude_text = ?,
          mood = ?,
          is_private = ?,
          updated_at_utc_us = ?
      WHERE id = ?
      ''',
      [
        _dateKey(updated.localDate),
        updated.title,
        updated.reflectionText,
        updated.gratitudeText,
        updated.mood?.storageKey,
        updated.isPrivate ? 1 : 0,
        nowUtc.microsecondsSinceEpoch,
        updated.id,
      ],
    );
    await _db.customStatement(
      'DELETE FROM journal_entry_tags WHERE entry_id = ?',
      [updated.id],
    );
    for (final tag in updated.tags) {
      await _db.customStatement(
        'INSERT INTO journal_entry_tags (entry_id, tag) VALUES (?, ?)',
        [updated.id, tag],
      );
    }
    return updated;
  });

  Future<void> softDeleteEntry(String id) => _db.transaction(() async {
    final existing = await _readEntryRow(id);
    if (existing == null || existing.read<int>('is_deleted') == 1) {
      throw StateError('Journal entry not found: $id');
    }
    final nowUs = _clock.now().toUtc().microsecondsSinceEpoch;
    await _db.customStatement(
      '''
      UPDATE journal_entries
      SET is_deleted = 1, updated_at_utc_us = ?
      WHERE id = ?
      ''',
      [nowUs, id.trim()],
    );
  });

  Future<List<JournalEntry>> readEntries({
    LocalDate? startInclusive,
    LocalDate? endInclusive,
    String? tagFilter,
    bool includePrivate = false,
  }) => _db.transaction(() async {
    final clauses = <String>['e.is_deleted = 0'];
    final vars = <Variable<Object>>[];
    if (!includePrivate) {
      clauses.add('e.is_private = 0');
    }
    if (startInclusive != null) {
      clauses.add('e.local_date >= ?');
      vars.add(Variable<String>(_dateKey(startInclusive)));
    }
    if (endInclusive != null) {
      clauses.add('e.local_date <= ?');
      vars.add(Variable<String>(_dateKey(endInclusive)));
    }
    final normalizedTag = tagFilter?.trim().toLowerCase();
    if (normalizedTag != null && normalizedTag.isNotEmpty) {
      clauses.add(
        'EXISTS (SELECT 1 FROM journal_entry_tags t WHERE t.entry_id = e.id AND t.tag = ?)',
      );
      vars.add(Variable<String>(normalizedTag));
    }

    final rows = await _db.customSelect('''
          SELECT e.id, e.local_date, e.title, e.reflection_text, e.gratitude_text,
                 e.mood, e.is_private, e.is_deleted, e.created_at_utc_us, e.updated_at_utc_us
          FROM journal_entries e
          WHERE ${clauses.join(' AND ')}
          ORDER BY e.local_date DESC, e.created_at_utc_us DESC, e.id DESC
          ''', variables: vars).get();
    if (rows.isEmpty) return const [];

    final entryIds = [for (final row in rows) row.read<String>('id')];
    final placeholders = List.filled(entryIds.length, '?').join(', ');
    final tagRows = await _db
        .customSelect(
          '''
          SELECT entry_id, tag
          FROM journal_entry_tags
          WHERE entry_id IN ($placeholders)
          ORDER BY tag ASC
          ''',
          variables: [for (final id in entryIds) Variable<String>(id)],
        )
        .get();
    final tagsByEntry = <String, List<String>>{};
    for (final row in tagRows) {
      tagsByEntry
          .putIfAbsent(row.read<String>('entry_id'), () => <String>[])
          .add(row.read<String>('tag'));
    }

    return [
      for (final row in rows)
        _mapRow(row, tagsByEntry[row.read<String>('id')] ?? const []),
    ];
  });

  Future<QueryRow?> _readEntryRow(String id) => _db
      .customSelect(
        '''
        SELECT id, local_date, title, reflection_text, gratitude_text, mood,
               is_private, is_deleted, created_at_utc_us, updated_at_utc_us
        FROM journal_entries
        WHERE id = ?
        ''',
        variables: [Variable<String>(id.trim())],
      )
      .getSingleOrNull();

  JournalEntry _mapRow(QueryRow row, List<String> tags) {
    final moodRaw = row.readNullable<String>('mood');
    return JournalEntry(
      id: row.read<String>('id'),
      localDate: _parseDateKey(row.read<String>('local_date')),
      title: row.readNullable<String>('title'),
      reflectionText: row.readNullable<String>('reflection_text'),
      gratitudeText: row.readNullable<String>('gratitude_text'),
      mood: moodRaw == null ? null : JournalMood.fromStorageKey(moodRaw),
      tags: tags,
      isPrivate: row.read<int>('is_private') == 1,
      isDeleted: row.read<int>('is_deleted') == 1,
      createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        row.read<int>('created_at_utc_us'),
        isUtc: true,
      ),
      updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        row.read<int>('updated_at_utc_us'),
        isUtc: true,
      ),
    );
  }
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

LocalDate _parseDateKey(String raw) {
  final parts = raw.split('-');
  return LocalDate(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}
