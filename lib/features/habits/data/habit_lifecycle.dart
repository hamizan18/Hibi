import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/habit_schedule.dart';
import 'habit_schedule_store.dart';

enum HabitLifecycleState { scheduled, active, paused, archived, deleted }

enum HabitApplicability { applicable, notApplicable, unknown }

/// Internal append-only lifecycle history. Not a user-facing correction API.
class HabitLifecycleStore {
  const HabitLifecycleStore(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<void> append({
    required String id,
    required String habitId,
    required LocalDate effectiveDate,
    required HabitLifecycleState state,
    String? reason,
  }) => _db.transaction(() async {
    final now = _clock.now();
    final localNow = now.toLocal();
    final date = _key(effectiveDate);
    if (date.compareTo(
          _key(LocalDate(localNow.year, localNow.month, localNow.day)),
        ) <
        0) {
      throw StateError(
        'Backdated lifecycle changes require a correction workflow',
      );
    }
    final latest = await _db
        .customSelect(
          '''
      SELECT state, effective_date FROM habit_lifecycle_events
      WHERE habit_id = ? ORDER BY effective_date DESC LIMIT 1
    ''',
          variables: [Variable<String>(habitId)],
        )
        .getSingleOrNull();
    final previous = latest == null
        ? null
        : HabitLifecycleState.values.byName(latest.read<String>('state'));
    if (latest != null &&
        date.compareTo(latest.read<String>('effective_date')) <= 0) {
      throw StateError(
        'Lifecycle events must be appended on distinct later dates',
      );
    }
    if (!_allowed(previous, state)) {
      throw StateError('Invalid lifecycle transition');
    }
    await _db.customStatement(
      '''
      INSERT INTO habit_lifecycle_events
        (id, habit_id, effective_date, previous_state, state, reason, created_at_utc_us)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    ''',
      [
        id,
        habitId,
        date,
        previous?.name,
        state.name,
        reason,
        now.toUtc().microsecondsSinceEpoch,
      ],
    );
  });
}

bool _allowed(
  HabitLifecycleState? previous,
  HabitLifecycleState next,
) => switch (previous) {
  null =>
    next == HabitLifecycleState.scheduled || next == HabitLifecycleState.active,
  HabitLifecycleState.scheduled =>
    next == HabitLifecycleState.active ||
        next == HabitLifecycleState.paused ||
        next == HabitLifecycleState.archived ||
        next == HabitLifecycleState.deleted,
  HabitLifecycleState.active =>
    next == HabitLifecycleState.paused ||
        next == HabitLifecycleState.archived ||
        next == HabitLifecycleState.deleted,
  HabitLifecycleState.paused =>
    next == HabitLifecycleState.active ||
        next == HabitLifecycleState.archived ||
        next == HabitLifecycleState.deleted,
  HabitLifecycleState.archived =>
    next == HabitLifecycleState.active || next == HabitLifecycleState.deleted,
  HabitLifecycleState.deleted => next == HabitLifecycleState.active,
};

/// Read-only combination of known lifecycle, version and recurrence data.
class HabitApplicabilityReader {
  const HabitApplicabilityReader(this._db);

  final AppDatabase _db;

  Future<HabitApplicability> evaluate(String habitId, LocalDate date) =>
      _db.transaction(() async {
        final habit = await _db
            .customSelect(
              'SELECT id FROM habits WHERE id = ?',
              variables: [Variable<String>(habitId)],
            )
            .getSingleOrNull();
        if (habit == null) throw StateError('Habit does not exist');
        final key = _key(date);
        final earliest = await _db
            .customSelect(
              'SELECT MIN(effective_start) AS first_date FROM habit_versions WHERE habit_id = ?',
              variables: [Variable<String>(habitId)],
            )
            .getSingle();
        final firstDate = earliest.readNullable<String>('first_date');
        if (firstDate == null) return HabitApplicability.unknown;
        if (key.compareTo(firstDate) < 0) {
          return HabitApplicability.notApplicable;
        }
        final event = await _db
            .customSelect(
              '''
      SELECT state FROM habit_lifecycle_events
      WHERE habit_id = ? AND effective_date <= ? ORDER BY effective_date DESC LIMIT 1
    ''',
              variables: [Variable<String>(habitId), Variable<String>(key)],
            )
            .getSingleOrNull();
        if (event == null) return HabitApplicability.unknown;
        final state = HabitLifecycleState.values.byName(
          event.read<String>('state'),
        );
        if (state != HabitLifecycleState.active) {
          return HabitApplicability.notApplicable;
        }
        final version = await _db
            .customSelect(
              '''
      SELECT id FROM habit_versions WHERE habit_id = ? AND effective_start <= ?
      AND (effective_end IS NULL OR ? < effective_end)
    ''',
              variables: [
                Variable<String>(habitId),
                Variable<String>(key),
                Variable<String>(key),
              ],
            )
            .getSingleOrNull();
        if (version == null) return HabitApplicability.unknown;
        final schedule = await HabitScheduleStore(_db)
            .findForVersion(version.read<String>('id'));
        if (schedule == null) return HabitApplicability.unknown;
        return schedule.appliesOn(date)
            ? HabitApplicability.applicable
            : HabitApplicability.notApplicable;
      });
}

String _key(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
