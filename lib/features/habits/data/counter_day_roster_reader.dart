import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/counter_day_status.dart';
import '../domain/habit_schedule.dart';
import 'counter_day_reader.dart';

/// Read-only roster item combining habit identity, effective version metadata
/// and full counter-day status evaluation on a requested local date.
class CounterDayRosterItem {
  const CounterDayRosterItem({
    required this.habitId,
    required this.versionId,
    required this.name,
    required this.revision,
    required this.evaluation,
  });

  final String habitId;
  final String? versionId;
  final String? name;
  final int? revision;
  final CounterDayEvaluation evaluation;
}

/// Evaluates all stored habits on a local date in one read transaction without
/// creating occurrences, mutating history or inferring failure.
class CounterDayRosterReader {
  const CounterDayRosterReader(this._db);

  final AppDatabase _db;

  Future<List<CounterDayRosterItem>> readForDate(LocalDate date) =>
      _db.transaction(() async {
        final key = _dateKey(date);
        final habits = await _db
            .customSelect(
              'SELECT id FROM habits ORDER BY created_at_utc_us ASC, id ASC',
            )
            .get();
        final dayReader = CounterDayReader(_db);
        final items = <CounterDayRosterItem>[];
        for (final habit in habits) {
          final habitId = habit.read<String>('id');
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
            date: date,
          );
          items.add(
            CounterDayRosterItem(
              habitId: habitId,
              versionId: version?.read<String>('id'),
              name: version?.read<String>('name'),
              revision: version?.read<int>('revision'),
              evaluation: evaluation,
            ),
          );
        }
        return List.unmodifiable(items);
      });
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
