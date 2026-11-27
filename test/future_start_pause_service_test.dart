import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_correction_preview.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_lifecycle_action_service.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class MutableClock implements AppClock {
  DateTime current = DateTime(2026, 11, 26, 12);
  @override
  DateTime now() => current;
}

void main() {
  test('pause at start preserves original event, invalidates preview and permits later resume', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock();
    final start = LocalDate(2026, 11, 29);
    await CounterHabitWriter(db, clock).create(
      habitId: 'h',
      versionId: 'v',
      auditId: 'a',
      lifecycleEventId: 'initial',
      name: 'Read',
      effectiveDate: DateTime(2026, 11, 29),
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: start),
    );
    final previewer = CounterCorrectionPreviewer(db, clock);
    final preview = await previewer.preview(
      const CounterTargetCorrectionProposal(
        habitId: 'h',
        versionId: 'v',
        proposedTargetCount: 10,
        proposedUnit: 'pages',
      ),
    );
    final actions = CounterLifecycleActionService(db, clock);
    await expectLater(
      actions.pauseFutureStart(
        eventId: 'wrong',
        habitId: 'h',
        expectedInitialEventId: 'stale',
      ),
      throwsStateError,
    );
    await actions.pauseFutureStart(
      eventId: 'pause',
      habitId: 'h',
      expectedInitialEventId: 'initial',
      reason: 'postpone',
    );
    expect(await previewer.isStale(preview), isTrue);
    final history = await HabitLifecycleReader(db).readHistory('h');
    expect(history.map((e) => e.id), ['initial', 'pause']);
    expect(history.map((e) => e.state), [
      HabitLifecycleState.active,
      HabitLifecycleState.paused,
    ]);
    expect(history.last.reason, 'postpone');
    expect(
      (await db
              .customSelect(
                "SELECT state FROM habit_lifecycle_events WHERE id = 'initial'",
              )
              .getSingle())
          .read<String>('state'),
      'active',
    );
    expect(
      (await HabitApplicabilityReader(
        db,
      ).describe('h', LocalDate(2026, 11, 28))).reason,
      HabitApplicabilityReason.beforeStart,
    );
    expect(
      (await HabitApplicabilityReader(db).describe('h', start)).reason,
      HabitApplicabilityReason.paused,
    );
    await expectLater(
      actions.pauseFutureStart(
        eventId: 'twice',
        habitId: 'h',
        expectedInitialEventId: 'initial',
      ),
      throwsStateError,
    );
    await actions.resume(
      eventId: 'resume',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 30),
    );
    expect(
      (await HabitApplicabilityReader(
        db,
      ).describe('h', LocalDate(2026, 11, 30))).reason,
      HabitApplicabilityReason.applicable,
    );
    final last = (await HabitLifecycleReader(db).readHistory('h')).last;
    expect(last.previousState, HabitLifecycleState.paused);
    expect(
      (await db
              .customSelect('SELECT COUNT(*) n FROM habit_occurrences')
              .getSingle())
          .read<int>('n'),
      0,
    );
  });

  test(
    'rejects on-start pause after logging and stale day after start',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = MutableClock();
      final start = LocalDate(2026, 11, 29);
      await CounterHabitWriter(db, clock).create(
        habitId: 'h',
        versionId: 'v',
        auditId: 'a',
        lifecycleEventId: 'initial',
        name: 'Read',
        effectiveDate: DateTime(2026, 11, 29),
        target: CounterTarget(count: 5, unit: 'pages'),
        schedule: DailySchedule(start: start),
      );
      clock.current = DateTime(2026, 11, 29, 12);
      await CounterTodayActionService(db, clock).recordTodayProgress(
        habitId: 'h',
        occurrenceId: 'o',
        eventId: 'progress',
        quantity: 2,
      );
      final actions = CounterLifecycleActionService(db, clock);
      await expectLater(
        actions.pauseFutureStart(
          eventId: 'pause',
          habitId: 'h',
          expectedInitialEventId: 'initial',
        ),
        throwsStateError,
      );
      clock.current = DateTime(2026, 11, 30, 12);
      await expectLater(
        actions.pauseFutureStart(
          eventId: 'pause',
          habitId: 'h',
          expectedInitialEventId: 'initial',
        ),
        throwsStateError,
      );
      expect(
        (await db
                .customSelect(
                  'SELECT COUNT(*) n FROM habit_lifecycle_start_pauses',
                )
                .getSingle())
            .read<int>('n'),
        0,
      );
      expect(
        (await HabitApplicabilityReader(db).describe('h', start)).reason,
        HabitApplicabilityReason.applicable,
      );
    },
  );
}
