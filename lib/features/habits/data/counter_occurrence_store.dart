import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/habit_schedule.dart';
import 'habit_lifecycle.dart';

/// A persisted counter occurrence and its original target snapshot.
class CounterOccurrence {
  const CounterOccurrence({
    required this.id,
    required this.habitId,
    required this.versionId,
    required this.date,
    required this.targetCount,
    required this.unit,
  });

  final String id;
  final String habitId;
  final String versionId;
  final LocalDate date;
  final int targetCount;
  final String unit;
}

/// Applicability is independent of the presence of a historical occurrence.
typedef CounterOccurrenceResult = ({
  HabitApplicability applicability,
  CounterOccurrence? occurrence,
});

/// Internal retrieval/creation only; it does not record progress or a status.
class CounterOccurrenceStore {
  const CounterOccurrenceStore(this._db);

  final AppDatabase _db;

  Future<CounterOccurrenceResult> getOrCreate({
    required String habitId,
    required LocalDate date,
    required String occurrenceId,
  }) => _db.transaction(() async {
    final dateKey = _dateKey(date);
    final applicability = await HabitApplicabilityReader(_db)
        .evaluate(habitId, date);
    final existing = await _db
        .customSelect(
          '''
      SELECT id, habit_version_id, target_count, unit FROM habit_occurrences
      WHERE habit_id = ? AND local_date = ?
      ''',
          variables: [Variable<String>(habitId), Variable<String>(dateKey)],
        )
        .getSingleOrNull();
    if (existing != null) {
      return (
        applicability: applicability,
        occurrence: CounterOccurrence(
          id: existing.read<String>('id'),
          habitId: habitId,
          versionId: existing.read<String>('habit_version_id'),
          date: date,
          targetCount: existing.read<int>('target_count'),
          unit: existing.read<String>('unit'),
        ),
      );
    }
    if (applicability != HabitApplicability.applicable) {
      return (applicability: applicability, occurrence: null);
    }
    final version = await _db
        .customSelect(
          '''
      SELECT v.id, t.target_count, t.unit FROM habit_versions v
      LEFT JOIN habit_counter_targets t ON t.habit_version_id = v.id
      WHERE v.habit_id = ? AND v.effective_start <= ?
        AND (v.effective_end IS NULL OR ? < v.effective_end)
      ''',
          variables: [
            Variable<String>(habitId),
            Variable<String>(dateKey),
            Variable<String>(dateKey),
          ],
        )
        .getSingleOrNull();
    final count = version?.readNullable<int>('target_count');
    final unit = version?.readNullable<String>('unit');
    if (version == null || count == null || unit == null) {
      return (applicability: HabitApplicability.unknown, occurrence: null);
    }
    final versionId = version.read<String>('id');
    await _db.customStatement(
      'INSERT INTO habit_occurrences (id, habit_id, habit_version_id, local_date, target_count, unit) VALUES (?, ?, ?, ?, ?, ?)',
      [occurrenceId, habitId, versionId, dateKey, count, unit],
    );
    return (
      applicability: HabitApplicability.applicable,
      occurrence: CounterOccurrence(
        id: occurrenceId,
        habitId: habitId,
        versionId: versionId,
        date: date,
        targetCount: count,
        unit: unit,
      ),
    );
  });
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
