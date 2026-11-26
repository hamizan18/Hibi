import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/counter_progress.dart';
import '../domain/habit_schedule.dart';
import 'counter_resolution.dart';
import 'counter_progress_reader.dart';
import 'habit_lifecycle.dart';

/// Scheduling applicability and recorded progress are independent facts.
typedef CounterDay = ({
  HabitApplicability applicability,
  String? occurrenceId,
  ({CounterProgress progress, String unit})? recorded,
  CounterResolution? resolution,
});

/// Reads an existing day consistently without creating or changing records.
class CounterDayReader {
  const CounterDayReader(this._db);

  final AppDatabase _db;

  Future<CounterDay> read({
    required String habitId,
    required LocalDate date,
  }) => _db.transaction(() async {
    final applicability = await HabitApplicabilityReader(_db)
        .evaluate(habitId, date);
    final key =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final occurrence = await _db
        .customSelect(
          'SELECT id FROM habit_occurrences WHERE habit_id = ? AND local_date = ?',
          variables: [Variable<String>(habitId), Variable<String>(key)],
        )
        .getSingleOrNull();
    final id = occurrence?.read<String>('id');
    final recorded = id == null
        ? null
        : await CounterProgressReader(_db).find(id);
    final resolution = id == null
        ? null
        : await CounterResolutionReader(_db).find(id);
    return (
      applicability: applicability,
      occurrenceId: id,
      recorded: recorded,
      resolution: resolution,
    );
  });
}
