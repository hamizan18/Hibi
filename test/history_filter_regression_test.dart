import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/history_analytics_screen.dart';

class _Clock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

void main() {
  testWidgets('current month excludes future dates from recording coverage', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = _Clock();
    await _createHabit(
      db,
      clock,
      'public',
      'Public Habit',
      'Public Category',
      false,
    );
    await CounterTodayActionService(db, clock).recordTodayProgress(
      habitId: 'public',
      occurrenceId: 'occ_public',
      eventId: 'event_public',
      quantity: 1,
    );
    await _show(tester, db, clock);

    await tester.tap(find.text('Current month'));
    await tester.pumpAndSettle();
    expect(
      find.text('Calendar Heatmap (2026-11-01 to 2026-11-26)'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('heatmap-cell-2026-11-27')), findsNothing);
    expect(
      find.text('Overall habit recording coverage: 1/1 (100.0%)'),
      findsOneWidget,
    );
  });

  testWidgets(
    'hiding private selections clears both displayed and actual filters',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _Clock();
      await _createHabit(
        db,
        clock,
        'public',
        'Public Habit',
        'Public Category',
        false,
      );
      await _createHabit(
        db,
        clock,
        'private',
        'Secret Habit',
        'Secret Category',
        true,
      );
      await CounterTodayActionService(db, clock).recordTodayProgress(
        habitId: 'public',
        occurrenceId: 'occ_public',
        eventId: 'event_public',
        quantity: 1,
      );
      await _show(tester, db, clock);

      await tester.tap(find.text('Show private or unclassified habits'));
      await tester.pumpAndSettle();
      final dropdowns = find.byType(DropdownButtonFormField<String?>);
      await tester.tap(dropdowns.first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Secret Category').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(dropdowns.last);
      await tester.tap(dropdowns.last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Secret Habit').last);
      await tester.pumpAndSettle();
      expect(find.text('Habit recording coverage: 0/1 (0.0%)'), findsOneWidget);

      final privacy = find.text('Show private or unclassified habits');
      await tester.ensureVisible(privacy);
      await tester.tap(privacy);
      await tester.pumpAndSettle();
      expect(find.text('All categories'), findsOneWidget);
      expect(find.text('All habits'), findsOneWidget);
      expect(find.textContaining('Secret Habit'), findsNothing);
      expect(find.textContaining('Secret Category'), findsNothing);
      expect(
        find.text('Habit recording coverage: 1/1 (100.0%)'),
        findsOneWidget,
      );
      expect(find.textContaining('Public Habit'), findsWidgets);

      await tester.tap(privacy);
      await tester.pumpAndSettle();
      expect(find.text('All categories'), findsOneWidget);
      expect(find.text('All habits'), findsOneWidget);
      expect(
        find.text('Habit recording coverage: 1/2 (50.0%)'),
        findsOneWidget,
      );
    },
  );
}

Future<void> _createHabit(
  AppDatabase db,
  AppClock clock,
  String id,
  String name,
  String category,
  bool isPrivate,
) async {
  await CounterHabitWriter(db, clock).create(
    habitId: id,
    versionId: 'version_$id',
    auditId: 'audit_$id',
    lifecycleEventId: 'lifecycle_$id',
    name: name,
    effectiveDate: DateTime(2026, 11, 26),
    target: CounterTarget(count: 1, unit: 'times'),
    schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
  );
  await HabitMetadataStore(db).insert(
    'version_$id',
    HabitMetadata(category: category, isPrivate: isPrivate),
  );
}

Future<void> _show(WidgetTester tester, AppDatabase db, AppClock clock) async {
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
}
