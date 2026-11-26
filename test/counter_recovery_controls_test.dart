import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_recovery_eligibility.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/counter_recovery_controls.dart';

class TestClock implements AppClock {
  DateTime current = DateTime(2026, 11, 26, 12);
  @override
  DateTime now() => current;
}

void main() {
  late AppDatabase db;
  late TestClock clock;
  final prior = LocalDate(2026, 11, 26);
  final today = LocalDate(2026, 11, 27);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock();
    await CounterHabitWriter(db, clock).create(
      habitId: 'h',
      versionId: 'v',
      auditId: 'a',
      lifecycleEventId: 'l',
      name: 'Reading',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 10, unit: 'pages'),
      schedule: DailySchedule(start: prior),
    );
    final actions = CounterTodayActionService(db, clock);
    await actions.recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o',
      eventId: 'e',
      quantity: 3,
    );
    await actions.resolveToday(
      habitId: 'h',
      occurrenceId: 'o',
      resolutionId: 'r',
      state: CounterResolutionState.failed,
    );
    clock.current = DateTime(2026, 11, 27, 12);
  });
  tearDown(() => db.close());

  Future<void> metadata(bool enabled) => HabitMetadataStore(
    db,
  ).insert('v', HabitMetadata(category: 'General', recoveryEnabled: enabled));

  test('unknown and disabled metadata are ineligible', () async {
    final service = CounterRecoveryEligibility(db, clock);
    expect(await service.find(habitId: 'h', asOfDate: today), isEmpty);
    await metadata(false);
    expect(await service.find(habitId: 'h', asOfDate: today), isEmpty);
    await expectLater(
      service.recover(
        habitId: 'h',
        date: today,
        occurrenceId: 'o',
        recoveryId: 'x',
        quantity: 1,
      ),
      throwsStateError,
    );
  });

  test('stale deficit cannot be recovered twice', () async {
    await metadata(true);
    final service = CounterRecoveryEligibility(db, clock);
    expect(await service.find(habitId: 'h', asOfDate: today), hasLength(1));
    await service.recover(
      habitId: 'h',
      date: today,
      occurrenceId: 'o',
      recoveryId: 'first',
      quantity: 7,
    );
    await expectLater(
      service.recover(
        habitId: 'h',
        date: today,
        occurrenceId: 'o',
        recoveryId: 'second',
        quantity: 1,
      ),
      throwsStateError,
    );
  });

  testWidgets('private historical deficits require explicit reveal', (
    tester,
  ) async {
    await HabitMetadataStore(db).insert(
      'v',
      HabitMetadata(
        category: 'General',
        recoveryEnabled: true,
        isPrivate: true,
      ),
    );
    final habit = (await UnifiedHabitRegistryReader(
      db,
    ).readAll(asOfDate: today)).single;
    Widget view(bool reveal) => ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appClockProvider.overrideWithValue(clock),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: CounterRecoveryControls(
            habit: habit,
            date: today,
            showPrivateHistory: reveal,
            onChanged: () {},
          ),
        ),
      ),
    );
    await tester.pumpWidget(view(false));
    await tester.pumpAndSettle();
    expect(find.text('2026-11-26: 7 pages remaining'), findsNothing);
    await tester.pumpWidget(view(true));
    await tester.pumpAndSettle();
    expect(find.text('2026-11-26: 7 pages remaining'), findsOneWidget);
  });

  testWidgets(
    'read only, validation, partial and full recovery preserve progress',
    (tester) async {
      await metadata(true);
      final actions = CounterTodayActionService(db, clock);
      await actions.recordTodayProgress(
        habitId: 'h',
        occurrenceId: 'today',
        eventId: 'today-event',
        quantity: 2,
      );
      final habit = (await UnifiedHabitRegistryReader(
        db,
      ).readAll(asOfDate: today)).single;
      var changes = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: CounterRecoveryControls(
                  habit: habit,
                  date: today,
                  showPrivateHistory: false,
                  onChanged: () => changes++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2026-11-26: 7 pages remaining'), findsOneWidget);
      expect(
        (await db
                .customSelect(
                  'SELECT COUNT(*) AS n FROM habit_counter_recoveries',
                )
                .getSingle())
            .read<int>('n'),
        0,
      );
      await tester.enterText(find.byType(TextField), '8');
      await tester.tap(find.text('Recover'));
      await tester.pumpAndSettle();
      expect(find.textContaining('no greater'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '2');
      await tester.tap(find.text('Recover'));
      await tester.pumpAndSettle();
      expect(find.text('2026-11-26: 5 pages remaining'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '5');
      await tester.tap(find.text('Recover'));
      await tester.pumpAndSettle();
      expect(find.text('No recoverable deficits.'), findsOneWidget);
      expect(changes, 2);
      expect(
        (await CounterDayReader(
          db,
        ).evaluate(habitId: 'h', date: prior)).day.recorded!.progress.total,
        3,
      );
      expect(
        (await CounterDayReader(
          db,
        ).evaluate(habitId: 'h', date: today)).day.recorded!.progress.total,
        2,
      );
    },
  );

  test('rollover and excessive quantities cannot write', () async {
    await metadata(true);
    final service = CounterRecoveryEligibility(db, clock);
    await expectLater(
      service.recover(
        habitId: 'h',
        date: today,
        occurrenceId: 'o',
        recoveryId: 'x',
        quantity: 8,
      ),
      throwsStateError,
    );
    await expectLater(
      service.recover(
        habitId: 'h',
        date: today,
        occurrenceId: 'o',
        recoveryId: 'x',
        quantity: 0,
      ),
      throwsStateError,
    );
    clock.current = DateTime(2026, 11, 28, 1);
    await expectLater(
      service.recover(
        habitId: 'h',
        date: today,
        occurrenceId: 'o',
        recoveryId: 'x',
        quantity: 1,
      ),
      throwsStateError,
    );
    expect(
      (await db
              .customSelect(
                'SELECT COUNT(*) AS n FROM habit_counter_recoveries',
              )
              .getSingle())
          .read<int>('n'),
      0,
    );
  });
}
