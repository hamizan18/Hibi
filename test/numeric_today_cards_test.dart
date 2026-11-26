import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/measurement_time_range_habit_store.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/domain/measurement_time_range_habit.dart';
import 'package:hibi/features/habits/presentation/numeric_today_cards.dart';

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

final date = LocalDate(2026, 11, 26);

Future<int> count(AppDatabase db, String table) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<void> showHabit(
  WidgetTester tester,
  AppDatabase db,
  String id,
  VoidCallback onChanged,
) async {
  final habits = await UnifiedHabitRegistryReader(db).readAll(asOfDate: date);
  final habit = habits.singleWhere((habit) => habit.habitId == id);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appClockProvider.overrideWithValue(FixedClock()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: NumericTodayCard(
            habit: habit,
            date: date,
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> enterAndSubmit(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.text('Log today'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'measurement reads without writes and logs exact decimals only once',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await MeasurementTimeRangeHabitService(
        db,
        FixedClock(),
      ).createMeasurement(
        habitId: 'm',
        versionId: 'mv',
        lifecycleEventId: 'ml',
        name: 'Water',
        effectiveDate: DateTime(2026, 11, 26),
        target: MeasurementTarget(
          scaledTarget: 250,
          decimalPlaces: 2,
          unit: 'L',
          rule: MeasurementComparisonRule.atLeast,
        ),
        schedule: DailySchedule(start: date),
      );
      var changes = 0;
      await showHabit(tester, db, 'm', () => changes++);
      expect(find.text('Target: At least 2.50 L'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
      expect(await count(db, 'habit_typed_occurrences'), 0);
      expect(await count(db, 'habit_typed_logs'), 0);
      for (final invalid in ['2.501', '1e3', '92233720368547759', '']) {
        await enterAndSubmit(tester, invalid);
        expect(await count(db, 'habit_typed_logs'), 0);
        expect(find.textContaining('Enter a valid number'), findsOneWidget);
      }
      await enterAndSubmit(tester, '2.75');
      expect(changes, 1);
      expect(find.text('Completed · 2.75 L'), findsOneWidget);
      expect(find.text('Log today'), findsNothing);
      expect(
        (await db
                .customSelect('SELECT scaled_value FROM habit_typed_logs')
                .getSingle())
            .read<int>('scaled_value'),
        275,
      );
      await showHabit(tester, db, 'm', () => changes++);
      expect(find.text('Completed · 2.75 L'), findsOneWidget);
      expect(await count(db, 'habit_typed_logs'), 1);
    },
  );

  testWidgets('time validates HH:MM and displays persisted failure', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await MeasurementTimeRangeHabitService(db, FixedClock()).createTimeOfDay(
      habitId: 't',
      versionId: 'tv',
      lifecycleEventId: 'tl',
      name: 'Wake',
      effectiveDate: DateTime(2026, 11, 26),
      target: TimeOfDayTarget(
        targetMinutesSinceMidnight: 330,
        rule: TimeComparisonRule.atOrBefore,
      ),
      schedule: DailySchedule(start: date),
    );
    var changes = 0;
    await showHabit(tester, db, 't', () => changes++);
    expect(find.text('Target: At or before 05:30'), findsOneWidget);
    expect(await count(db, 'habit_typed_occurrences'), 0);
    for (final invalid in ['24:00', '05:60', '5:30']) {
      await enterAndSubmit(tester, invalid);
      expect(find.text('Enter a valid time in HH:MM format.'), findsOneWidget);
      expect(await count(db, 'habit_typed_logs'), 0);
    }
    await enterAndSubmit(tester, '05:45');
    expect(find.text('Failed · 05:45'), findsOneWidget);
    expect(changes, 1);
  });

  testWidgets('range logs negative fixed-scale values and shows partial', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await MeasurementTimeRangeHabitService(db, FixedClock()).createRange(
      habitId: 'r',
      versionId: 'rv',
      lifecycleEventId: 'rl',
      name: 'Temperature',
      effectiveDate: DateTime(2026, 11, 26),
      target: RangeTarget(
        minScaled: -10,
        maxScaled: 85,
        decimalPlaces: 1,
        unit: 'C',
      ),
      schedule: DailySchedule(start: date),
    );
    var changes = 0;
    await showHabit(tester, db, 'r', () => changes++);
    expect(find.text('Target: -1.0–8.5 C'), findsOneWidget);
    expect(await count(db, 'habit_typed_occurrences'), 0);
    await enterAndSubmit(tester, '-1.1');
    expect(find.text('Partial · -1.1 C'), findsOneWidget);
    expect(changes, 1);
    expect(
      (await db
              .customSelect('SELECT scaled_value FROM habit_typed_logs')
              .getSingle())
          .read<int>('scaled_value'),
      -11,
    );
  });
}
