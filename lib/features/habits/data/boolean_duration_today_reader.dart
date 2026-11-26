import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/boolean_duration_habit.dart';
import '../domain/habit_schedule.dart';
import 'boolean_duration_habit_store.dart';

/// Reads duration progress without creating an occurrence for a pending day.
class BooleanDurationTodayReader {
  const BooleanDurationTodayReader(this.db, this.service);

  final AppDatabase db;
  final BooleanDurationHabitService service;

  Future<DurationDayProgress?> readDuration({
    required String habitId,
    required String? versionId,
    required LocalDate date,
  }) async {
    final progress = await service.readDurationDay(
      habitId: habitId,
      date: date,
    );
    if (progress != null || versionId == null) return progress;
    final dateKey =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final occurrence = await db
        .customSelect(
          'SELECT id FROM habit_typed_occurrences WHERE habit_id = ? AND local_date = ?',
          variables: [Variable<String>(habitId), Variable<String>(dateKey)],
        )
        .getSingleOrNull();
    if (occurrence != null) return null;
    final target = await db
        .customSelect(
          "SELECT target_seconds FROM habit_typed_targets WHERE habit_version_id = ? AND tracking_type = 'duration'",
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (target == null) return null;
    final seconds = target.readNullable<int>('target_seconds');
    if (seconds == null || seconds <= 0) return null;
    return DurationDayProgress.evaluate(
      targetSeconds: seconds,
      entrySeconds: const [],
    );
  }
}
