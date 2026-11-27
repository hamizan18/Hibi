import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/habit_schedule.dart';
import 'habit_schedule_store.dart';

enum HabitLifecycleState { scheduled, active, paused, archived, deleted }

enum HabitApplicability { applicable, notApplicable, unknown }

/// Specific reason explaining why a habit is applicable, notApplicable or unknown.
enum HabitApplicabilityReason {
  applicable,
  beforeStart,
  scheduled,
  paused,
  archived,
  deleted,
  unscheduled,
  missingVersions,
  missingLifecycle,
  missingActiveVersion,
  missingSchedule,
}

typedef HabitApplicabilityDetail = ({
  HabitApplicability applicability,
  HabitApplicabilityReason reason,
  HabitLifecycleState? lifecycleState,
  String? versionId,
});

/// Immutable dated lifecycle transition record.
class HabitLifecycleEvent {
  const HabitLifecycleEvent({
    required this.id,
    required this.habitId,
    required this.effectiveDate,
    required this.previousState,
    required this.state,
    required this.reason,
    required this.createdAtUtc,
  });

  final String id;
  final String habitId;
  final LocalDate effectiveDate;
  final HabitLifecycleState? previousState;
  final HabitLifecycleState state;
  final String? reason;
  final DateTime createdAtUtc;
}

/// Read-only inspection of effective-dated lifecycle transitions.
class HabitLifecycleReader {
  const HabitLifecycleReader(this._db);

  final AppDatabase _db;

  Future<HabitLifecycleEvent?> findEffectiveOn(
    String habitId,
    LocalDate date,
  ) => _db.transaction(() async {
    await _requireHabit(_db, habitId);
    final key = _key(date);
    final row = await _db
        .customSelect(
          '''
      SELECT * FROM (
        SELECT id, habit_id, effective_date, previous_state, state, reason, created_at_utc_us, 0 AS ordering
        FROM habit_lifecycle_events WHERE habit_id = ? AND effective_date <= ?
        UNION ALL
        SELECT p.id, e.habit_id, e.effective_date, 'active', 'paused', p.reason, p.created_at_utc_us, 1
        FROM habit_lifecycle_start_pauses p
        JOIN habit_lifecycle_events e ON e.id = p.initial_event_id
        WHERE e.habit_id = ? AND e.effective_date <= ?
      ) ORDER BY effective_date DESC, ordering DESC LIMIT 1
      ''',
          variables: [
            Variable<String>(habitId),
            Variable<String>(key),
            Variable<String>(habitId),
            Variable<String>(key),
          ],
        )
        .getSingleOrNull();
    return row == null ? null : _mapEvent(row);
  });

