import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/domain/counter_day_status.dart';
import 'package:hibi/features/habits/domain/counter_recovery.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class MutableClock implements AppClock {
  MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  test('recordTodayProgress creates occurrence on demand, reuses it on subsequent events and rolls back new occurrence on failure', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 26, 9));
    await CounterHabitWriter(db, clock).create(
      habitId: 'h',
      versionId: 'v',
      auditId: 'a',
      lifecycleEventId: 'l',
      name: 'Push Up',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 10, unit: 'repetitions'),
      schedule: WeekdaySchedule(start: LocalDate(2026, 11, 26), weekdays: {4}),
    );

    final service = CounterTodayActionService(db, clock);
    await expectLater(
      service.recordTodayProgress(
        habitId: 'h',
        occurrenceId: 'o_bad',
        eventId: 'e_bad',
        quantity: 0,
      ),
      throwsRangeError,
    );
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
              .getSingle())
          .read<int>('n'),
      0,
    );

    final first = await service.recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o_26',
      eventId: 'e1',
      quantity: 4,
    );
    expect(first.effectiveStatus, CounterDayEffectiveStatus.partial);
    expect(first.day.occurrenceId, 'o_26');
    expect(first.day.recorded!.progress.total, 4);

    final second = await service.recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'ignored_candidate_id',
      eventId: 'e2',
      quantity: 6,
    );
    expect(second.effectiveStatus, CounterDayEffectiveStatus.completed);
    expect(second.day.occurrenceId, 'o_26');
    expect(second.day.recorded!.progress.total, 10);

    // Friday Nov 27 is not a scheduled weekday
    clock.current = DateTime(2026, 11, 27, 9);
    await expectLater(
      service.recordTodayProgress(
        habitId: 'h',
        occurrenceId: 'o_27',
        eventId: 'e3',
        quantity: 5,
      ),
      throwsStateError,
    );
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
              .getSingle())
          .read<int>('n'),
      1,
    );
  });

  test('resolveToday resolves zero-progress day atomically, rolls back on failure and recoverPriorDeficit updates prior day without touching today', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 26, 10));
    await CounterHabitWriter(db, clock).create(
      habitId: 'h',
      versionId: 'v',
      auditId: 'a',
      lifecycleEventId: 'l',
      name: 'Quran Reading',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );

    final service = CounterTodayActionService(db, clock);
    final failedDay = await service.resolveToday(
      habitId: 'h',
      occurrenceId: 'o_26',
      resolutionId: 'r_26',
      state: CounterResolutionState.failed,
      reason: 'Missed reading',
    );
    expect(failedDay.effectiveStatus, CounterDayEffectiveStatus.failed);
    expect(failedDay.day.occurrenceId, 'o_26');
    expect(failedDay.day.recorded!.progress.total, 0);
    expect(failedDay.recovery!.remainingDeficit, 5);

    // Next day: recover 2 pages, then 3 pages
    clock.current = DateTime(2026, 11, 27, 9);
    final partialRecovery = await service.recoverPriorDeficit(
      recoveryId: 'rec1',
      occurrenceId: 'o_26',
      quantity: 2,
      note: 'Part 1',
    );
    expect(partialRecovery.effectiveStatus, CounterDayEffectiveStatus.failed);
    expect(
      partialRecovery.recovery!.status,
      CounterRecoveryStatus.partiallyRecovered,
    );
    expect(partialRecovery.recovery!.remainingDeficit, 3);

    final fullRecovery = await service.recoverPriorDeficit(
      recoveryId: 'rec2',
      occurrenceId: 'o_26',
      quantity: 3,
      note: 'Part 2',
    );
    expect(fullRecovery.effectiveStatus, CounterDayEffectiveStatus.recovered);
    expect(fullRecovery.recovery!.status, CounterRecoveryStatus.recovered);
    expect(fullRecovery.recovery!.remainingDeficit, 0);
    expect(fullRecovery.day.recorded!.progress.total, 0);

    // Today (Nov 27) still has no fabricated occurrence
    final todayEvaluation = await CounterDayReader(db)
        .evaluate(habitId: 'h', date: LocalDate(2026, 11, 27));
    expect(todayEvaluation.effectiveStatus, CounterDayEffectiveStatus.pending);
    expect(todayEvaluation.hasOccurrence, isFalse);

    // Inject resolution failure on Nov 27 and verify occurrence creation rolls back
    await db.customStatement(
      "CREATE TRIGGER fail_res_insert BEFORE INSERT ON habit_counter_resolutions WHEN NEW.id = 'bad_res' BEGIN SELECT RAISE(ABORT, 'injected'); END",
    );
    await expectLater(
      service.resolveToday(
        habitId: 'h',
        occurrenceId: 'o_27',
        resolutionId: 'bad_res',
        state: CounterResolutionState.excused,
      ),
      throwsA(isA<Exception>()),
    );
    expect(
      (await CounterDayReader(
        db,
      ).evaluate(habitId: 'h', date: LocalDate(2026, 11, 27))).hasOccurrence,
      isFalse,
    );
  });
}
