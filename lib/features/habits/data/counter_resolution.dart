import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/counter_progress.dart';
import '../domain/habit_schedule.dart';
import 'counter_progress_reader.dart';
import 'habit_lifecycle.dart';

enum CounterResolutionState { failed, excused }

/// Immutable creation record, including the original target and progress.
class CounterResolution {
  const CounterResolution({
    required this.id,
    required this.state,
    required this.reason,
    required this.target,
    required this.progress,
    required this.occurredAtUtc,
  });
  final String id;
  final CounterResolutionState state;
  final String? reason;
  final int target;
  final int progress;
  final DateTime occurredAtUtc;
}

class CounterResolutionReader {
  const CounterResolutionReader(this._db);
  final AppDatabase _db;

  Future<CounterResolution?> find(String occurrenceId) async {
    final row = await _db
        .customSelect(
          'SELECT id, state, reason, target_count, progress_total, occurred_at_utc_us FROM habit_counter_resolutions WHERE occurrence_id = ?',
          variables: [Variable<String>(occurrenceId)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    return CounterResolution(
      id: row.read<String>('id'),
      state: CounterResolutionState.values.byName(row.read<String>('state')),
      reason: row.readNullable<String>('reason'),
      target: row.read<int>('target_count'),
      progress: row.read<int>('progress_total'),
      occurredAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        row.read<int>('occurred_at_utc_us'),
        isUtc: true,
      ),
    );
  }
}

/// Creates one explicit resolution; changing it requires a future correction flow.
class CounterResolutionWriter {
  const CounterResolutionWriter(this._db, this._clock);
  final AppDatabase _db;
  final AppClock _clock;

  Future<void> resolve({
    required String id,
    required String occurrenceId,
    required CounterResolutionState state,
    String? reason,
  }) => _db.transaction(() async {
    final now = _clock.now();
    final local = now.toLocal();
    final today = LocalDate(local.year, local.month, local.day);
    final key =
        '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final occurrence = await _db
        .customSelect(
          'SELECT habit_id, local_date FROM habit_occurrences WHERE id = ?',
          variables: [Variable<String>(occurrenceId)],
        )
        .getSingleOrNull();
    if (occurrence == null) throw StateError('Occurrence does not exist');
    if (occurrence.read<String>('local_date') != key) {
      throw StateError('Only the current local date can be resolved');
    }
    if (await HabitApplicabilityReader(_db)
            .evaluate(occurrence.read<String>('habit_id'), today) !=
        HabitApplicability.applicable) {
      throw StateError('Occurrence applicability must be known and active');
    }
    final recorded = await CounterProgressReader(_db).find(occurrenceId);
    if (recorded == null) throw StateError('Occurrence does not exist');
    if (recorded.progress.status == CounterProgressStatus.completed) {
      throw StateError('Completed occurrences cannot be failed or excused');
    }
    await _db.customStatement(
      'INSERT INTO habit_counter_resolutions (id, occurrence_id, state, reason, target_count, progress_total, occurred_at_utc_us) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        occurrenceId,
        state.name,
        reason,
        recorded.progress.target,
        recorded.progress.total,
        now.toUtc().microsecondsSinceEpoch,
      ],
    );
  });
}
