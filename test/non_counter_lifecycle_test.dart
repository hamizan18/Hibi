import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/avoidance_habit_store.dart';
import 'package:hibi/features/habits/data/boolean_duration_habit_store.dart';
import 'package:hibi/features/habits/data/checklist_habit_store.dart';
import 'package:hibi/features/habits/data/counter_lifecycle_action_service.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/domain/avoidance_habit.dart';
import 'package:hibi/features/habits/domain/boolean_duration_habit.dart';
import 'package:hibi/features/habits/domain/checklist_habit.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/today_habit_roster.dart';

class TestClock implements AppClock {
  DateTime value = DateTime(2026, 11, 26, 12);
  @override
  DateTime now() => value;
}

void main() {
  final start = LocalDate(2026, 11, 26);
  testWidgets(
    'checklist lifecycle is accessible in Today and preserves its history',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = TestClock();
      final service = ChecklistHabitService(db, clock);
      await service.create(
        habitId: 'h',
        versionId: 'v',
        lifecycleEventId: 'l',
        name: 'List',
        effectiveDate: clock.now(),
        schedule: DailySchedule(start: start),
        metadata: HabitMetadata(category: 'General'),
        items: [
          ChecklistItemDefinition(id: 'i', label: 'Item', displayOrder: 0),
        ],
      );
      await service.logItemToday(
        habitId: 'h',
        occurrenceId: 'o',
        logId: 'log',
        itemId: 'i',
        state: ChecklistItemLogState.completed,
      );
      clock.value = DateTime(2026, 11, 27, 12);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: TodayHabitRoster(date: LocalDate(2026, 11, 27)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Pause'));
      await tester.tap(find.text('Pause'));
      await tester.pumpAndSettle();
      expect(find.text('Not scheduled or not active today.'), findsOneWidget);
      expect(
        (await HabitLifecycleReader(db).readHistory('h')).last.state,
        HabitLifecycleState.paused,
      );
      final old = await service.readDay(habitId: 'h', date: start);
      expect(
        old.progress!.items.single.state,
        ChecklistItemEffectiveState.completed,
      );
    },
  );

  test('all non-counter occurrence families reject lifecycle changes on recorded dates', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = TestClock();
    final checklist = ChecklistHabitService(db, clock);
    final avoidance = AvoidanceHabitService(db, clock);
    final typed = BooleanDurationHabitService(db, clock);
    await checklist.create(
      habitId: 'c',
      versionId: 'cv',
      lifecycleEventId: 'cl',
      name: 'List',
      effectiveDate: clock.now(),
      schedule: DailySchedule(start: start),
      items: [ChecklistItemDefinition(id: 'i', label: 'Item', displayOrder: 0)],
    );
    await avoidance.create(
      habitId: 'a',
      versionId: 'av',
      lifecycleEventId: 'al',
      name: 'Avoid',
      effectiveDate: clock.now(),
      schedule: DailySchedule(start: start),
      target: AvoidanceTarget(maxIncidents: 1),
    );
    await typed.createBoolean(
      habitId: 'b',
      versionId: 'bv',
      lifecycleEventId: 'bl',
      name: 'Boolean',
      effectiveDate: clock.now(),
      schedule: DailySchedule(start: start),
    );
    clock.value = DateTime(2026, 11, 27, 12);
    await checklist.logItemToday(
      habitId: 'c',
      occurrenceId: 'co',
      logId: 'ci',
      itemId: 'i',
      state: ChecklistItemLogState.completed,
    );
    await avoidance.recordIncidentToday(
      habitId: 'a',
      occurrenceId: 'ao',
      incidentId: 'ai',
    );
    await typed.logBooleanToday(
      habitId: 'b',
      occurrenceId: 'bo',
      logId: 'bi',
      state: BooleanLogState.completed,
    );
    final actions = CounterLifecycleActionService(db, clock);
    for (final id in ['c', 'a', 'b']) {
      await expectLater(
        actions.pause(
          eventId: '${id}p',
          habitId: id,
          effectiveDate: LocalDate(2026, 11, 27),
        ),
        throwsStateError,
      );
      expect((await HabitLifecycleReader(db).readHistory(id)).length, 1);
      await expectLater(
        actions.resume(
          eventId: '${id}r',
          habitId: id,
          effectiveDate: LocalDate(2026, 11, 28),
        ),
        throwsStateError,
      );
      await actions.pause(
        eventId: '${id}p2',
        habitId: id,
        effectiveDate: LocalDate(2026, 11, 28),
      );
      expect(
        (await HabitLifecycleReader(db).readHistory(id)).last.state,
        HabitLifecycleState.paused,
      );
    }
    expect(
      await typed.readBooleanDay(habitId: 'b', date: LocalDate(2026, 11, 27)),
      BooleanLogState.completed,
    );
    expect(
      (await avoidance.readDay(
        habitId: 'a',
        date: LocalDate(2026, 11, 27),
      )).progress!.incidentCount,
      1,
    );
  });
}
