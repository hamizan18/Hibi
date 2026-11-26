import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_history_reader.dart';
import 'package:hibi/features/habits/data/counter_occurrence_store.dart';
import 'package:hibi/features/habits/data/counter_progress_writer.dart';
import 'package:hibi/features/habits/data/counter_recovery_store.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/domain/counter_day_status.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class MutableClock implements AppClock {
  MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  test('rejects inverted date ranges and nonexistent habits', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final reader = CounterHistoryReader(db);
    expect(
      () => reader.readRange(
        habitId: 'missing',
        startInclusive: LocalDate(2026, 11, 27),
        endInclusive: LocalDate(2026, 11, 26),
      ),
      throwsArgumentError,
    );
    await expectLater(
      reader.readRange(
        habitId: 'missing',
        startInclusive: LocalDate(2026, 11, 26),
        endInclusive: LocalDate(2026, 11, 26),
      ),
      throwsStateError,
    );
    await expectLater(
      reader.findRecoverableDeficits(
        habitId: 'missing',
        asOfDate: LocalDate(2026, 11, 26),
      ),
      throwsStateError,
    );
  });

  test('readRange evaluates inclusive intervals across pre-start, version changes, month boundary and pause without creating occurrences', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 28, 9));
    final writer = CounterHabitWriter(db, clock);

    await writer.create(
      habitId: 'h',
      versionId: 'v1',
      auditId: 'a1',
      lifecycleEventId: 'l1',
      name: 'Read',
      effectiveDate: DateTime(2026, 11, 28),
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 28)),
    );
    await CounterOccurrenceStore(db).getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 28),
      occurrenceId: 'o_28',
    );
    await CounterProgressWriter(
      db,
      clock,
    ).append(eventId: 'e_28', occurrenceId: 'o_28', quantity: 5);

    await writer.scheduleVersion(
      habitId: 'h',
      versionId: 'v2',
      auditId: 'a2',
      name: 'Read More',
      effectiveDate: DateTime(2026, 12, 1),
      target: CounterTarget(count: 10, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 12, 1)),
    );
    clock.current = DateTime(2026, 12, 2, 9);
    await HabitLifecycleStore(db, clock).append(
      id: 'pause',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 12, 2),
      state: HabitLifecycleState.paused,
    );

    final history = await CounterHistoryReader(db).readRange(
      habitId: 'h',
      startInclusive: LocalDate(2026, 11, 27),
      endInclusive: LocalDate(2026, 12, 2),
    );
    expect(history.length, 6);

    expect(history[0].date.compareTo(LocalDate(2026, 11, 27)), 0);
    expect(history[0].versionId, isNull);
    expect(
      history[0].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.notApplicable,
    );

    expect(history[1].date.compareTo(LocalDate(2026, 11, 28)), 0);
    expect(history[1].name, 'Read');
    expect(
      history[1].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.completed,
    );

    expect(history[2].date.compareTo(LocalDate(2026, 11, 29)), 0);
    expect(
      history[2].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.pending,
    );
    expect(history[2].evaluation.hasOccurrence, isFalse);
    expect(history[2].evaluation.configuredTarget!.count, 5);

    expect(history[3].date.compareTo(LocalDate(2026, 11, 30)), 0);
    expect(
      history[3].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.pending,
    );

    expect(history[4].date.compareTo(LocalDate(2026, 12, 1)), 0);
    expect(history[4].name, 'Read More');
    expect(history[4].revision, 2);
    expect(history[4].evaluation.configuredTarget!.count, 10);
    expect(
      history[4].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.pending,
    );

    expect(history[5].date.compareTo(LocalDate(2026, 12, 2)), 0);
    expect(
      history[5].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.notApplicable,
    );

    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
              .getSingle())
          .read<int>('n'),
      1,
    );
  });

  test('findRecoverableDeficits returns only prior failed occurrences with positive remaining deficits while habit is active', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 24, 9));
    await CounterHabitWriter(db, clock).create(
      habitId: 'h',
      versionId: 'v1',
      auditId: 'a1',
      lifecycleEventId: 'l1',
      name: 'Quran Reading',
      effectiveDate: DateTime(2026, 11, 24),
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 24)),
    );

    // Nov 24: failed with 2/5, fully recovered on Nov 25
    await CounterOccurrenceStore(db).getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 24),
      occurrenceId: 'o_24',
    );
    await CounterProgressWriter(
      db,
      clock,
    ).append(eventId: 'e_24', occurrenceId: 'o_24', quantity: 2);
    await CounterResolutionWriter(db, clock).resolve(
      id: 'r_24',
      occurrenceId: 'o_24',
      state: CounterResolutionState.failed,
    );

    // Nov 25: failed with 1/5, partially recovered (+2 -> remaining 2) on Nov 26
    clock.current = DateTime(2026, 11, 25, 9);
    await CounterRecoveryWriter(
      db,
      clock,
    ).record(id: 'rec_24', occurrenceId: 'o_24', quantity: 3);
    await CounterOccurrenceStore(db).getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 25),
      occurrenceId: 'o_25',
    );
    await CounterProgressWriter(
      db,
      clock,
    ).append(eventId: 'e_25', occurrenceId: 'o_25', quantity: 1);
    await CounterResolutionWriter(db, clock).resolve(
      id: 'r_25',
      occurrenceId: 'o_25',
      state: CounterResolutionState.failed,
    );

    // Nov 26: excused with 0/5
    clock.current = DateTime(2026, 11, 26, 9);
    await CounterRecoveryWriter(
      db,
      clock,
    ).record(id: 'rec_25', occurrenceId: 'o_25', quantity: 2);
    await CounterOccurrenceStore(db).getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
      occurrenceId: 'o_26',
    );
    await CounterResolutionWriter(db, clock).resolve(
      id: 'r_26',
      occurrenceId: 'o_26',
      state: CounterResolutionState.excused,
    );

    // Nov 27: failed with 0/5, unrecovered
    clock.current = DateTime(2026, 11, 27, 9);
    await CounterOccurrenceStore(db).getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 27),
      occurrenceId: 'o_27',
    );
    await CounterResolutionWriter(db, clock).resolve(
      id: 'r_27',
      occurrenceId: 'o_27',
      state: CounterResolutionState.failed,
    );

    final reader = CounterHistoryReader(db);
    final deficitsOnNov27 = await reader.findRecoverableDeficits(
      habitId: 'h',
      asOfDate: LocalDate(2026, 11, 27),
    );
    // On Nov 27, o_27 is same-day (not prior), so only o_25 is prior and recoverable
    expect(deficitsOnNov27.map((d) => d.occurrenceId), ['o_25']);
    expect(deficitsOnNov27.single.recordedTotal, 1);
    expect(deficitsOnNov27.single.recoveredTotal, 2);
    expect(deficitsOnNov27.single.remainingDeficit, 2);

    final deficitsOnNov28 = await reader.findRecoverableDeficits(
      habitId: 'h',
      asOfDate: LocalDate(2026, 11, 28),
    );
    expect(deficitsOnNov28.map((d) => d.occurrenceId), ['o_25', 'o_27']);
    expect(deficitsOnNov28[0].remainingDeficit, 2);
    expect(deficitsOnNov28[1].remainingDeficit, 5);

    clock.current = DateTime(2026, 11, 29, 9);
    await HabitLifecycleStore(db, clock).append(
      id: 'pause',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 29),
      state: HabitLifecycleState.paused,
    );
    final deficitsWhilePaused = await reader.findRecoverableDeficits(
      habitId: 'h',
      asOfDate: LocalDate(2026, 11, 29),
    );
    expect(deficitsWhilePaused, isEmpty);
  });
}
