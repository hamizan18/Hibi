import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/habit_schedule.dart';
import 'habit_lifecycle.dart';

/// Records new same-day counter progress; historical corrections are unsupported.
class CounterProgressWriter {
  const CounterProgressWriter(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<void> append({
    required String eventId,
    required String occurrenceId,
    required int quantity,
  }) => _db.transaction(() async {
    if (quantity <= 0) {
      throw RangeError.value(quantity, 'quantity', 'Must be positive');
    }
    final now = _clock.now();
    final local = now.toLocal();
    final today = LocalDate(local.year, local.month, local.day);
    final dateKey =
        '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final occurrence = await _db
        .customSelect(
          'SELECT habit_id, local_date FROM habit_occurrences WHERE id = ?',
          variables: [Variable<String>(occurrenceId)],
        )
        .getSingleOrNull();
    if (occurrence == null) throw StateError('Occurrence does not exist');
    if (occurrence.read<String>('local_date') != dateKey) {
      throw StateError('Only the current local date supports new progress');
    }
    final applicability = await HabitApplicabilityReader(_db)
        .evaluate(occurrence.read<String>('habit_id'), today);
    if (applicability != HabitApplicability.applicable) {
      throw StateError('Occurrence applicability must be known and active');
    }
    final resolution = await _db
        .customSelect(
          'SELECT id FROM habit_counter_resolutions WHERE occurrence_id = ?',
          variables: [Variable<String>(occurrenceId)],
        )
        .getSingleOrNull();
    if (resolution != null) {
      throw StateError('Resolved occurrences require a correction workflow');
    }
    final total =
        (await _db
                .customSelect(
                  'SELECT COALESCE(SUM(quantity), 0) AS total FROM habit_counter_events WHERE occurrence_id = ?',
                  variables: [Variable<String>(occurrenceId)],
                )
                .getSingle())
            .read<int>('total');
    if (quantity > 9223372036854775807 - total) {
      throw RangeError('Counter progress exceeds signed 64-bit range');
    }
    final timestamp = now.toUtc().microsecondsSinceEpoch;
    await _db.customStatement(
      'INSERT INTO habit_counter_events (id, occurrence_id, quantity, occurred_at_utc_us) VALUES (?, ?, ?, ?)',
      [eventId, occurrenceId, quantity, timestamp],
    );
    await _db.customStatement(
      'INSERT INTO habit_counter_event_audit (event_id, occurrence_id, quantity, occurred_at_utc_us) VALUES (?, ?, ?, ?)',
      [eventId, occurrenceId, quantity, timestamp],
    );
  });
}
