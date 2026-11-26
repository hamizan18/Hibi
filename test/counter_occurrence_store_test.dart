import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_occurrence_store.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as path;

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

Future<void> setupHabit(AppDatabase db) async {
  final writer = CounterHabitWriter(db, FixedClock());
  await writer.create(
    habitId: 'h',
    versionId: 'v1',
    auditId: 'a1',
    lifecycleEventId: 'l1',
    name: 'Read',
    effectiveDate: DateTime(2026, 11, 26),
    target: CounterTarget(count: 5, unit: 'pages'),
    schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
  );
  await writer.scheduleVersion(
    habitId: 'h',
    versionId: 'v2',
    auditId: 'a2',
    name: 'Read more',
    effectiveDate: DateTime(2026, 12, 1),
    target: CounterTarget(count: 20, unit: 'pages'),
    schedule: WeekdaySchedule(start: LocalDate(2026, 12, 1), weekdays: {2, 4}),
  );
}

void main() {
  test('repeated requests keep the original id and versioned target', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await setupHabit(db);
    final store = CounterOccurrenceStore(db);
    final old = await store.getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 30),
      occurrenceId: 'old',
    );
    final fresh = await store.getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 12, 1),
      occurrenceId: 'new',
    );
    final repeated = await store.getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 12, 1),
      occurrenceId: 'ignored',
    );
    expect(old.applicability, HabitApplicability.applicable);
    expect(old.occurrence!.versionId, 'v1');
    expect(old.occurrence!.targetCount, 5);
    expect(fresh.occurrence!.versionId, 'v2');
    expect(fresh.occurrence!.targetCount, 20);
    expect(repeated.occurrence!.id, 'new');
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
              .getSingle())
          .read<int>('n'),
      2,
    );
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_counter_events')
              .getSingle())
          .read<int>('n'),
      0,
    );
  });

  test(
    'before start, unscheduled and paused dates do not create occurrences',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await setupHabit(db);
      await HabitLifecycleStore(db, FixedClock()).append(
        id: 'pause',
        habitId: 'h',
        effectiveDate: LocalDate(2026, 12, 3),
        state: HabitLifecycleState.paused,
      );
      final store = CounterOccurrenceStore(db);
      for (final date in [
        LocalDate(2026, 11, 25),
        LocalDate(2026, 12, 2),
        LocalDate(2026, 12, 3),
      ]) {
        final result = await store.getOrCreate(
          habitId: 'h',
          date: date,
          occurrenceId: 'unused',
        );
        expect(result.applicability, HabitApplicability.notApplicable);
        expect(result.occurrence, isNull);
      }
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
                .getSingle())
            .read<int>('n'),
        0,
      );
    },
  );

  test('unknown configuration stays unknown, while preexisting history stays accessible', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement("INSERT INTO habits VALUES ('h', 1)");
    await db.customStatement(
      "INSERT INTO habit_versions VALUES ('v', 'h', 'Read', '2026-11-26', NULL, 1, 1)",
    );
    await db.customStatement(
      "INSERT INTO habit_counter_targets VALUES ('v', 5, 'pages')",
    );
    await db.customStatement(
      "INSERT INTO habit_occurrences VALUES ('existing', 'h', 'v', '2026-11-26', 5, 'pages')",
    );
    final store = CounterOccurrenceStore(db);
    final existing = await store.getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
      occurrenceId: 'ignored',
    );
    expect(existing.applicability, HabitApplicability.unknown);
    expect(existing.occurrence!.id, 'existing');
    final missing = await store.getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 27),
      occurrenceId: 'new',
    );
    expect(missing.applicability, HabitApplicability.unknown);
    expect(missing.occurrence, isNull);
  });

  test('missing counter target does not create a guessed occurrence', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement("INSERT INTO habits VALUES ('h', 1)");
    await db.customStatement(
      "INSERT INTO habit_versions VALUES ('v', 'h', 'Read', '2026-11-26', NULL, 1, 1)",
    );
    await db.customStatement(
      "INSERT INTO habit_schedules VALUES ('v', 'daily', '2026-11-26', NULL, NULL)",
    );
    await db.customStatement(
      "INSERT INTO habit_lifecycle_events VALUES ('l', 'h', '2026-11-26', NULL, 'active', NULL, 1)",
    );
    final result = await CounterOccurrenceStore(db).getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
      occurrenceId: 'o',
    );
    expect(result.applicability, HabitApplicability.unknown);
    expect(result.occurrence, isNull);
  });

  test('concurrent requests on one database return one occurrence', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await setupHabit(db);
    final store = CounterOccurrenceStore(db);
    final results = await Future.wait([
      store.getOrCreate(
        habitId: 'h',
        date: LocalDate(2026, 12, 1),
        occurrenceId: 'first',
      ),
      store.getOrCreate(
        habitId: 'h',
        date: LocalDate(2026, 12, 1),
        occurrenceId: 'second',
      ),
    ]);
    expect(results[0].occurrence!.id, results[1].occurrence!.id);
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
              .getSingle())
          .read<int>('n'),
      1,
    );
  });

  test(
    'database reopen returns the same occurrence without duplicating it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hibi_occurrence_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(path.join(directory.path, 'test.sqlite'));
      final first = AppDatabase(NativeDatabase(file));
      await setupHabit(first);
      await CounterOccurrenceStore(first).getOrCreate(
        habitId: 'h',
        date: LocalDate(2026, 12, 1),
        occurrenceId: 'o',
      );
      await first.close();
      final second = AppDatabase(NativeDatabase(file));
      addTearDown(second.close);
      final reopened = await CounterOccurrenceStore(second).getOrCreate(
        habitId: 'h',
        date: LocalDate(2026, 12, 1),
        occurrenceId: 'another',
      );
      expect(reopened.occurrence!.id, 'o');
      expect(reopened.occurrence!.targetCount, 20);
    },
  );
}
