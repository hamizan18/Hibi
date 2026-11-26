import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_occurrence_store.dart';
import 'package:hibi/features/habits/data/counter_progress_reader.dart';
import 'package:hibi/features/habits/data/counter_progress_writer.dart';
import 'package:hibi/features/habits/domain/counter_progress.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

void main() {
  test('empty, partial, exact and excess progress have distinct statuses', () {
    final empty = CounterProgress.fromEvents(target: 5, quantities: []);
    expect(empty.total, 0);
    expect(empty.status, CounterProgressStatus.pending);
    final partial = CounterProgress.fromEvents(target: 5, quantities: [2]);
    expect(partial.total, 2);
    expect(partial.status, CounterProgressStatus.partial);
    final exact = CounterProgress.fromEvents(target: 5, quantities: [2, 3]);
    expect(exact.total, 5);
    expect(exact.status, CounterProgressStatus.completed);
    final excess = CounterProgress.fromEvents(target: 5, quantities: [2, 4]);
    expect(excess.total, 6);
    expect(excess.status, CounterProgressStatus.completed);
  });

  test('invalid targets and events, including those after completion, are rejected', () {
    for (final target in [0, -1]) {
      expect(
        () => CounterProgress.fromEvents(target: target, quantities: []),
        throwsRangeError,
      );
    }
    for (final quantities in [
      [0],
      [-1],
      [5, 0],
    ]) {
      expect(
        () => CounterProgress.fromEvents(target: 5, quantities: quantities),
        throwsRangeError,
      );
    }
  });

  test('signed 64-bit totals are exact and overflow is rejected', () {
    const max = 9223372036854775807;
    final progress = CounterProgress.fromEvents(
      target: max,
      quantities: [max - 1, 1],
    );
    expect(progress.total, max);
    expect(progress.status, CounterProgressStatus.completed);
    expect(
      () => CounterProgress.fromEvents(target: 1, quantities: [max, 1]),
      throwsRangeError,
    );
  });

  test('persisted events recalculate against the occurrence snapshot without writes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final writer = CounterHabitWriter(db, FixedClock());
    await writer.create(
      habitId: 'h',
      versionId: 'v1',
      auditId: 'a1',
      lifecycleEventId: 'l',
      name: 'Read',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    await CounterOccurrenceStore(db).getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
      occurrenceId: 'o',
    );
    await writer.scheduleVersion(
      habitId: 'h',
      versionId: 'v2',
      auditId: 'a2',
      name: 'Read more',
      effectiveDate: DateTime(2026, 12, 1),
      target: CounterTarget(count: 20, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 12, 1)),
    );
    final reader = CounterProgressReader(db);
    expect(await reader.find('missing'), isNull);
    var result = (await reader.find('o'))!;
    expect(result.progress.target, 5);
    expect(result.progress.status, CounterProgressStatus.pending);
    expect(result.unit, 'pages');
    final progressWriter = CounterProgressWriter(db, FixedClock());
    await progressWriter.append(eventId: 'e1', occurrenceId: 'o', quantity: 2);
    result = (await reader.find('o'))!;
    expect(result.progress.total, 2);
    expect(result.progress.status, CounterProgressStatus.partial);
    await progressWriter.append(eventId: 'e2', occurrenceId: 'o', quantity: 3);
    result = (await reader.find('o'))!;
    expect(result.progress.target, 5);
    expect(result.progress.total, 5);
    expect(result.progress.status, CounterProgressStatus.completed);
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_counter_events')
              .getSingle())
          .read<int>('n'),
      2,
    );
  });

  test(
    'reader rejects overflow in preexisting events instead of wrapping',
    () async {
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
        "INSERT INTO habit_counter_events VALUES ('e1', 'o', 9223372036854775807, 1), ('e2', 'o', 1, 2)",
      );
      await expectLater(CounterProgressReader(db).find('o'), throwsRangeError);
    },
  );
}
