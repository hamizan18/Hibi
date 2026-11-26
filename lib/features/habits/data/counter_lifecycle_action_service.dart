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
