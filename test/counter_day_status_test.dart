import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_occurrence_store.dart';
import 'package:hibi/features/habits/data/counter_progress_writer.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/domain/counter_day_status.dart';
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
  test('applicable day without occurrence is pending when target is configured and performs no writes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await createHabit(db);
    final reader = CounterDayReader(db);
    final evaluation = await reader.evaluate(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
    );
    expect(evaluation.effectiveStatus, CounterDayEffectiveStatus.pending);
    expect(evaluation.hasOccurrence, isFalse);
    expect(evaluation.day.occurrenceId, isNull);
    expect(evaluation.day.recorded, isNull);
    expect(evaluation.configuredTarget?.count, 5);
    expect(evaluation.configuredTarget?.unit, 'pages');
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
              .getSingle())
          .read<int>('n'),
      0,
    );
  });

  test('not applicable and unknown dates without records never infer pending or failure', () async {
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
      final evaluation = await reader.evaluate(habitId: 'h', date: date);
      expect(
        evaluation.effectiveStatus,
        CounterDayEffectiveStatus.notApplicable,
      );
      expect(evaluation.hasOccurrence, isFalse);
    }

    await db.customStatement("INSERT INTO habits VALUES ('legacy', 1)");
    await db.customStatement(
      "INSERT INTO habit_versions VALUES ('lv', 'legacy', 'Legacy', '2026-11-26', NULL, 1, 1)",
    );
    final unknown = await reader.evaluate(
      habitId: 'legacy',
      date: LocalDate(2026, 11, 26),
    );
    expect(unknown.effectiveStatus, CounterDayEffectiveStatus.unknown);
    expect(unknown.hasOccurrence, isFalse);

    await db.customStatement(
      "INSERT INTO habit_schedules VALUES ('lv', 'daily', '2026-11-26', NULL, NULL)",
    );
    await db.customStatement(
      "INSERT INTO habit_lifecycle_events VALUES ('ll', 'legacy', '2026-11-26', NULL, 'active', NULL, 1)",
    );
    final missingTarget = await reader.evaluate(
      habitId: 'legacy',
      date: LocalDate(2026, 11, 26),
    );
    expect(missingTarget.day.applicability, HabitApplicability.applicable);
    expect(missingTarget.configuredTarget, isNull);
    expect(missingTarget.effectiveStatus, CounterDayEffectiveStatus.unknown);
  });

  test('occurrence transitions across pending, partial, completed, failed and excused', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await createHabit(db);
    await CounterOccurrenceStore(db).getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
      occurrenceId: 'o',
    );
    final reader = CounterDayReader(db);
    var evaluation = await reader.evaluate(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
    );
    expect(evaluation.effectiveStatus, CounterDayEffectiveStatus.pending);
    expect(evaluation.hasOccurrence, isTrue);
    expect(
      evaluation.day.recorded!.progress.status,
      CounterProgressStatus.pending,
    );

    final progressWriter = CounterProgressWriter(db, FixedClock());
    await progressWriter.append(eventId: 'e1', occurrenceId: 'o', quantity: 2);
    evaluation = await reader.evaluate(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
    );
    expect(evaluation.effectiveStatus, CounterDayEffectiveStatus.partial);
    expect(evaluation.day.recorded!.progress.total, 2);

    await progressWriter.append(eventId: 'e2', occurrenceId: 'o', quantity: 3);
    evaluation = await reader.evaluate(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
    );
    expect(evaluation.effectiveStatus, CounterDayEffectiveStatus.completed);
    expect(evaluation.day.recorded!.progress.total, 5);

    for (final state in CounterResolutionState.values) {
      final hId = 'h_${state.name}';
      final vId = 'v_${state.name}';
      final oId = 'o_${state.name}';
      await CounterHabitWriter(db, FixedClock()).create(
        habitId: hId,
        versionId: vId,
        auditId: 'a_${state.name}',
        lifecycleEventId: 'l_${state.name}',
        name: 'Habit ${state.name}',
        effectiveDate: DateTime(2026, 11, 26),
        target: CounterTarget(count: 5, unit: 'pages'),
        schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
      );
      await CounterOccurrenceStore(db).getOrCreate(
        habitId: hId,
        date: LocalDate(2026, 11, 26),
        occurrenceId: oId,
      );
      await progressWriter.append(
        eventId: 'ev_${state.name}',
        occurrenceId: oId,
        quantity: 2,
      );
      await CounterResolutionWriter(db, FixedClock()).resolve(
        id: 'r_${state.name}',
        occurrenceId: oId,
        state: state,
        reason: 'Explicit ${state.name}',
      );
      final resolved = await reader.evaluate(
        habitId: hId,
        date: LocalDate(2026, 11, 26),
      );
      expect(
        resolved.effectiveStatus,
        state == CounterResolutionState.failed
            ? CounterDayEffectiveStatus.failed
            : CounterDayEffectiveStatus.excused,
      );
      expect(resolved.day.recorded!.progress.total, 2);
      expect(resolved.day.resolution!.reason, 'Explicit ${state.name}');
    }
  });

  test('contradictory historical records report conflict without hiding underlying data', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final reader = CounterDayReader(db);

    await db.customStatement("INSERT INTO habits VALUES ('u', 1)");
    await db.customStatement(
      "INSERT INTO habit_versions VALUES ('uv', 'u', 'Unknown', '2026-11-26', NULL, 1, 1)",
    );
    await db.customStatement(
      "INSERT INTO habit_counter_targets VALUES ('uv', 5, 'pages')",
    );
    await db.customStatement(
      "INSERT INTO habit_occurrences VALUES ('uo', 'u', 'uv', '2026-11-26', 5, 'pages')",
    );
    await db.customStatement(
      "INSERT INTO habit_counter_events VALUES ('ue', 'uo', 3, 1)",
    );
    final unknownWithRecord = await reader.evaluate(
      habitId: 'u',
      date: LocalDate(2026, 11, 26),
    );
    expect(
      unknownWithRecord.effectiveStatus,
      CounterDayEffectiveStatus.conflict,
    );
    expect(unknownWithRecord.day.applicability, HabitApplicability.unknown);
    expect(unknownWithRecord.day.occurrenceId, 'uo');
    expect(unknownWithRecord.day.recorded!.progress.total, 3);

    await db.customStatement("INSERT INTO habits VALUES ('p', 1)");
    await db.customStatement(
      "INSERT INTO habit_versions VALUES ('pv', 'p', 'Paused', '2026-11-26', NULL, 1, 1)",
    );
    await db.customStatement(
      "INSERT INTO habit_counter_targets VALUES ('pv', 5, 'pages')",
    );
    await db.customStatement(
      "INSERT INTO habit_schedules VALUES ('pv', 'daily', '2026-11-26', NULL, NULL)",
    );
    await db.customStatement(
      "INSERT INTO habit_lifecycle_events VALUES ('pl', 'p', '2026-11-25', NULL, 'paused', NULL, 1)",
    );
    await db.customStatement(
      "INSERT INTO habit_occurrences VALUES ('po', 'p', 'pv', '2026-11-26', 5, 'pages')",
    );
    final notApplicableWithRecord = await reader.evaluate(
      habitId: 'p',
      date: LocalDate(2026, 11, 26),
    );
    expect(
      notApplicableWithRecord.effectiveStatus,
      CounterDayEffectiveStatus.conflict,
    );
    expect(
      notApplicableWithRecord.day.applicability,
      HabitApplicability.notApplicable,
    );
    expect(notApplicableWithRecord.day.occurrenceId, 'po');
    expect(
      notApplicableWithRecord.day.recorded!.progress.status,
      CounterProgressStatus.pending,
    );

    await createHabit(db);
    await CounterOccurrenceStore(db).getOrCreate(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
      occurrenceId: 'o',
    );
    await CounterProgressWriter(
      db,
      FixedClock(),
    ).append(eventId: 'e1', occurrenceId: 'o', quantity: 2);
    await CounterResolutionWriter(
      db,
      FixedClock(),
    ).resolve(id: 'r', occurrenceId: 'o', state: CounterResolutionState.failed);
    await db.customStatement(
      "INSERT INTO habit_counter_events VALUES ('raw_e2', 'o', 3, 2)",
    );
    final mismatchedResolution = await reader.evaluate(
      habitId: 'h',
      date: LocalDate(2026, 11, 26),
    );
    expect(
      mismatchedResolution.effectiveStatus,
      CounterDayEffectiveStatus.conflict,
    );
    expect(mismatchedResolution.day.recorded!.progress.total, 5);
    expect(mismatchedResolution.day.resolution!.progress, 2);
    expect(
      mismatchedResolution.day.resolution!.state,
      CounterResolutionState.failed,
    );
  });
}
