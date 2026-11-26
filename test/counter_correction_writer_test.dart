import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_correction_preview.dart';
import 'package:hibi/features/habits/data/counter_correction_writer.dart';
import 'package:hibi/features/habits/data/counter_day_reader.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
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
  test('confirmed correction updates version target, occurrence snapshots and preimage audit atomically while leaving source events and other versions untouched', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 26, 9));
    final writer = CounterHabitWriter(db, clock);
    await writer.create(
      habitId: 'h',
      versionId: 'v1',
      auditId: 'a1',
      lifecycleEventId: 'l1',
      name: 'Read',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 10, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    await writer.scheduleVersion(
      habitId: 'h',
      versionId: 'v2',
      auditId: 'a2',
      name: 'Read Dec',
      effectiveDate: DateTime(2026, 12, 1),
      target: CounterTarget(count: 20, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 12, 1)),
    );

    final actions = CounterTodayActionService(db, clock);
    // Nov 26: 5 pages recorded (partial against 10, completed against 5)
    await actions.recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o_26',
      eventId: 'e1',
      quantity: 2,
    );
    await actions.recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o_26',
      eventId: 'e2',
      quantity: 3,
    );

    final previewer = CounterCorrectionPreviewer(db, clock);
    final preview = await previewer.preview(
      const CounterTargetCorrectionProposal(
        habitId: 'h',
        versionId: 'v1',
        proposedTargetCount: 5,
        proposedUnit: 'pages',
        reason: 'Correct initial target typo',
      ),
    );

    final correctionWriter = CounterCorrectionWriter(db, clock);
    await correctionWriter.commit(
      correctionAuditId: 'corr_1',
      confirmedPreview: preview,
    );

    // Re-committing the same preview fails as stale
    await expectLater(
      correctionWriter.commit(
        correctionAuditId: 'corr_duplicate',
        confirmedPreview: preview,
      ),
      throwsStateError,
    );

    // Nov 26 occurrence now evaluates to completed (5/5) while preserving 2 + 3 events
    final nov26 = await CounterDayReader(db)
        .evaluate(habitId: 'h', date: LocalDate(2026, 11, 26));
    expect(nov26.effectiveStatus, CounterDayEffectiveStatus.completed);
    expect(nov26.day.recorded!.progress.target, 5);
    expect(nov26.day.recorded!.progress.total, 5);

    // v2 remains untouched at target 20
    final dec1 = await CounterDayReader(db)
        .evaluate(habitId: 'h', date: LocalDate(2026, 12, 1));
    expect(dec1.configuredTarget!.count, 20);

    // Audit record preserves full preimage and postimage and is immutable
    final audits = await correctionWriter.readAuditsForHabit('h');
    expect(audits.length, 1);
    expect(audits.single.previousTargetCount, 10);
    expect(audits.single.updatedTargetCount, 5);
    expect(audits.single.reason, 'Correct initial target typo');
    expect(audits.single.beforeSnapshot['target_count'], 10);
    expect(audits.single.afterSnapshot['target_count'], 5);

    // Direct SQL updates to target or occurrence are still blocked by triggers
    await expectLater(
      db.customStatement(
        "UPDATE habit_counter_targets SET target_count = 99 WHERE habit_version_id = 'v1'",
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      db.customStatement(
        "UPDATE habit_occurrences SET target_count = 99 WHERE id = 'o_26'",
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      db.customStatement(
        "DELETE FROM habit_counter_correction_audit WHERE id = 'corr_1'",
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('stale preview or injected audit failure rolls back target, occurrence snapshots and protection triggers', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 26, 9));
    await CounterHabitWriter(db, clock).create(
      habitId: 'h',
      versionId: 'v1',
      auditId: 'a1',
      lifecycleEventId: 'l1',
      name: 'Read',
      effectiveDate: DateTime(2026, 11, 26),
      target: CounterTarget(count: 10, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    await CounterTodayActionService(db, clock).recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o_26',
      eventId: 'e1',
      quantity: 4,
    );

    final previewer = CounterCorrectionPreviewer(db, clock);
    final preview = await previewer.preview(
      const CounterTargetCorrectionProposal(
        habitId: 'h',
        versionId: 'v1',
        proposedTargetCount: 5,
        proposedUnit: 'pages',
      ),
    );

    await db.customStatement(
      "CREATE TRIGGER fail_corr_audit BEFORE INSERT ON habit_counter_correction_audit WHEN NEW.id = 'fail' BEGIN SELECT RAISE(ABORT, 'injected'); END",
    );
    final correctionWriter = CounterCorrectionWriter(db, clock);
    await expectLater(
      correctionWriter.commit(
        correctionAuditId: 'fail',
        confirmedPreview: preview,
      ),
      throwsA(isA<Exception>()),
    );

    // Target and occurrence snapshot remain 10, and protection triggers remain active
    final nov26 = await CounterDayReader(db)
        .evaluate(habitId: 'h', date: LocalDate(2026, 11, 26));
    expect(nov26.day.recorded!.progress.target, 10);
    expect(await correctionWriter.readAuditsForHabit('h'), isEmpty);
    await expectLater(
      db.customStatement(
        "UPDATE habit_counter_targets SET target_count = 5 WHERE habit_version_id = 'v1'",
      ),
      throwsA(isA<Exception>()),
    );
  });
}