  Future<List<HabitLifecycleEvent>> readHistory(String habitId) =>
      _db.transaction(() async {
        await _requireHabit(_db, habitId);
        final rows = await _db
            .customSelect(
              '''
          SELECT id, habit_id, effective_date, previous_state, state, reason, created_at_utc_us, 0 AS ordering
          FROM habit_lifecycle_events WHERE habit_id = ?
          UNION ALL
          SELECT p.id, e.habit_id, e.effective_date, 'active', 'paused', p.reason, p.created_at_utc_us, 1
          FROM habit_lifecycle_start_pauses p
          JOIN habit_lifecycle_events e ON e.id = p.initial_event_id
          WHERE e.habit_id = ?
          ORDER BY effective_date ASC, ordering ASC, created_at_utc_us ASC, id ASC
        ''',
              variables: [Variable<String>(habitId), Variable<String>(habitId)],
            )
            .get();
        return List.unmodifiable([for (final row in rows) _mapEvent(row)]);
      });
}

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
    final history = await HabitLifecycleReader(_db).readHistory(habitId);
    final latest = history.isEmpty ? null : history.last;
    final previous = latest?.state;
    if (latest != null && date.compareTo(_key(latest.effectiveDate)) <= 0) {
      throw StateError(
        'Lifecycle events must be appended on distinct later dates',
      );
    }
    if (!_allowed(previous, state)) {
      throw StateError('Invalid lifecycle transition');
    }
    final conflictingOccurrence = await _db
        .customSelect(
          '''
      SELECT 1 FROM habit_checklist_occurrences
      WHERE habit_id = ? AND local_date >= ?
      UNION ALL
      SELECT 1 FROM habit_avoidance_occurrences
      WHERE habit_id = ? AND local_date >= ?
      UNION ALL
      SELECT 1 FROM habit_typed_occurrences
      WHERE habit_id = ? AND local_date >= ?
      LIMIT 1
      ''',
          variables: [
            Variable<String>(habitId),
            Variable<String>(date),
            Variable<String>(habitId),
            Variable<String>(date),
            Variable<String>(habitId),
            Variable<String>(date),
          ],
        )
        .getSingleOrNull();
    if (conflictingOccurrence != null) {
      throw StateError('Lifecycle correction workflow required');
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

  Future<HabitApplicability> evaluate(String habitId, LocalDate date) async =>
      (await describe(habitId, date)).applicability;

  Future<HabitApplicabilityDetail> describe(String habitId, LocalDate date) =>
      _db.transaction(() async {
        await _requireHabit(_db, habitId);
        final key = _key(date);
        final earliest = await _db
            .customSelect(
              'SELECT MIN(effective_start) AS first_date FROM habit_versions WHERE habit_id = ?',
              variables: [Variable<String>(habitId)],
            )
            .getSingle();
        final firstDate = earliest.readNullable<String>('first_date');
        if (firstDate == null) {
          return (
            applicability: HabitApplicability.unknown,
            reason: HabitApplicabilityReason.missingVersions,
            lifecycleState: null,
            versionId: null,
          );
        }
        if (key.compareTo(firstDate) < 0) {
          return (
            applicability: HabitApplicability.notApplicable,
            reason: HabitApplicabilityReason.beforeStart,
            lifecycleState: null,
            versionId: null,
          );
        }
        final event = await HabitLifecycleReader(_db)
            .findEffectiveOn(habitId, date);
        if (event == null) {
          return (
            applicability: HabitApplicability.unknown,
            reason: HabitApplicabilityReason.missingLifecycle,
            lifecycleState: null,
            versionId: null,
          );
        }
        final state = event.state;
        if (state != HabitLifecycleState.active) {
          return (
            applicability: HabitApplicability.notApplicable,
            reason: switch (state) {
              HabitLifecycleState.scheduled =>
                HabitApplicabilityReason.scheduled,
              HabitLifecycleState.paused => HabitApplicabilityReason.paused,
              HabitLifecycleState.archived => HabitApplicabilityReason.archived,
              HabitLifecycleState.deleted => HabitApplicabilityReason.deleted,
              HabitLifecycleState.active => HabitApplicabilityReason.applicable,
            },
            lifecycleState: state,
            versionId: null,
          );
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
        if (version == null) {
          return (
            applicability: HabitApplicability.unknown,
            reason: HabitApplicabilityReason.missingActiveVersion,
            lifecycleState: state,
            versionId: null,
          );
        }
        final versionId = version.read<String>('id');
        final schedule = await HabitScheduleStore(_db)
            .findForVersion(versionId);
        if (schedule == null) {
          return (
            applicability: HabitApplicability.unknown,
            reason: HabitApplicabilityReason.missingSchedule,
            lifecycleState: state,
            versionId: versionId,
          );
        }
        final applies = schedule.appliesOn(date);
        return (
          applicability: applies
              ? HabitApplicability.applicable
              : HabitApplicability.notApplicable,
          reason: applies
              ? HabitApplicabilityReason.applicable
              : HabitApplicabilityReason.unscheduled,
          lifecycleState: state,
          versionId: versionId,
        );
      });
}

Future<void> _requireHabit(AppDatabase db, String habitId) async {
  final habit = await db
      .customSelect(
        'SELECT id FROM habits WHERE id = ?',
        variables: [Variable<String>(habitId)],
      )
      .getSingleOrNull();
  if (habit == null) throw StateError('Habit does not exist');
}

HabitLifecycleEvent _mapEvent(QueryRow row) {
  final prev = row.readNullable<String>('previous_state');
  return HabitLifecycleEvent(
    id: row.read<String>('id'),
    habitId: row.read<String>('habit_id'),
    effectiveDate: _parseDate(row.read<String>('effective_date')),
    previousState: prev == null
        ? null
        : HabitLifecycleState.values.byName(prev),
    state: HabitLifecycleState.values.byName(row.read<String>('state')),
    reason: row.readNullable<String>('reason'),
    createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
      row.read<int>('created_at_utc_us'),
      isUtc: true,
    ),
  );
}

String _key(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

LocalDate _parseDate(String value) => LocalDate(
  int.parse(value.substring(0, 4)),
  int.parse(value.substring(5, 7)),
  int.parse(value.substring(8, 10)),
);
