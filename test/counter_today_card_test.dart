import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/counter_day_status.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/counter_today_card.dart';

class TestClock implements AppClock {
  DateTime current = DateTime(2026, 11, 26, 12);
  @override
  DateTime now() => current;
}

void main() {
  late AppDatabase db;
  late TestClock clock;
  late UnifiedHabitSummary habit;
  final date = LocalDate(2026, 11, 26);
  var changes = 0;

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
      schedule: DailySchedule(start: date),
    );
    habit = (await UnifiedHabitRegistryReader(db).readAll(asOfDate: date))
        .single;
  });
  tearDown(() => db.close());

  Future<void> showCard(WidgetTester tester, {LocalDate? selected}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appClockProvider.overrideWithValue(clock),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CounterTodayCard(
                habit: habit,
                date: selected ?? date,
                onChanged: () => changes++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('loading does not write and progress entries accumulate', (
    tester,
  ) async {
    await showCard(tester);
    expect(find.text('Pending'), findsOneWidget);
    expect(
      (await CounterDayReader(
        db,
      ).evaluate(habitId: 'h', date: date)).hasOccurrence,
      isFalse,
    );
    expect(changes, 0);
    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.text('Add progress'));
    await tester.pumpAndSettle();
    expect(find.textContaining('positive whole number'), findsOneWidget);
    expect(
      (await CounterDayReader(
        db,
      ).evaluate(habitId: 'h', date: date)).hasOccurrence,
      isFalse,
    );
    await tester.enterText(find.byType(TextField), '4');
    await tester.tap(find.text('Add progress'));
    await tester.pumpAndSettle();
    expect(find.text('In progress'), findsOneWidget);
    expect(find.text('Progress: 4 / 10 pages'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '6');
    await tester.tap(find.text('Add progress'));
    await tester.pumpAndSettle();
    expect(find.text('Completed'), findsOneWidget);
    expect(changes, 2);
    final result = await CounterDayReader(db)
        .evaluate(habitId: 'h', date: date);
    expect(result.day.recorded!.progress.total, 10);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Add progress'),
          )
          .onPressed,
      isNull,
    );
  });

  for (final state in CounterResolutionState.values) {
    testWidgets(
      'explicit ${state.name} preserves progress and disables actions',
      (tester) async {
        await showCard(tester);
        await tester.enterText(find.byType(TextField), '3');
        await tester.tap(find.text('Add progress'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(
            state == CounterResolutionState.failed ? 'Mark failed' : 'Excuse',
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            state == CounterResolutionState.failed ? 'Failed' : 'Excused',
          ),
          findsOneWidget,
        );
        final result = await CounterDayReader(db)
            .evaluate(habitId: 'h', date: date);
        expect(result.day.recorded!.progress.total, 3);
        expect(result.day.resolution!.progress, 3);
        expect(result.day.resolution!.state, state);
        expect(changes, 2);
        expect(
          tester
              .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Add progress'),
              )
              .onPressed,
          isNull,
        );
      },
    );
  }

  testWidgets('stale day cannot write, recovered history remains visible', (
    tester,
  ) async {
    final service = CounterTodayActionService(db, clock);
    await service.resolveToday(
      habitId: 'h',
      occurrenceId: 'o',
      resolutionId: 'r',
      state: CounterResolutionState.failed,
    );
    clock.current = DateTime(2026, 11, 27, 12);
    await service.recoverPriorDeficit(
      recoveryId: 'recovery',
      occurrenceId: 'o',
      quantity: 10,
    );
    await showCard(tester);
    expect(find.text('Recovered'), findsOneWidget);
    expect(find.text('Progress: 0 / 10 pages'), findsOneWidget);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Add progress'),
          )
          .onPressed,
      isNull,
    );
    expect(changes, 0);
  });

  testWidgets('unavailable day disables actions without creating records', (
    tester,
  ) async {
    await showCard(tester, selected: LocalDate(2026, 11, 25));
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Add progress'),
          )
          .onPressed,
      isNull,
    );
    expect(
      (await CounterDayReader(
        db,
      ).evaluate(habitId: 'h', date: date)).effectiveStatus,
      CounterDayEffectiveStatus.pending,
    );
    expect(changes, 0);
  });
}
