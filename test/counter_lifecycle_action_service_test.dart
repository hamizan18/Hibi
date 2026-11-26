import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_lifecycle_action_service.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/domain/counter_day_status.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class MutableClock implements AppClock {
  MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  test('pause, resume, archive, softDelete and restore enforce semantic preconditions and preserve historical progress', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 26, 9));
    await CounterHabitWriter(db, clock).create(
      habitId: 'h',
      versionId: 'v1',
      auditId: 'a1',
      lifecycleEventId: 'l1',
      name: 'Push Up',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 10, unit: 'repetitions'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    await CounterTodayActionService(db, clock).recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o_26',
      eventId: 'e_26',
      quantity: 10,
    );

    final lifecycleActions = CounterLifecycleActionService(db, clock);

    // Cannot pause on Nov 26 because o_26 already exists on Nov 26
    await expectLater(
      lifecycleActions.pause(
        eventId: 'bad_same_day',
        habitId: 'h',
        effectiveDate: LocalDate(2026, 11, 26),
      ),
      throwsStateError,
    );

    // Cannot resume or restore while active
    await expectLater(
      lifecycleActions.resume(
        eventId: 'bad_resume',
        habitId: 'h',
        effectiveDate: LocalDate(2026, 11, 27),
      ),
      throwsStateError,
    );
    await expectLater(
      lifecycleActions.restore(
        eventId: 'bad_restore',
        habitId: 'h',
        effectiveDate: LocalDate(2026, 11, 27),
      ),
      throwsStateError,
    );

    clock.current = DateTime(2026, 11, 27, 9);
    final paused = await lifecycleActions.pause(
      eventId: 'l2_pause',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 27),
      reason: 'Rest day',
    );
    expect(paused.applicability.reason, HabitApplicabilityReason.paused);
    expect(paused.effectiveLifecycle!.state, HabitLifecycleState.paused);

    // Cannot restore from paused (must use resume)
    clock.current = DateTime(2026, 11, 28, 9);
    await expectLater(
      lifecycleActions.restore(
        eventId: 'bad_restore_from_paused',
        habitId: 'h',
        effectiveDate: LocalDate(2026, 11, 28),
      ),
      throwsStateError,
    );

    final resumed = await lifecycleActions.resume(
      eventId: 'l3_resume',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 28),
      reason: 'Back to routine',
    );
    expect(resumed.applicability.reason, HabitApplicabilityReason.applicable);
    expect(resumed.effectiveLifecycle!.state, HabitLifecycleState.active);

    clock.current = DateTime(2026, 11, 29, 9);
    final archived = await lifecycleActions.archive(
      eventId: 'l4_archive',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 29),
      reason: 'Season break',
    );
    expect(archived.applicability.reason, HabitApplicabilityReason.archived);

    // Cannot resume from archived (must use restore)
    clock.current = DateTime(2026, 11, 30, 9);
    await expectLater(
      lifecycleActions.resume(
        eventId: 'bad_resume_from_archived',
        habitId: 'h',
        effectiveDate: LocalDate(2026, 11, 30),
      ),
      throwsStateError,
    );

    final deleted = await lifecycleActions.softDelete(
      eventId: 'l5_delete',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 30),
      reason: 'Temporary cleanup',
    );
    expect(deleted.applicability.reason, HabitApplicabilityReason.deleted);

    clock.current = DateTime(2026, 12, 1, 9);
    final restored = await lifecycleActions.restore(
      eventId: 'l6_restore',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 12, 1),
      reason: 'Reinstated',
    );
    expect(restored.applicability.reason, HabitApplicabilityReason.applicable);
    expect(restored.lifecycleHistory.length, 6);

    // Historical Nov 26 completed progress remains intact
    final nov26 = await CounterDayReader(db)
        .evaluate(habitId: 'h', date: LocalDate(2026, 11, 26));
    expect(nov26.effectiveStatus, CounterDayEffectiveStatus.completed);
    expect(nov26.day.recorded!.progress.total, 10);
  });
}
