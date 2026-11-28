import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/avoidance_habit_store.dart';
import 'package:hibi/features/habits/data/checklist_habit_store.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/avoidance_habit.dart';
import 'package:hibi/features/habits/domain/checklist_habit.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/checklist_avoidance_today_cards.dart';

class FakeClock implements AppClock {
  DateTime current = DateTime(2026, 11, 27, 9);
  @override
  DateTime now() => current;
}

Future<int> count(AppDatabase db, String table) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<void> pumpCard(
  WidgetTester tester,
  AppDatabase db,
  FakeClock clock,
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

Future<void> tapText(WidgetTester tester, String text) async {
  final target = find.text(text);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'checklist shows definitions without writes and logs each item once',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = FakeClock();
      final date = LocalDate(2026, 11, 27);
      await ChecklistHabitService(db, clock).create(
        habitId: 'h',
        versionId: 'v',
        lifecycleEventId: 'l',
        name: 'List',
        effectiveDate: DateTime(2026, 11, 27),
        schedule: DailySchedule(start: date),
        items: [
          ChecklistItemDefinition(id: 'a', label: 'Alpha', displayOrder: 0),
          ChecklistItemDefinition(id: 'b', label: 'Beta', displayOrder: 1),
          ChecklistItemDefinition(id: 'c', label: 'Gamma', displayOrder: 2),
        ],
      );
      final habit = (await UnifiedHabitRegistryReader(
        db,
      ).readAll(asOfDate: date)).single;
      var changes = 0;
      await pumpCard(
        tester,
        db,
        clock,
        ChecklistTodayCard(
          habit: habit,
          date: date,
          onChanged: () => changes++,
        ),
      );
      expect(find.text('Alpha: Pending'), findsOneWidget);
      expect(find.text('Beta: Pending'), findsOneWidget);
      expect(await count(db, 'habit_checklist_occurrences'), 0);
      expect(await count(db, 'habit_checklist_item_logs'), 0);
      await tapText(tester, 'Completed Alpha');
      await tapText(tester, 'Failed Beta');
      await tapText(tester, 'Excused Gamma');
      expect(find.text('Alpha: Completed'), findsOneWidget);
      expect(find.text('Beta: Failed'), findsOneWidget);
      expect(find.text('Gamma: Excused'), findsOneWidget);
      expect(find.text('Completed Alpha'), findsNothing);
      expect(await count(db, 'habit_checklist_item_logs'), 3);
      expect(changes, 3);
    },
  );

  testWidgets(
    'avoidance remains pending until confirmation and permits repeated incidents',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = FakeClock();
      final date = LocalDate(2026, 11, 27);
      await AvoidanceHabitService(db, clock).create(
        habitId: 'h',
        versionId: 'v',
        lifecycleEventId: 'l',
        name: 'Avoid',
        effectiveDate: DateTime(2026, 11, 27),
        schedule: DailySchedule(start: date),
        target: AvoidanceTarget(maxIncidents: 2),
      );
      final habit = (await UnifiedHabitRegistryReader(
        db,
      ).readAll(asOfDate: date)).single;
      var changes = 0;
      await pumpCard(
        tester,
        db,
        clock,
        AvoidanceTodayCard(
          habit: habit,
          date: date,
          onChanged: () => changes++,
        ),
      );
      expect(find.text('Status: Not recorded yet'), findsOneWidget);
      expect(await count(db, 'habit_avoidance_occurrences'), 0);
      await tapText(tester, 'Record an incident');
      await tapText(tester, 'Record an incident');
      expect(find.text('Incidents: 2'), findsOneWidget);
      expect(find.text('Status: Pending'), findsOneWidget);
      expect(await count(db, 'habit_avoidance_resolutions'), 0);
      await tapText(tester, 'Confirm done');
      expect(find.text('Status: Completed'), findsOneWidget);
      await tapText(tester, 'Record an incident');
      expect(find.text('Incidents: 3'), findsOneWidget);
      expect(find.text('Status: Failed'), findsOneWidget);
      expect(await count(db, 'habit_avoidance_incidents'), 3);
      expect(await count(db, 'habit_avoidance_resolutions'), 1);
      expect(changes, 4);
    },
  );
}
