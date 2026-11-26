import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_occurrence_store.dart';
import 'package:hibi/features/habits/data/counter_progress_writer.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/domain/counter_progress.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

Future<void> createHabit(AppDatabase db) =>
    CounterHabitWriter(db, FixedClock()).create(
      habitId: 'h',
      versionId: 'v',
      auditId: 'a',
      lifecycleEventId: 'l',
      name: 'Read',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: WeekdaySchedule(start: LocalDate(2026, 11, 26), weekdays: {4}),
    );

void main() {
  test('applicable missing occurrence remains missing and reader performs no writes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await createHabit(db);
    final reader = CounterDayReader(db);
    final result = await reader.read(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
    );
    expect(result.applicability, HabitApplicability.applicable);
    expect(result.occurrenceId, isNull);
    expect(result.recorded, isNull);
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
              .getSingle())
          .read<int>('n'),
      0,
    );
    await expectLater(
      reader.read(habitId: 'absent', date: LocalDate(2026, 11, 26)),
      throwsStateError,
    );
  });

  test(
    'recorded progress is returned with schedule and historical target',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await createHabit(db);
      await CounterOccurrenceStore(db).getOrCreate(
        habitId: 'h',
        date: LocalDate(2026, 11, 26),
        occurrenceId: 'o',
      );
      final reader = CounterDayReader(db);
      var result = await reader.read(
        habitId: 'h',
        date: LocalDate(2026, 11, 26),
      );
      expect(result.applicability, HabitApplicability.applicable);
      expect(result.recorded!.progress.status, CounterProgressStatus.pending);
      await CounterProgressWriter(
        db,
        FixedClock(),
      ).append(eventId: 'e', occurrenceId: 'o', quantity: 2);
      await CounterHabitWriter(db, FixedClock()).scheduleVersion(
        habitId: 'h',
        versionId: 'v2',
        auditId: 'a2',
        name: 'More',
        effectiveDate: DateTime(2026, 12, 1),
        target: CounterTarget(count: 20, unit: 'pages'),
        schedule: DailySchedule(start: LocalDate(2026, 12, 1)),
      );
      result = await reader.read(habitId: 'h', date: LocalDate(2026, 11, 26));
      expect(result.occurrenceId, 'o');
      expect(result.recorded!.progress.target, 5);
      expect(result.recorded!.progress.total, 2);
      expect(result.recorded!.progress.status, CounterProgressStatus.partial);
      expect(result.recorded!.unit, 'pages');
    },
  );

  test(
    'before start, unscheduled and paused dates remain not applicable',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await createHabit(db);
      await HabitLifecycleStore(db, FixedClock()).append(
        id: 'p',
        habitId: 'h',
        effectiveDate: LocalDate(2026, 12, 3),
        state: HabitLifecycleState.paused,
      );
      final reader = CounterDayReader(db);
      for (final date in [
        LocalDate(2026, 11, 25),
        LocalDate(2026, 11, 27),
        LocalDate(2026, 12, 3),
      ]) {
        final result = await reader.read(habitId: 'h', date: date);
        expect(result.applicability, HabitApplicability.notApplicable);
        expect(result.recorded, isNull);
      }
    },
  );

  test('existing records remain visible when applicability is unknown or not applicable', () async {
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
      "INSERT INTO habit_occurrences VALUES ('o', 'h', 'v', '2026-11-26', 5, 'pages')",
    );
    await db.customStatement(
      "INSERT INTO habit_counter_events VALUES ('e', 'o', 3, 1)",
    );
    final unknown = await CounterDayReader(db)
        .read(habitId: 'h', date: LocalDate(2026, 11, 26));
    expect(unknown.applicability, HabitApplicability.unknown);
    expect(unknown.occurrenceId, 'o');
    expect(unknown.recorded!.progress.total, 3);
    expect(unknown.recorded!.progress.status, CounterProgressStatus.partial);
    final unknownMissing = await CounterDayReader(db)
        .read(habitId: 'h', date: LocalDate(2026, 11, 27));
    expect(unknownMissing.applicability, HabitApplicability.unknown);
    expect(unknownMissing.recorded, isNull);
    await db.customStatement("INSERT INTO habits VALUES ('h2', 1)");
    await db.customStatement(
      "INSERT INTO habit_versions VALUES ('v2', 'h2', 'Read', '2026-11-26', NULL, 1, 1)",
    );
    await db.customStatement(
      "INSERT INTO habit_counter_targets VALUES ('v2', 5, 'pages')",
    );
    await db.customStatement(
      "INSERT INTO habit_lifecycle_events VALUES ('p', 'h2', '2026-11-25', NULL, 'paused', NULL, 1)",
    );
    await db.customStatement(
      "INSERT INTO habit_occurrences VALUES ('o2', 'h2', 'v2', '2026-11-26', 5, 'pages')",
    );
    await db.customStatement(
      "INSERT INTO habit_counter_events VALUES ('e2', 'o2', 3, 1)",
    );
    final paused = await CounterDayReader(db)
        .read(habitId: 'h2', date: LocalDate(2026, 11, 26));
    expect(paused.applicability, HabitApplicability.notApplicable);
    expect(paused.occurrenceId, 'o2');
    expect(paused.recorded!.progress.total, 3);
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_counter_events')
              .getSingle())
          .read<int>('n'),
      2,
    );
  });
}
