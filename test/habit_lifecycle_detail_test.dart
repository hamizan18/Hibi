import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/data/habit_schedule_store.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 1, 9);
}

void main() {
  test('HabitLifecycleReader reads effective state on date and full transition history', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final reader = HabitLifecycleReader(db);
    await expectLater(
      reader.findEffectiveOn('missing', LocalDate(2026, 11, 1)),
      throwsStateError,
    );
    await expectLater(reader.readHistory('missing'), throwsStateError);

    await db.customStatement("INSERT INTO habits VALUES ('h', 1)");
    expect(await reader.findEffectiveOn('h', LocalDate(2026, 11, 1)), isNull);
    expect(await reader.readHistory('h'), isEmpty);

    final store = HabitLifecycleStore(db, FixedClock());
    await store.append(
      id: 'e1',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 2),
      state: HabitLifecycleState.scheduled,
      reason: 'Planned start',
    );
    await store.append(
      id: 'e2',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 5),
      state: HabitLifecycleState.active,
      reason: 'Began routine',
    );
    await store.append(
      id: 'e3',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 8),
      state: HabitLifecycleState.paused,
      reason: 'Travel',
    );

    expect(await reader.findEffectiveOn('h', LocalDate(2026, 11, 1)), isNull);
    final onNov3 = await reader.findEffectiveOn('h', LocalDate(2026, 11, 3));
    expect(onNov3!.id, 'e1');
    expect(onNov3.previousState, isNull);
    expect(onNov3.state, HabitLifecycleState.scheduled);
    expect(onNov3.reason, 'Planned start');

    final onNov6 = await reader.findEffectiveOn('h', LocalDate(2026, 11, 6));
    expect(onNov6!.id, 'e2');
    expect(onNov6.previousState, HabitLifecycleState.scheduled);
    expect(onNov6.state, HabitLifecycleState.active);

    final history = await reader.readHistory('h');
    expect(history.map((e) => e.id), ['e1', 'e2', 'e3']);
    expect(history[2].previousState, HabitLifecycleState.active);
    expect(history[2].state, HabitLifecycleState.paused);
    expect(history[2].reason, 'Travel');
  });

  test('HabitApplicabilityReader.describe distinguishes every notApplicable, unknown and applicable reason', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final applicability = HabitApplicabilityReader(db);
    final store = HabitLifecycleStore(db, FixedClock());

    await db.customStatement("INSERT INTO habits VALUES ('h', 1)");
    final noVersions = await applicability.describe(
      'h',
      LocalDate(2026, 11, 5),
    );
    expect(noVersions.applicability, HabitApplicability.unknown);
    expect(noVersions.reason, HabitApplicabilityReason.missingVersions);

    await db.customStatement(
      "INSERT INTO habit_versions VALUES ('v1', 'h', 'Read', '2026-11-05', '2026-11-15', 1, 1)",
    );
    final beforeStart = await applicability.describe(
      'h',
      LocalDate(2026, 11, 4),
    );
    expect(beforeStart.applicability, HabitApplicability.notApplicable);
    expect(beforeStart.reason, HabitApplicabilityReason.beforeStart);

    final noLifecycle = await applicability.describe(
      'h',
      LocalDate(2026, 11, 5),
    );
    expect(noLifecycle.applicability, HabitApplicability.unknown);
    expect(noLifecycle.reason, HabitApplicabilityReason.missingLifecycle);

    await store.append(
      id: 's',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 5),
      state: HabitLifecycleState.scheduled,
    );
    final scheduled = await applicability.describe('h', LocalDate(2026, 11, 5));
    expect(scheduled.applicability, HabitApplicability.notApplicable);
    expect(scheduled.reason, HabitApplicabilityReason.scheduled);
    expect(scheduled.lifecycleState, HabitLifecycleState.scheduled);

    await store.append(
      id: 'a',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 6),
      state: HabitLifecycleState.active,
    );
    final missingSchedule = await applicability.describe(
      'h',
      LocalDate(2026, 11, 6),
    );
    expect(missingSchedule.applicability, HabitApplicability.unknown);
    expect(missingSchedule.reason, HabitApplicabilityReason.missingSchedule);
    expect(missingSchedule.versionId, 'v1');

    await HabitScheduleStore(db).insert(
      'v1',
      WeekdaySchedule(start: LocalDate(2026, 11, 5), weekdays: {5}),
    );
    // Nov 6, 2026 is Friday (ISO weekday 5)
    final applicable = await applicability.describe(
      'h',
      LocalDate(2026, 11, 6),
    );
    expect(applicable.applicability, HabitApplicability.applicable);
    expect(applicable.reason, HabitApplicabilityReason.applicable);
    expect(applicable.versionId, 'v1');

    // Nov 7, 2026 is Saturday (ISO weekday 6)
    final unscheduled = await applicability.describe(
      'h',
      LocalDate(2026, 11, 7),
    );
    expect(unscheduled.applicability, HabitApplicability.notApplicable);
    expect(unscheduled.reason, HabitApplicabilityReason.unscheduled);
    expect(unscheduled.versionId, 'v1');

    // Nov 15, 2026 is after v1 effective_end ('2026-11-15') with active lifecycle
    final versionGap = await applicability.describe(
      'h',
      LocalDate(2026, 11, 15),
    );
    expect(versionGap.applicability, HabitApplicability.unknown);
    expect(versionGap.reason, HabitApplicabilityReason.missingActiveVersion);

    await store.append(
      id: 'p',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 8),
      state: HabitLifecycleState.paused,
    );
    await store.append(
      id: 'ar',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 9),
      state: HabitLifecycleState.archived,
    );
    await store.append(
      id: 'd',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 10),
      state: HabitLifecycleState.deleted,
    );
    expect(
      (await applicability.describe('h', LocalDate(2026, 11, 8))).reason,
      HabitApplicabilityReason.paused,
    );
    expect(
      (await applicability.describe('h', LocalDate(2026, 11, 9))).reason,
      HabitApplicabilityReason.archived,
    );
    expect(
      (await applicability.describe('h', LocalDate(2026, 11, 10))).reason,
      HabitApplicabilityReason.deleted,
    );
  });
}
