import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/boolean_duration_habit_store.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/boolean_duration_habit.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/boolean_duration_today_cards.dart';

class MutableClock implements AppClock {
  DateTime value = DateTime(2026, 11, 26, 12);
  @override
  DateTime now() => value;
}

final date = LocalDate(2026, 11, 26);

Future<int> count(AppDatabase db, String table) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<void> showCard(
  WidgetTester tester,
  AppDatabase db,
  MutableClock clock,
  Widget card,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appClockProvider.overrideWithValue(clock),
      ],
      child: MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: card)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final entry in <(String, BooleanLogState)>[
    ('Mark done', BooleanLogState.completed),
    ('Mark not done', BooleanLogState.failed),
    ('Excuse today', BooleanLogState.excused),
  ]) {
    testWidgets('Boolean ${entry.$2.name} is explicit and cannot be repeated', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = MutableClock();
      final service = BooleanDurationHabitService(db, clock);
      await service.createBoolean(
        habitId: 'b',
        versionId: 'bv',
        lifecycleEventId: 'bl',
        name: 'Boolean',
        effectiveDate: clock.now(),
        schedule: DailySchedule(start: date),
      );
      final habit = (await UnifiedHabitRegistryReader(
        db,
      ).readAll(asOfDate: date)).single;
      var changes = 0;
      await showCard(
        tester,
        db,
        clock,
        BooleanTodayCard(habit: habit, date: date, onChanged: () => changes++),
      );
      expect(find.text('Not recorded yet'), findsOneWidget);
      expect(await count(db, 'habit_typed_occurrences'), 0);
      expect(await count(db, 'habit_typed_logs'), 0);
      await tester.tap(find.text(entry.$1));
      await tester.pumpAndSettle();
      expect(await service.readBooleanDay(habitId: 'b', date: date), entry.$2);
      expect(changes, 1);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, entry.$1),
            )
            .onPressed,
        isNull,
      );
      expect(await count(db, 'habit_typed_logs'), 1);
    });
  }

  testWidgets(
    'duration validates manual input and records manual and timer entries',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = MutableClock();
      final service = BooleanDurationHabitService(db, clock);
      await service.createDuration(
        habitId: 'd',
        versionId: 'dv',
        lifecycleEventId: 'dl',
        name: 'Duration',
        effectiveDate: clock.now(),
        target: DurationTarget(targetSeconds: 60),
        schedule: DailySchedule(start: date),
      );
      final habit = (await UnifiedHabitRegistryReader(
        db,
      ).readAll(asOfDate: date)).single;
      var changes = 0;
      await showCard(
        tester,
        db,
        clock,
        DurationTodayCard(habit: habit, date: date, onChanged: () => changes++),
      );
      expect(find.text('pending: 0 / 60 seconds'), findsOneWidget);
      expect(await count(db, 'habit_typed_occurrences'), 0);
      await tester.enterText(find.byType(TextField), '0');
      await tester.tap(find.text('Add time'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a positive whole number of seconds.'),
        findsOneWidget,
      );
      expect(await count(db, 'habit_duration_events'), 0);
      await tester.enterText(find.byType(TextField), '20');
      await tester.tap(find.text('Add time'));
      await tester.pumpAndSettle();
      expect(find.text('partial: 20 / 60 seconds'), findsOneWidget);
      await tester.tap(find.text('Start timer'));
      await tester.pumpAndSettle();
      clock.value = clock.value.add(const Duration(seconds: 40));
      await tester.tap(find.text('Stop and save timer'));
      await tester.pumpAndSettle();
      expect(find.text('completed: 60 / 60 seconds'), findsOneWidget);
      expect(changes, 2);
      expect(await count(db, 'habit_duration_events'), 2);
    },
  );
}
