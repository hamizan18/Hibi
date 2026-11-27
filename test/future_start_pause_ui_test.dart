import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_lifecycle_action_service.dart';
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
  final today = LocalDate(2026, 11, 26);
  final start = LocalDate(2026, 11, 29);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock();
    changes = 0;
    await CounterHabitWriter(db, clock).create(
      habitId: 'h',
      versionId: 'v',
      auditId: 'a',
      lifecycleEventId: 'initial',
      name: 'Future habit',
      effectiveDate: DateTime(2026, 11, 29),
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: start),
    );
    habit = (await UnifiedHabitRegistryReader(db).readAll(asOfDate: today))
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

  Future<void> openDialog(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Pause from start'));
    await tester.tap(find.text('Pause from start'));
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Pause from start'),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('cancel preserves the initial event; confirm pauses from start', (
    tester,
  ) async {
    await showControls(tester, today);
    await openDialog(tester);
    expect(
      find.textContaining('initial start date, 2026-11-29'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect((await HabitLifecycleReader(db).readHistory('h')).length, 1);
    expect(changes, 0);

    await openDialog(tester);
    await confirm(tester);
    final history = await HabitLifecycleReader(db).readHistory('h');
    expect(history.map((event) => event.state), [
      HabitLifecycleState.active,
      HabitLifecycleState.paused,
    ]);
    expect(history.first.id, 'initial');
    expect(history.last.effectiveDate.compareTo(start), 0);
    expect(find.text('Pause from start'), findsNothing);
    expect(changes, 1);
    for (final table in ['habit_occurrences', 'habit_typed_occurrences']) {
      final count = await db
          .customSelect('SELECT COUNT(*) AS n FROM $table')
          .getSingle();
      expect(count.read<int>('n'), 0);
    }
  });

  testWidgets(
    'action is unavailable on other days or after another transition',
    (tester) async {
      await showControls(tester, start);
      expect(find.text('Pause from start'), findsNothing);
      await CounterLifecycleActionService(db, clock).pause(
        eventId: 'later',
        habitId: 'h',
        effectiveDate: LocalDate(2026, 11, 30),
      );
      await showControls(tester, today);
      expect(find.text('Pause from start'), findsNothing);
    },
  );

  testWidgets('initial start today is eligible but a past start is not', (
    tester,
  ) async {
    clock.current = DateTime(2026, 11, 29, 12);
    await showControls(tester, start);
    expect(find.text('Pause from start'), findsOneWidget);
    clock.current = DateTime(2026, 11, 30, 12);
    await showControls(tester, LocalDate(2026, 11, 30));
    expect(find.text('Pause from start'), findsNothing);
  });

  testWidgets('confirmation after midnight cannot pause a past start', (
    tester,
  ) async {
    clock.current = DateTime(2026, 11, 29, 23, 59);
    await showControls(tester, start);
    await openDialog(tester);
    clock.current = DateTime(2026, 11, 30, 0, 1);
    await confirm(tester);
    expect((await HabitLifecycleReader(db).readHistory('h')).length, 1);
    expect(changes, 0);
  });

  testWidgets('stale lifecycle change reloads and reports an error', (
    tester,
  ) async {
    await showControls(tester, today);
    await openDialog(tester);
    await CounterLifecycleActionService(db, clock).pause(
      eventId: 'later',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 30),
    );
    await confirm(tester);
    expect(find.textContaining('could not be saved'), findsOneWidget);
    expect(find.text('Pause from start'), findsNothing);
    expect(changes, 0);
  });
}
