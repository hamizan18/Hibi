import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/habit_schedule.dart';
import 'counter_configuration_reader.dart';
import 'habit_lifecycle.dart';

/// Semantic lifecycle transitions for a counter habit (pause, resume, archive,
/// softDelete and restore), preserving all historical occurrences and configs.
class CounterLifecycleActionService {
  const CounterLifecycleActionService(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  /// Pause an unstarted habit from its initial start date without changing the
  /// original lifecycle event. The caller must confirm the identified event.
  Future<void> pauseFutureStart({
    required String eventId,
    required String habitId,
    required String expectedInitialEventId,
    String? reason,
  }) => _db.transaction(() async {
    if (eventId.trim().isEmpty) throw ArgumentError('Event ID is required');
    final now = _clock.now();
    final localNow = now.toLocal();
    final today = LocalDate(localNow.year, localNow.month, localNow.day);
    final history = await HabitLifecycleReader(_db).readHistory(habitId);
    if (history.length != 1 ||
        history.single.id != expectedInitialEventId ||
        history.single.previousState != null ||
        history.single.state != HabitLifecycleState.active ||
        history.single.effectiveDate.compareTo(today) < 0) {
      throw StateError(
        'Initial lifecycle changed or the habit already started',
      );
    }
    final firstVersion = await _db
        .customSelect(
          'SELECT MIN(effective_start) AS first_date FROM habit_versions WHERE habit_id = ?',
          variables: [Variable<String>(habitId)],
        )
        .getSingle();
    final start = history.single.effectiveDate;
    final startKey =
        '${start.year.toString().padLeft(4, '0')}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';
    if (firstVersion.readNullable<String>('first_date') != startKey) {
      throw StateError('Initial lifecycle and habit start do not match');
    }
    final occurrence = await _db.customSelect(
      '''
      SELECT 1 FROM habit_occurrences WHERE habit_id = ?
      UNION ALL SELECT 1 FROM habit_checklist_occurrences WHERE habit_id = ?
      UNION ALL SELECT 1 FROM habit_avoidance_occurrences WHERE habit_id = ?
      UNION ALL SELECT 1 FROM habit_typed_occurrences WHERE habit_id = ?
      LIMIT 1
      ''',
      variables: List.generate(4, (_) => Variable<String>(habitId)),
    ).getSingleOrNull();
    if (occurrence != null) {
      throw StateError('Existing occurrences require a correction workflow');
    }
    await _db.customStatement(
      'INSERT INTO habit_lifecycle_start_pauses (id, initial_event_id, created_at_utc_us, reason) VALUES (?, ?, ?, ?)',
      [
        eventId,
        expectedInitialEventId,
        now.toUtc().microsecondsSinceEpoch,
        reason,
      ],
    );
  });

  Future<CounterHabitConfiguration> pause({
    required String eventId,
    required String habitId,
    required LocalDate effectiveDate,
    String? reason,
  }) => _transition(
    eventId: eventId,
    habitId: habitId,
    effectiveDate: effectiveDate,
    targetState: HabitLifecycleState.paused,
    allowedFrom: const {
      HabitLifecycleState.scheduled,
      HabitLifecycleState.active,
    },
    actionLabel: 'pause',
    reason: reason,
  );

  Future<CounterHabitConfiguration> resume({
    required String eventId,
    required String habitId,
    required LocalDate effectiveDate,
    String? reason,
  }) => _transition(
    eventId: eventId,
    habitId: habitId,
    effectiveDate: effectiveDate,
    targetState: HabitLifecycleState.active,
    allowedFrom: const {HabitLifecycleState.paused},
    actionLabel: 'resume',
    reason: reason,
  );

  Future<CounterHabitConfiguration> archive({
    required String eventId,
    required String habitId,
    required LocalDate effectiveDate,
    String? reason,
  }) => _transition(
    eventId: eventId,
    habitId: habitId,
    effectiveDate: effectiveDate,
    targetState: HabitLifecycleState.archived,
    allowedFrom: const {
      HabitLifecycleState.scheduled,
      HabitLifecycleState.active,
      HabitLifecycleState.paused,
    },
    actionLabel: 'archive',
    reason: reason,
  );

  Future<CounterHabitConfiguration> softDelete({
    required String eventId,
    required String habitId,
    required LocalDate effectiveDate,
    String? reason,
  }) => _transition(
    eventId: eventId,
    habitId: habitId,
    effectiveDate: effectiveDate,
    targetState: HabitLifecycleState.deleted,
    allowedFrom: const {
      HabitLifecycleState.scheduled,
      HabitLifecycleState.active,
      HabitLifecycleState.paused,
      HabitLifecycleState.archived,
    },
    actionLabel: 'softDelete',
    reason: reason,
  );

  Future<CounterHabitConfiguration> restore({
    required String eventId,
    required String habitId,
    required LocalDate effectiveDate,
    String? reason,
  }) => _transition(
    eventId: eventId,
    habitId: habitId,
    effectiveDate: effectiveDate,
    targetState: HabitLifecycleState.active,
    allowedFrom: const {
      HabitLifecycleState.archived,
      HabitLifecycleState.deleted,
    },
    actionLabel: 'restore',
    reason: reason,
  );

  Future<CounterHabitConfiguration> _transition({
    required String eventId,
    required String habitId,
    required LocalDate effectiveDate,
    required HabitLifecycleState targetState,
    required Set<HabitLifecycleState> allowedFrom,
    required String actionLabel,
    String? reason,
  }) => _db.transaction(() async {
    final history = await HabitLifecycleReader(_db).readHistory(habitId);
    if (history.isEmpty) {
      throw StateError('Habit has no initial lifecycle state to $actionLabel');
    }
    final latestState = history.last.state;
    if (!allowedFrom.contains(latestState)) {
      throw StateError(
        'Cannot $actionLabel habit from lifecycle state ${latestState.name}',
      );
    }
    await HabitLifecycleStore(_db, _clock).append(
      id: eventId,
      habitId: habitId,
      effectiveDate: effectiveDate,
      state: targetState,
      reason: reason,
    );
    return CounterConfigurationReader(_db)
        .read(habitId: habitId, asOfDate: effectiveDate);
  });
}
