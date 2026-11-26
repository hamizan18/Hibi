import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/checklist_habit_store.dart';
import 'package:hibi/features/habits/data/checklist_recovery_eligibility.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/checklist_habit.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/checklist_recovery_controls.dart';

class FakeClock implements AppClock {
  DateTime current = DateTime(2026, 11, 26, 9);
  @override
  DateTime now() => current;
}

class AdvancingClock implements AppClock {
  int calls = 0;
  @override
  DateTime now() => calls++ == 0
      ? DateTime(2026, 11, 27, 23, 59, 59)
      : DateTime(2026, 11, 28);
}

final yesterday = LocalDate(2026, 11, 26);
final today = LocalDate(2026, 11, 27);

Future<int> count(AppDatabase db, String table) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<void> seed(
  AppDatabase db,
  FakeClock clock, {
  HabitMetadata? metadata,
  bool oneTime = false,
}) async {
  final service = ChecklistHabitService(db, clock);
  await service.create(
    habitId: 'h',
    versionId: 'v',
    lifecycleEventId: 'l',
    name: 'List',
    effectiveDate: clock.current,
    schedule: oneTime
        ? OneTimeSchedule(date: yesterday)
        : DailySchedule(start: yesterday),
    metadata: metadata,
    items: [
      ChecklistItemDefinition(id: 'a', label: 'Alpha', displayOrder: 0),
      ChecklistItemDefinition(id: 'b', label: 'Beta', displayOrder: 1),
      ChecklistItemDefinition(
        id: 'c',
        label: 'Gamma',
        displayOrder: 2,
        recoveryEnabled: false,
      ),
    ],
  );
  await service.logItemToday(
    habitId: 'h',
    occurrenceId: 'o',
    logId: 'la',
    itemId: 'a',
    state: ChecklistItemLogState.failed,
  );
  await service.logItemToday(
    habitId: 'h',
    occurrenceId: 'unused',
    logId: 'lc',
    itemId: 'c',
    state: ChecklistItemLogState.failed,
  );
  clock.current = DateTime(2026, 11, 27, 9);
}

HabitMetadata enabled() =>
    HabitMetadata(category: 'Test', recoveryEnabled: true);

