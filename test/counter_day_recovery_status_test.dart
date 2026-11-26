import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_occurrence_store.dart';
import 'package:hibi/features/habits/data/counter_progress_writer.dart';
import 'package:hibi/features/habits/data/counter_recovery_store.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/domain/counter_day_status.dart';
import 'package:hibi/features/habits/domain/counter_recovery.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class MutableClock implements AppClock {
  MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  test('failed day stays failed on partial recovery and becomes recovered on full recovery without altering same-day or today totals', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 26, 10));
    await CounterHabitWriter(db, clock).create(
      habitId: 'h',
      versionId: 'v',
      auditId: 'a',
      lifecycleEventId: 'l',
      name: 'Quran Reading',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    await CounterOccurrenceStore(db).getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
      occurrenceId: 'o_nov26',
    );
    await CounterProgressWriter(
      db,
      clock,
    ).append(eventId: 'e1', occurrenceId: 'o_nov26', quantity: 2);
    await CounterResolutionWriter(db, clock).resolve(
      id: 'res1',
      occurrenceId: 'o_nov26',
      state: CounterResolutionState.failed,
    );

    final reader = CounterDayReader(db);
    var nov26 = await reader.evaluate(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
    );
    expect(nov26.effectiveStatus, CounterDayEffectiveStatus.failed);
    expect(nov26.recovery!.status, CounterRecoveryStatus.unrecovered);
    expect(nov26.recovery!.remainingDeficit, 3);

    clock.current = DateTime(2026, 11, 27, 9);
    final recoveryWriter = CounterRecoveryWriter(db, clock);
    await recoveryWriter.record(
      id: 'rec1',
      occurrenceId: 'o_nov26',
      quantity: 1,
    );

    nov26 = await reader.evaluate(habitId: 'h', date: LocalDate(2026, 11, 26));
    expect(nov26.effectiveStatus, CounterDayEffectiveStatus.failed);
    expect(nov26.recovery!.status, CounterRecoveryStatus.partiallyRecovered);
    expect(nov26.recovery!.recoveredTotal, 1);
    expect(nov26.recovery!.remainingDeficit, 2);
    expect(nov26.day.recorded!.progress.total, 2);
    expect(nov26.day.recoveries.length, 1);

    clock.current = DateTime(2026, 11, 27, 15);
    await recoveryWriter.record(
      id: 'rec2',
      occurrenceId: 'o_nov26',
      quantity: 2,
    );

    nov26 = await reader.evaluate(habitId: 'h', date: LocalDate(2026, 11, 26));
    expect(nov26.effectiveStatus, CounterDayEffectiveStatus.recovered);
    expect(nov26.recovery!.status, CounterRecoveryStatus.recovered);
    expect(nov26.recovery!.recoveredTotal, 3);
    expect(nov26.recovery!.remainingDeficit, 0);
    expect(nov26.day.recorded!.progress.total, 2);
    expect(nov26.day.resolution!.state, CounterResolutionState.failed);
    expect(nov26.day.recoveries.length, 2);

    final nov27 = await reader.evaluate(
      habitId: 'h',
      date: LocalDate(2026, 11, 27),
    );
    expect(nov27.effectiveStatus, CounterDayEffectiveStatus.pending);
    expect(nov27.hasOccurrence, isFalse);
  });

  test('contradictory raw-SQL recovery records report conflict while preserving all underlying entries', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 26, 10));
    await CounterHabitWriter(db, clock).create(
      habitId: 'h',
      versionId: 'v',
      auditId: 'a',
      lifecycleEventId: 'l',
      name: 'Read',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    await CounterOccurrenceStore(db).getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
      occurrenceId: 'o_excused',
    );
    await CounterResolutionWriter(db, clock).resolve(
      id: 'res_excused',
      occurrenceId: 'o_excused',
      state: CounterResolutionState.excused,
    );
    await db.customStatement(
      "INSERT INTO habit_counter_recoveries VALUES ('bad_excused', 'o_excused', '2026-11-27', 2, 5, 0, 3, NULL, 10)",
    );

    final reader = CounterDayReader(db);
    final excusedConflict = await reader.evaluate(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
    );
    expect(excusedConflict.effectiveStatus, CounterDayEffectiveStatus.conflict);
    expect(
      excusedConflict.day.resolution!.state,
      CounterResolutionState.excused,
    );
    expect(excusedConflict.day.recoveries.single.id, 'bad_excused');

    clock.current = DateTime(2026, 11, 27, 10);
    await CounterOccurrenceStore(db).getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 27),
      occurrenceId: 'o_same_date',
    );
    await CounterResolutionWriter(db, clock).resolve(
      id: 'res_failed',
      occurrenceId: 'o_same_date',
      state: CounterResolutionState.failed,
    );
    await db.customStatement(
      "INSERT INTO habit_counter_recoveries VALUES ('bad_date', 'o_same_date', '2026-11-27', 5, 5, 0, 0, NULL, 20)",
    );

    final sameDateConflict = await reader.evaluate(
      habitId: 'h',
      date: LocalDate(2026, 11, 27),
    );
    expect(
      sameDateConflict.effectiveStatus,
      CounterDayEffectiveStatus.conflict,
    );
    expect(sameDateConflict.day.recoveries.single.id, 'bad_date');
  });
}
