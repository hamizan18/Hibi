import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_day_roster_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
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
  test(
    'empty database returns an empty roster without writing records',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final roster = await CounterDayRosterReader(db)
          .readForDate(LocalDate(2026, 11, 26));
      expect(roster, isEmpty);
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
                .getSingle())
            .read<int>('n'),
        0,
      );
    },
  );

  test('evaluates multiple habits deterministically across pending, completed, recovered, paused, pre-start and unknown states without creating occurrences', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 26, 8));
    final writer = CounterHabitWriter(db, clock);

    await writer.create(
      habitId: 'h1_quran',
      versionId: 'v1_quran',
      auditId: 'a1_quran',
      lifecycleEventId: 'l1_quran',
      name: 'Quran Reading',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    await CounterOccurrenceStore(db).getOrCreate(
      habitId: 'h1_quran',
      date: LocalDate(2026, 11, 26),
      occurrenceId: 'o_quran_26',
    );
    await CounterProgressWriter(
      db,
      clock,
    ).append(eventId: 'e_quran_26', occurrenceId: 'o_quran_26', quantity: 2);
    await CounterResolutionWriter(db, clock).resolve(
      id: 'r_quran_26',
      occurrenceId: 'o_quran_26',
      state: CounterResolutionState.failed,
    );

    clock.current = DateTime(2026, 11, 26, 9);
    await writer.create(
      habitId: 'h2_pushup',
      versionId: 'v1_pushup',
      auditId: 'a1_pushup',
      lifecycleEventId: 'l1_pushup',
      name: 'Push Up',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 10, unit: 'repetitions'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );

    clock.current = DateTime(2026, 11, 26, 10);
    await writer.create(
      habitId: 'h3_future',
      versionId: 'v1_future',
      auditId: 'a1_future',
      lifecycleEventId: 'l1_future',
      name: 'Future Habit',
      effectiveDate: DateTime(2026, 12, 1),
      target: CounterTarget(count: 3, unit: 'sessions'),
      schedule: DailySchedule(start: LocalDate(2026, 12, 1)),
    );

    await db.customStatement(
      "INSERT INTO habits VALUES ('h4_legacy', 9999999999999999)",
    );
    await db.customStatement(
      "INSERT INTO habit_versions VALUES ('v1_legacy', 'h4_legacy', 'Legacy Counter', '2026-11-26', NULL, 9999999999999999, 1)",
    );

    clock.current = DateTime(2026, 11, 27, 10);
    await CounterRecoveryWriter(
      db,
      clock,
    ).record(id: 'rec_quran', occurrenceId: 'o_quran_26', quantity: 3);
    await HabitLifecycleStore(db, clock).append(
      id: 'pause_pushup',
      habitId: 'h2_pushup',
      effectiveDate: LocalDate(2026, 11, 27),
      state: HabitLifecycleState.paused,
    );
    await writer.scheduleVersion(
      habitId: 'h1_quran',
      versionId: 'v2_quran',
      auditId: 'a2_quran',
      name: 'Quran Reading Extended',
      effectiveDate: DateTime(2026, 11, 28),
      target: CounterTarget(count: 10, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 28)),
    );

    final rosterReader = CounterDayRosterReader(db);
    final nov26Roster = await rosterReader.readForDate(LocalDate(2026, 11, 26));
    expect(nov26Roster.map((item) => item.habitId), [
      'h1_quran',
      'h2_pushup',
      'h3_future',
      'h4_legacy',
    ]);
    expect(nov26Roster[0].name, 'Quran Reading');
    expect(nov26Roster[0].revision, 1);
    expect(
      nov26Roster[0].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.recovered,
    );
    expect(nov26Roster[0].evaluation.day.recorded!.progress.total, 2);
    expect(nov26Roster[0].evaluation.recovery!.recoveredTotal, 3);

    expect(nov26Roster[1].name, 'Push Up');
    expect(
      nov26Roster[1].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.pending,
    );
    expect(nov26Roster[1].evaluation.hasOccurrence, isFalse);
    expect(nov26Roster[1].evaluation.configuredTarget!.count, 10);

    expect(nov26Roster[2].versionId, isNull);
    expect(nov26Roster[2].name, isNull);
    expect(
      nov26Roster[2].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.notApplicable,
    );

    expect(nov26Roster[3].name, 'Legacy Counter');
    expect(
      nov26Roster[3].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.unknown,
    );

    final nov27Roster = await rosterReader.readForDate(LocalDate(2026, 11, 27));
    expect(
      nov27Roster[0].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.pending,
    );
    expect(nov27Roster[0].evaluation.hasOccurrence, isFalse);
    expect(
      nov27Roster[1].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.notApplicable,
    );

    final nov28Roster = await rosterReader.readForDate(LocalDate(2026, 11, 28));
    expect(nov28Roster[0].name, 'Quran Reading Extended');
    expect(nov28Roster[0].revision, 2);
    expect(nov28Roster[0].evaluation.configuredTarget!.count, 10);
    expect(
      nov28Roster[0].evaluation.effectiveStatus,
      CounterDayEffectiveStatus.pending,
    );

    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_occurrences')
              .getSingle())
          .read<int>('n'),
      1,
    );
  });
}
