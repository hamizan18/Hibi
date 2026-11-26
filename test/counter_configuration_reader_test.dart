import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_configuration_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class MutableClock implements AppClock {
  MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  test('partitions prior, effective and future versions across dates and preserves lifecycle timeline', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 26, 9));
    final writer = CounterHabitWriter(db, clock);
    final reader = CounterConfigurationReader(db);

    await expectLater(
      reader.read(habitId: 'missing', asOfDate: LocalDate(2026, 11, 26)),
      throwsStateError,
    );

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
      name: 'Read Extended',
      effectiveDate: DateTime(2026, 12, 1),
      target: CounterTarget(count: 10, unit: 'pages'),
      schedule: WeekdaySchedule(
        start: LocalDate(2026, 12, 1),
        weekdays: {1, 3, 5},
      ),
    );
    clock.current = DateTime(2026, 12, 5, 9);
    await HabitLifecycleStore(db, clock).append(
      id: 'l2',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 12, 5),
      state: HabitLifecycleState.paused,
      reason: 'Holiday',
    );

    // Before start (Nov 25): v1 and v2 are both future versions
    final beforeStart = await reader.read(
      habitId: 'h',
      asOfDate: LocalDate(2026, 11, 25),
    );
    expect(
      beforeStart.applicability.reason,
      HabitApplicabilityReason.beforeStart,
    );
    expect(beforeStart.effectiveLifecycle, isNull);
    expect(beforeStart.effectiveVersion, isNull);
    expect(beforeStart.priorVersions, isEmpty);
    expect(beforeStart.futureVersions.map((v) => v.versionId), ['v1', 'v2']);
    expect(beforeStart.allVersions.length, 2);

    // On Nov 26: v1 is effective, v2 is future
    final onNov26 = await reader.read(
      habitId: 'h',
      asOfDate: LocalDate(2026, 11, 26),
    );
    expect(onNov26.applicability.reason, HabitApplicabilityReason.applicable);
    expect(onNov26.effectiveLifecycle!.state, HabitLifecycleState.active);
    expect(onNov26.effectiveVersion!.versionId, 'v1');
    expect(onNov26.effectiveVersion!.name, 'Read');
    expect(onNov26.effectiveVersion!.target!.count, 5);
    expect(onNov26.effectiveVersion!.schedule, isA<DailySchedule>());
    expect(onNov26.effectiveVersion!.isFullyConfigured, isTrue);
    expect(onNov26.priorVersions, isEmpty);
    expect(onNov26.futureVersions.map((v) => v.versionId), ['v2']);

    // On Dec 5: v1 is prior, v2 is effective, lifecycle is paused
    final onDec5 = await reader.read(
      habitId: 'h',
      asOfDate: LocalDate(2026, 12, 5),
    );
    expect(onDec5.applicability.reason, HabitApplicabilityReason.paused);
    expect(onDec5.effectiveLifecycle!.state, HabitLifecycleState.paused);
    expect(onDec5.effectiveLifecycle!.reason, 'Holiday');
    expect(onDec5.lifecycleHistory.map((e) => e.id), ['l1', 'l2']);
    expect(onDec5.priorVersions.map((v) => v.versionId), ['v1']);
    expect(onDec5.effectiveVersion!.versionId, 'v2');
    expect(onDec5.effectiveVersion!.target!.count, 10);
    expect(onDec5.effectiveVersion!.schedule, isA<WeekdaySchedule>());
    expect(onDec5.futureVersions, isEmpty);
  });

  test('legacy unconfigured versions leave target and schedule null without inventing defaults or writing rows', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement("INSERT INTO habits VALUES ('legacy', 100)");
    await db.customStatement(
      "INSERT INTO habit_versions VALUES ('lv1', 'legacy', 'Legacy Counter', '2026-11-26', NULL, 100, 1)",
    );

    final all = await CounterConfigurationReader(db)
        .readAll(asOfDate: LocalDate(2026, 11, 26));
    expect(all.length, 1);
    final config = all.single;
    expect(config.habitId, 'legacy');
    expect(config.applicability.applicability, HabitApplicability.unknown);
    expect(
      config.applicability.reason,
      HabitApplicabilityReason.missingLifecycle,
    );
    expect(config.effectiveVersion!.versionId, 'lv1');
    expect(config.effectiveVersion!.target, isNull);
    expect(config.effectiveVersion!.schedule, isNull);
    expect(config.effectiveVersion!.isFullyConfigured, isFalse);
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM habit_counter_targets')
              .getSingle())
          .read<int>('n'),
      0,
    );
  });
}
