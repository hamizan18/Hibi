import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/counter_recovery.dart';
import '../domain/habit_schedule.dart';
import 'counter_day_reader.dart';
import 'counter_resolution.dart';
import 'habit_lifecycle.dart';

/// Immutable counter recovery creation record and audit snapshot.
class CounterRecoveryRecord {
  const CounterRecoveryRecord({
    required this.id,
    required this.occurrenceId,
    required this.recoveryDate,
    required this.quantity,
    required this.originalTarget,
    required this.originalProgress,
    required this.remainingDeficit,
    required this.note,
    required this.occurredAtUtc,
  });

  final String id;
  final String occurrenceId;
  final LocalDate recoveryDate;
  final int quantity;
  final int originalTarget;
  final int originalProgress;
  final int remainingDeficit;
  final String? note;
  final DateTime occurredAtUtc;
}

class CounterRecoveryReader {
  const CounterRecoveryReader(this._db);

  final AppDatabase _db;

  Future<List<CounterRecoveryRecord>> findForOccurrence(
    String occurrenceId,
  ) async {
    final rows = await _db
        .customSelect(
          '''
      SELECT id, occurrence_id, recovery_local_date, quantity,
             original_target_count, original_progress_total, remaining_deficit,
             note, occurred_at_utc_us
      FROM habit_counter_recoveries
      WHERE occurrence_id = ?
      ORDER BY occurred_at_utc_us ASC, rowid ASC
      ''',
          variables: [Variable<String>(occurrenceId)],
        )
        .get();
    return List.unmodifiable([
      for (final row in rows)
        CounterRecoveryRecord(
          id: row.read<String>('id'),
          occurrenceId: row.read<String>('occurrence_id'),
          recoveryDate: _parseDate(row.read<String>('recovery_local_date')),
          quantity: row.read<int>('quantity'),
          originalTarget: row.read<int>('original_target_count'),
          originalProgress: row.read<int>('original_progress_total'),
          remainingDeficit: row.read<int>('remaining_deficit'),
          note: row.readNullable<String>('note'),
          occurredAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            row.read<int>('occurred_at_utc_us'),
            isUtc: true,
          ),
        ),
    ]);
  }
}

/// Appends bounded recovery entries on the current local date for an explicitly
/// failed prior counter occurrence without altering same-day or today's events.
class CounterRecoveryWriter {
  const CounterRecoveryWriter(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<void> record({
    required String id,
    required String occurrenceId,
    required int quantity,
    String? note,
  }) => _db.transaction(() async {
    if (quantity <= 0) {
      throw RangeError.value(quantity, 'quantity', 'Must be positive');
    }
    final now = _clock.now();
    final local = now.toLocal();
    final today = LocalDate(local.year, local.month, local.day);
    final todayKey = _dateKey(today);

    final occurrence = await _db
        .customSelect(
          'SELECT habit_id, local_date FROM habit_occurrences WHERE id = ?',
          variables: [Variable<String>(occurrenceId)],
        )
        .getSingleOrNull();
    if (occurrence == null) throw StateError('Occurrence does not exist');

    final habitId = occurrence.read<String>('habit_id');
    final occurrenceDateKey = occurrence.read<String>('local_date');
    if (occurrenceDateKey.compareTo(todayKey) >= 0) {
      throw StateError('Only prior-date occurrences can be recovered');
    }

    final occurrenceDate = _parseDate(occurrenceDateKey);
    if (await HabitApplicabilityReader(_db).evaluate(habitId, occurrenceDate) !=
        HabitApplicability.applicable) {
      throw StateError(
        'Original occurrence applicability must be known and active',
      );
    }

    final latestLifecycle = await HabitLifecycleReader(_db)
        .findEffectiveOn(habitId, today);
    if (latestLifecycle?.state != HabitLifecycleState.active) {
      throw StateError('Habit must be active on the recovery date');
    }

    final evaluation = await CounterDayReader(_db)
        .evaluate(habitId: habitId, date: occurrenceDate);
    final recorded = evaluation.day.recorded;
    final resolution = evaluation.day.resolution;
    if (recorded == null ||
        resolution == null ||
        resolution.state != CounterResolutionState.failed) {
      throw StateError(
        'Only explicitly failed occurrences are eligible for recovery',
      );
    }
    if (evaluation.recovery == null) {
      throw StateError(
        'Existing recovery history requires a correction workflow',
      );
    }
    final existing = evaluation.day.recoveries;

    final summary = CounterRecovery.fromEvents(
      progress: recorded.progress,
      resolution: resolution.state,
      quantities: [...existing.map((entry) => entry.quantity), quantity],
    );

    await _db.customStatement(
      '''
      INSERT INTO habit_counter_recoveries
        (id, occurrence_id, recovery_local_date, quantity, original_target_count,
         original_progress_total, remaining_deficit, note, occurred_at_utc_us)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        id,
        occurrenceId,
        todayKey,
        quantity,
        recorded.progress.target,
        recorded.progress.total,
        summary.remainingDeficit,
        note,
        now.toUtc().microsecondsSinceEpoch,
      ],
    );
  });
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

LocalDate _parseDate(String value) => LocalDate(
  int.parse(value.substring(0, 4)),
  int.parse(value.substring(5, 7)),
  int.parse(value.substring(8, 10)),
);
