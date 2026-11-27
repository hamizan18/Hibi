import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/app/app.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/avoidance_habit_store.dart';
import 'package:hibi/features/habits/data/checklist_habit_store.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/avoidance_habit.dart';
import 'package:hibi/features/habits/domain/checklist_habit.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/history_analytics_screen.dart';

class TestClock implements AppClock {
  DateTime current = DateTime(2026, 11, 26, 12);
  @override
  DateTime now() => current;
}

void main() {
  testWidgets(
    'HistoryAnalyticsView renders heatmap, selected-day inspection, coverage, streaks and hides private habits until revealed',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = TestClock();

      await CounterHabitWriter(db, clock).create(
        habitId: 'h_quran',
        versionId: 'v_q1',
        auditId: 'a_q1',
        lifecycleEventId: 'l_q1',
        name: 'Quran Reading',
        effectiveDate: DateTime(2026, 11, 26),
        target: CounterTarget(count: 5, unit: 'pages'),
        schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
      );
      await HabitMetadataStore(db).insert(
        'v_q1',
        HabitMetadata(
          category: 'Spiritual',
          priority: HabitPriority.critical,
          isPrivate: false,
          recoveryEnabled: true,
        ),
      );
      await CounterTodayActionService(db, clock).recordTodayProgress(
        habitId: 'h_quran',
        occurrenceId: 'occ_q_26',
        eventId: 'ev_q_1',
        quantity: 5,
      );

      await ChecklistHabitService(db, clock).createFromStarterTemplate(
        template: ChecklistStarterTemplate.dailyPrayers,
        habitId: 'h_prayers',
        versionId: 'v_p1',
        lifecycleEventId: 'l_p1',
        itemIds: const ['i1', 'i2', 'i3', 'i4', 'i5'],
        effectiveDate: DateTime(2026, 11, 26),
      );

      await AvoidanceHabitService(db, clock).createFromStarterTemplate(
        template: AvoidanceStarterTemplate.selfControl,
        habitId: 'h_private',
        versionId: 'v_priv1',
        lifecycleEventId: 'l_priv1',
        effectiveDate: DateTime(2026, 11, 26),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: HistoryAnalyticsView(asOfDate: LocalDate(2026, 11, 26)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Private habit is hidden by default
      expect(find.textContaining('Quran Reading'), findsWidgets);
      expect(find.textContaining('Daily Prayers'), findsWidgets);
      expect(find.textContaining('Self Control'), findsNothing);

      // Selected day (2026-11-26) shows 100.0% score with incomplete recording (Daily Prayers pending)
      expect(
        find.textContaining(
          'Daily weighted score: 100.0% (incomplete recording: 1 pending)',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Habit recording coverage: 1/2 (50.0%)'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Checklist item coverage: 0/5 (0.0%)'),
        findsOneWidget,
      );

      // Tapping an earlier pre-start heatmap cell (2026-11-20) shows No Data
      final cell20 = find.byKey(const Key('heatmap-cell-2026-11-20'));
      await tester.ensureVisible(cell20);
      await tester.pumpAndSettle();
      await tester.tap(cell20);
      await tester.pumpAndSettle();
      expect(find.text('Selected Day: 2026-11-20'), findsOneWidget);
      expect(find.text('Daily weighted score: No Data'), findsOneWidget);

      // Toggling private visibility reveals Self Control
      final privateSwitch = find.text('Show private or unclassified habits');
      await tester.ensureVisible(privateSwitch);
      await tester.pumpAndSettle();
      await tester.tap(privateSwitch);
      await tester.pumpAndSettle();
      expect(find.textContaining('Self Control'), findsWidgets);

      // Non-judgmental disclaimer is displayed
      expect(
        find.textContaining('never measure human worth or faith'),
        findsOneWidget,
      );
    },
  );

  testWidgets('HibiApp navigates to History & Analytics tab', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appClockProvider.overrideWithValue(TestClock()),
          databaseInitializationProvider.overrideWith((ref) async {}),
        ],
        child: const HibiApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('History & Analytics'), findsOneWidget);
    expect(find.text('Filters & Privacy'), findsOneWidget);
  });
}
