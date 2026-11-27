import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/counter_day_status.dart';
import '../domain/habit_schedule.dart';
import 'counter_day_reader.dart';
import 'habit_lifecycle.dart';

/// Per-date evaluation of a single counter habit across a date range.
class CounterDateHistoryItem {
  const CounterDateHistoryItem({
    required this.date,
    required this.versionId,
    required this.name,
    required this.revision,
    required this.evaluation,
  });

  final LocalDate date;
  final String? versionId;
  final String? name;
  final int? revision;
  final CounterDayEvaluation evaluation;
}

/// A prior explicitly failed counter occurrence with a remaining recovery deficit.
class CounterRecoverableDeficit {
  const CounterRecoverableDeficit({
    required this.occurrenceId,
    required this.date,
    required this.versionId,
    required this.name,
    required this.target,
    required this.unit,
    required this.recordedTotal,
    required this.recoveredTotal,
    required this.remainingDeficit,
  });

  final String occurrenceId;
  final LocalDate date;
  final String versionId;
  final String name;
  final int target;
  final String unit;
  final int recordedTotal;
  final int recoveredTotal;
  final int remainingDeficit;
}

/// Read-only date-range history and recoverable-deficit queries for one habit.
/// Never creates occurrences or infers failures from missing records.
class CounterHistoryReader {
  const CounterHistoryReader(this._db);

  final AppDatabase _db;

  Future<List<CounterDateHistoryItem>> readRange({
    required String habitId,
    required LocalDate startInclusive,
    required LocalDate endInclusive,
  }) {
    if (endInclusive.compareTo(startInclusive) < 0) {
      throw ArgumentError('endInclusive must not precede startInclusive');
    }
    return _db.transaction(() async {
      await _requireHabit(habitId);
      final dayReader = CounterDayReader(_db);
      final items = <CounterDateHistoryItem>[];
      var current = startInclusive;
      while (current.compareTo(endInclusive) <= 0) {
        final key = _dateKey(current);
        final version = await _db
            .customSelect(
              '''
          SELECT id, name, revision
          FROM habit_versions
          WHERE habit_id = ? AND effective_start <= ?
            AND (effective_end IS NULL OR ? < effective_end)
          ''',
              variables: [
                Variable<String>(habitId),
                Variable<String>(key),
                Variable<String>(key),
              ],
            )
            .getSingleOrNull();
        final evaluation = await dayReader.evaluate(
          habitId: habitId,
          date: current,
        );
        items.add(
          CounterDateHistoryItem(
            date: current,
            versionId: version?.read<String>('id'),
            name: version?.read<String>('name'),
            revision: version?.read<int>('revision'),
            evaluation: evaluation,
          ),
        );
        current = _nextDate(current);
      }
      return List.unmodifiable(items);
    });
  }

  Future<List<CounterRecoverableDeficit>> findRecoverableDeficits({
    required String habitId,
    required LocalDate asOfDate,
  }) => _db.transaction(() async {
    await _requireHabit(habitId);
    final asOfKey = _dateKey(asOfDate);
    final latestLifecycle = await HabitLifecycleReader(_db)
        .findEffectiveOn(habitId, asOfDate);
    if (latestLifecycle?.state != HabitLifecycleState.active) {
      return const <CounterRecoverableDeficit>[];
    }

    final rows = await _db
        .customSelect(
          '''
      SELECT o.id, o.local_date, o.habit_version_id, v.name
      FROM habit_occurrences o
      JOIN habit_versions v ON v.id = o.habit_version_id
      WHERE o.habit_id = ? AND o.local_date < ?
      ORDER BY o.local_date ASC, o.id ASC
      ''',
          variables: [Variable<String>(habitId), Variable<String>(asOfKey)],
        )
        .get();

    final dayReader = CounterDayReader(_db);
    final deficits = <CounterRecoverableDeficit>[];
    for (final row in rows) {
      final date = _parseDate(row.read<String>('local_date'));
      final evaluation = await dayReader.evaluate(habitId: habitId, date: date);
      final recovery = evaluation.recovery;
      final recorded = evaluation.day.recorded;
      if (evaluation.effectiveStatus == CounterDayEffectiveStatus.failed &&
          recovery != null &&
          recorded != null &&
          recovery.remainingDeficit > 0) {
        deficits.add(
          CounterRecoverableDeficit(
            occurrenceId: row.read<String>('id'),
            date: date,
            versionId: row.read<String>('habit_version_id'),
            name: row.read<String>('name'),
            target: recovery.target,
            unit: recorded.unit,
            recordedTotal: recovery.recordedTotal,
            recoveredTotal: recovery.recoveredTotal,
            remainingDeficit: recovery.remainingDeficit,
          ),
        );
      }
    }
    return List.unmodifiable(deficits);
  });

  Future<void> _requireHabit(String habitId) async {
    final habit = await _db
        .customSelect(
          'SELECT id FROM habits WHERE id = ?',
          variables: [Variable<String>(habitId)],
        )
        .getSingleOrNull();
    if (habit == null) throw StateError('Habit does not exist');
  }
}

LocalDate _nextDate(LocalDate date) {
  final next = DateTime.utc(date.year, date.month, date.day + 1);
  return LocalDate(next.year, next.month, next.day);
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

LocalDate _parseDate(String value) => LocalDate(
  int.parse(value.substring(0, 4)),
  int.parse(value.substring(5, 7)),
  int.parse(value.substring(8, 10)),
);
