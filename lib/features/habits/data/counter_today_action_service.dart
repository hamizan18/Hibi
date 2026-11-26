import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/counter_day_status.dart';
import '../domain/habit_schedule.dart';
import 'counter_day_reader.dart';
import 'counter_occurrence_store.dart';
import 'counter_progress_writer.dart';
import 'counter_recovery_store.dart';
import 'counter_resolution.dart';
import 'habit_lifecycle.dart';

/// Coordinates transactional current-day counter actions and prior-date
/// recovery using one captured clock instant per operation.
class CounterTodayActionService {
  const CounterTodayActionService(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  /// Retrieves or creates today's occurrence and appends an audited progress
  /// event in one transaction, rolling back both if validation fails.
  Future<CounterDayEvaluation> recordTodayProgress({
    required String habitId,
    required String occurrenceId,
    required String eventId,
    required int quantity,
  }) => _db.transaction(() async {
    final now = _clock.now();
    final today = _localDate(now);
    final result = await CounterOccurrenceStore(_db)
        .getOrCreate(habitId: habitId, date: today, occurrenceId: occurrenceId);
    final occurrence = result.occurrence;
    if (result.applicability != HabitApplicability.applicable ||
        occurrence == null) {
      throw StateError('Habit is not applicable for counter progress today');
    }
    await CounterProgressWriter(
      _db,
      _CapturedClock(now),
    ).append(eventId: eventId, occurrenceId: occurrence.id, quantity: quantity);
    return CounterDayReader(_db).evaluate(habitId: habitId, date: today);
  });

  /// Retrieves or creates today's occurrence and records an explicit failed or
  /// excused resolution in one transaction, rolling back both on failure.
  Future<CounterDayEvaluation> resolveToday({
    required String habitId,
    required String occurrenceId,
    required String resolutionId,
    required CounterResolutionState state,
    String? reason,
  }) => _db.transaction(() async {
    final now = _clock.now();
    final today = _localDate(now);
    final result = await CounterOccurrenceStore(_db)
        .getOrCreate(habitId: habitId, date: today, occurrenceId: occurrenceId);
    final occurrence = result.occurrence;
    if (result.applicability != HabitApplicability.applicable ||
        occurrence == null) {
      throw StateError('Habit is not applicable for resolution today');
    }
    await CounterResolutionWriter(_db, _CapturedClock(now)).resolve(
      id: resolutionId,
      occurrenceId: occurrence.id,
      state: state,
      reason: reason,
    );
    return CounterDayReader(_db).evaluate(habitId: habitId, date: today);
  });

  /// Records a bounded recovery entry on the current local date against an
  /// explicitly failed prior-date occurrence and returns that day's evaluation.
  Future<CounterDayEvaluation> recoverPriorDeficit({
    required String recoveryId,
    required String occurrenceId,
    required int quantity,
    String? note,
  }) => _db.transaction(() async {
    await CounterRecoveryWriter(_db, _clock).record(
      id: recoveryId,
      occurrenceId: occurrenceId,
      quantity: quantity,
      note: note,
    );
    final row = await _db
        .customSelect(
          'SELECT habit_id, local_date FROM habit_occurrences WHERE id = ?',
          variables: [Variable<String>(occurrenceId)],
        )
        .getSingle();
    return CounterDayReader(_db).evaluate(
      habitId: row.read<String>('habit_id'),
      date: _parseDate(row.read<String>('local_date')),
    );
  });
}

LocalDate _localDate(DateTime instant) {
  final local = instant.toLocal();
  return LocalDate(local.year, local.month, local.day);
}

LocalDate _parseDate(String value) => LocalDate(
  int.parse(value.substring(0, 4)),
  int.parse(value.substring(5, 7)),
  int.parse(value.substring(8, 10)),
);

class _CapturedClock implements AppClock {
  const _CapturedClock(this.instant);
  final DateTime instant;

  @override
  DateTime now() => instant;
}
