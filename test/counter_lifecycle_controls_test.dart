import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_lifecycle_action_service.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/counter_lifecycle_controls.dart';

class TestClock implements AppClock {
  DateTime current = DateTime(2026, 11, 26, 12);
  @override
  DateTime now() => current;
}

void main() {
  late AppDatabase db;
  late TestClock clock;
  late UnifiedHabitSummary habit;
  var changes = 0;
  final start = LocalDate(2026, 11, 26);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock();
    changes = 0;
    await CounterHabitWriter(db, clock).create(
      habitId: 'h',
      versionId: 'v',
      auditId: 'a',
      lifecycleEventId: 'l',
      name: 'Reading',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 10, unit: 'pages'),
      schedule: DailySchedule(start: start),
    );
    habit = (await UnifiedHabitRegistryReader(db).readAll(asOfDate: start))
        .single;
  });
  tearDown(() => db.close());

  Future<void> showControls(WidgetTester tester, LocalDate date) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appClockProvider.overrideWithValue(clock),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CounterLifecycleControls(
                key: ValueKey('${date.year}-${date.month}-${date.day}'),
                habit: habit,
                date: date,
                onChanged: () => changes++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester, String label) =>
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label))
          .onPressed !=
      null;

  Future<void> tapAction(
    WidgetTester tester,
    String label, {
    bool confirm = false,
  }) async {
    await tester.tap(find.widgetWithText(OutlinedButton, label));
    await tester.pumpAndSettle();
    if (confirm) {
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
    }
  }

  testWidgets(
    'same-day and invalid actions are disabled, cancellation writes nothing',
    (tester) async {
      await showControls(tester, start);
      expect(enabled(tester, 'Pause'), isFalse);
      expect(find.textContaining('same-day transitions'), findsOneWidget);
      expect((await HabitLifecycleReader(db).readHistory('h')).length, 1);

      clock.current = DateTime(2026, 11, 27, 12);
      await showControls(tester, LocalDate(2026, 11, 27));
      expect(enabled(tester, 'Pause'), isTrue);
      expect(enabled(tester, 'Resume'), isFalse);
      expect(enabled(tester, 'Restore'), isFalse);
      for (final label in ['Archive', 'Soft-delete']) {
        await tapAction(tester, label);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
      expect((await HabitLifecycleReader(db).readHistory('h')).length, 1);
      expect(changes, 0);
    },
  );

  testWidgets('dated lifecycle transitions preserve historical progress', (
    tester,
  ) async {
    await CounterTodayActionService(db, clock).recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o',
      eventId: 'progress',
      quantity: 10,
    );
    clock.current = DateTime(2026, 11, 27, 12);
    await showControls(tester, LocalDate(2026, 11, 27));
    await tapAction(tester, 'Pause');
    expect(enabled(tester, 'Resume'), isFalse);
    clock.current = DateTime(2026, 11, 28, 12);
    await showControls(tester, LocalDate(2026, 11, 28));
    await tapAction(tester, 'Resume');
    clock.current = DateTime(2026, 11, 29, 12);
    await showControls(tester, LocalDate(2026, 11, 29));
    await tapAction(tester, 'Archive', confirm: true);
    clock.current = DateTime(2026, 11, 30, 12);
    await showControls(tester, LocalDate(2026, 11, 30));
    expect(enabled(tester, 'Resume'), isFalse);
    await tapAction(tester, 'Soft-delete', confirm: true);
    clock.current = DateTime(2026, 12, 1, 12);
    await showControls(tester, LocalDate(2026, 12, 1));
    await tapAction(tester, 'Restore');
    final history = await HabitLifecycleReader(db).readHistory('h');
    expect(history.map((e) => e.state), [
      HabitLifecycleState.active,
      HabitLifecycleState.paused,
      HabitLifecycleState.active,
      HabitLifecycleState.archived,
      HabitLifecycleState.deleted,
      HabitLifecycleState.active,
    ]);
    expect(changes, 5);
    final oldDay = await CounterDayReader(db)
        .evaluate(habitId: 'h', date: start);
    expect(oldDay.day.recorded!.progress.total, 10);
  });

  testWidgets('future selection is exact and stale conflicts are safe', (
    tester,
  ) async {
    clock.current = DateTime(2026, 11, 27, 12);
    await showControls(tester, LocalDate(2026, 11, 27));
    await tester.tap(find.text('Effective date: 2026-11-27'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('29').last);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Effective date: 2026-11-29'), findsOneWidget);
    await tapAction(tester, 'Pause');
    var history = await HabitLifecycleReader(db).readHistory('h');
    expect(history.last.effectiveDate.compareTo(LocalDate(2026, 11, 29)), 0);
    expect(find.text('Current: active'), findsOneWidget);
    expect(enabled(tester, 'Resume'), isFalse);

    clock.current = DateTime(2026, 11, 30, 12);
    await showControls(tester, LocalDate(2026, 11, 30));
    await CounterLifecycleActionService(db, clock).resume(
      eventId: 'external',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 30),
    );
    await tapAction(tester, 'Resume');
    expect(find.textContaining('could not be saved'), findsOneWidget);
    history = await HabitLifecycleReader(db).readHistory('h');
    expect(history.length, 3);
    expect(changes, 1);
  });
}