void main() {
  testWidgets(
    'partial failure is recoverable on an active unscheduled day without read writes',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = FakeClock();
      await seed(db, clock, metadata: enabled(), oneTime: true);
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
              body: ChecklistRecoveryControls(
                habit: habit,
                date: today,
                showPrivateHistory: false,
                onChanged: () => changes++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Recover Alpha (2026-11-26)'), findsOneWidget);
      expect(find.textContaining('Recover Gamma'), findsNothing);
      expect(await count(db, 'habit_checklist_occurrences'), 1);
      expect(await count(db, 'habit_checklist_item_logs'), 2);
      expect(await count(db, 'habit_checklist_item_recoveries'), 0);
      await tester.tap(find.text('Recover Alpha (2026-11-26)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Recover Alpha'), findsNothing);
      expect(changes, 1);
      expect(await count(db, 'habit_checklist_occurrences'), 1);
      expect(await count(db, 'habit_checklist_item_logs'), 2);
      expect(await count(db, 'habit_checklist_item_recoveries'), 1);
      final day = await ChecklistHabitService(
        db,
        clock,
      ).readDay(habitId: 'h', date: today);
      expect(day.occurrenceId, isNull);
    },
  );

  testWidgets('private historical checklist labels require explicit reveal', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = FakeClock();
    await seed(
      db,
      clock,
      metadata: HabitMetadata(
        category: 'Test',
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
          body: ChecklistRecoveryControls(
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
    expect(find.textContaining('Recover Alpha'), findsNothing);
    await tester.pumpWidget(view(true));
    await tester.pumpAndSettle();
    expect(find.textContaining('Recover Alpha'), findsOneWidget);
  });

  for (final metadata in <HabitMetadata?>[
    null,
    HabitMetadata(category: 'Test'),
  ]) {
    test('missing or disabled historical metadata excludes recovery', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = FakeClock();
      await seed(db, clock, metadata: metadata);
      expect(
        await ChecklistRecoveryEligibility(
          db,
          clock,
        ).read(habitId: 'h', date: today),
        isEmpty,
      );
    });
  }

  test('stale eligibility, duplicate and same-day recovery are rejected atomically', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = FakeClock();
    await seed(db, clock, metadata: enabled());
    final eligibility = ChecklistRecoveryEligibility(db, clock);
    expect(
      (await eligibility.read(habitId: 'h', date: today)).map((e) => e.itemId),
      ['a'],
    );
    await db.customStatement(
      'UPDATE habit_version_metadata SET recovery_enabled = 0 WHERE habit_version_id = ?',
      ['v'],
    );
    await expectLater(
      eligibility.recover(
        habitId: 'h',
        date: today,
        occurrenceId: 'o',
        itemId: 'a',
        recoveryId: 'r',
      ),
      throwsStateError,
    );
    expect(await count(db, 'habit_checklist_item_recoveries'), 0);
    await db.customStatement(
      'UPDATE habit_version_metadata SET recovery_enabled = 1 WHERE habit_version_id = ?',
      ['v'],
    );
    await eligibility.recover(
      habitId: 'h',
      date: today,
      occurrenceId: 'o',
      itemId: 'a',
      recoveryId: 'r',
    );
    await expectLater(
      eligibility.recover(
        habitId: 'h',
        date: today,
        occurrenceId: 'o',
        itemId: 'a',
        recoveryId: 'r2',
      ),
      throwsStateError,
    );
    await expectLater(
      eligibility.recover(
        habitId: 'h',
        date: yesterday,
        occurrenceId: 'o',
        itemId: 'a',
        recoveryId: 'r3',
      ),
      throwsStateError,
    );
    expect(await count(db, 'habit_checklist_item_recoveries'), 1);
  });

  test('inactive lifecycle excludes prior failures', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = FakeClock();
    await seed(db, clock, metadata: enabled());
    await HabitLifecycleStore(db, clock).append(
      id: 'paused',
      habitId: 'h',
      effectiveDate: today,
      state: HabitLifecycleState.paused,
    );
    final eligibility = ChecklistRecoveryEligibility(db, clock);
    expect(await eligibility.read(habitId: 'h', date: today), isEmpty);
    await expectLater(
      eligibility.recover(
        habitId: 'h',
        date: today,
        occurrenceId: 'o',
        itemId: 'a',
        recoveryId: 'r',
      ),
      throwsStateError,
    );
    expect(await count(db, 'habit_checklist_item_recoveries'), 0);
  });

  test('unknown historical applicability excludes failures', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = FakeClock();
    await seed(db, clock, metadata: enabled());
    await db.customStatement(
      'DELETE FROM habit_schedules WHERE habit_version_id = ?',
      ['v'],
    );
    final eligibility = ChecklistRecoveryEligibility(db, clock);
    expect(await eligibility.read(habitId: 'h', date: today), isEmpty);
    await expectLater(
      eligibility.recover(
        habitId: 'h',
        date: today,
        occurrenceId: 'o',
        itemId: 'a',
        recoveryId: 'r',
      ),
      throwsStateError,
    );
    expect(await count(db, 'habit_checklist_item_recoveries'), 0);
  });

  test(
    'one captured instant is used throughout recovery at midnight',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await seed(db, FakeClock(), metadata: enabled());
      final clock = AdvancingClock();
      await ChecklistRecoveryEligibility(db, clock).recover(
        habitId: 'h',
        date: today,
        occurrenceId: 'o',
        itemId: 'a',
        recoveryId: 'midnight',
      );
      expect(clock.calls, 1);
      final row = await db
          .customSelect(
            "SELECT recovery_local_date FROM habit_checklist_item_recoveries WHERE id = 'midnight'",
          )
          .getSingle();
      expect(row.read<String>('recovery_local_date'), '2026-11-27');
    },
  );

  test(
    'today failures cannot be recovered and independent today logs survive',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = FakeClock();
      await seed(db, clock, metadata: enabled());
      await ChecklistHabitService(db, clock).logItemToday(
        habitId: 'h',
        occurrenceId: 'today',
        logId: 'today-log',
        itemId: 'a',
        state: ChecklistItemLogState.failed,
      );
      final eligibility = ChecklistRecoveryEligibility(db, clock);
      await expectLater(
        eligibility.recover(
          habitId: 'h',
          date: today,
          occurrenceId: 'today',
          itemId: 'a',
          recoveryId: 'bad',
        ),
        throwsStateError,
      );
      await eligibility.recover(
        habitId: 'h',
        date: today,
        occurrenceId: 'o',
        itemId: 'a',
        recoveryId: 'good',
      );
      final day = await ChecklistHabitService(
        db,
        clock,
      ).readDay(habitId: 'h', date: today);
      expect(
        day.progress!.items.first.state,
        ChecklistItemEffectiveState.failed,
      );
      expect(await count(db, 'habit_checklist_item_logs'), 3);
    },
  );
}
