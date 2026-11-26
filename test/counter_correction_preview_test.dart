import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_correction_preview.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_lifecycle_action_service.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/domain/counter_progress.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class MutableClock implements AppClock {
  MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  test('preview summarizes affected range, occurrence status changes and unavailable derived engines without writing rows', () async {
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
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    final actions = CounterTodayActionService(db, clock);
    await actions.recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o_26',
      eventId: 'e1',
      quantity: 6,
    );

    final previewer = CounterCorrectionPreviewer(db, clock);
    final preview = await previewer.preview(
      const CounterTargetCorrectionProposal(
        habitId: 'h',
        versionId: 'v1',
        proposedTargetCount: 10,
        proposedUnit: 'pages',
        reason: 'Increase target',
      ),
    );
    expect(preview.isUnboundedEnd, isTrue);
    expect(preview.originalTarget.count, 5);
    expect(preview.proposedTarget.count, 10);
    expect(preview.affectedOccurrences.length, 1);
    expect(
      preview.affectedOccurrences.single.originalProgressStatus,
      CounterProgressStatus.completed,
    );
    expect(
      preview.affectedOccurrences.single.proposedProgressStatus,
      CounterProgressStatus.partial,
    );
    expect(preview.totalAffectedEventCount, 1);
    expect(
      preview.scoreImpact,
      CounterDerivedImpactAvailability.notImplemented,
    );
    expect(
      preview.streakImpact,
      CounterDerivedImpactAvailability.notImplemented,
    );
    expect(
      preview.rewardImpact,
      CounterDerivedImpactAvailability.notImplemented,
    );
    expect(
      preview.achievementImpact,
      CounterDerivedImpactAvailability.notImplemented,
    );
    expect(
      preview.englishConfirmationSummary,
      contains('[2026-11-26, unbounded)'),
    );
    expect(await previewer.isStale(preview), isFalse);
  });

  test('detects stale previews on new events, lifecycle changes or local-day boundary and rejects incompatible units or resolution conflicts', () async {
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
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: LocalDate(2026, 11, 26)),
    );
    final actions = CounterTodayActionService(db, clock);
    await actions.recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o_26',
      eventId: 'e1',
      quantity: 3,
    );

    final previewer = CounterCorrectionPreviewer(db, clock);
    // Incompatible unit change is rejected
    await expectLater(
      previewer.preview(
        const CounterTargetCorrectionProposal(
          habitId: 'h',
          versionId: 'v1',
          proposedTargetCount: 10,
          proposedUnit: 'chapters',
        ),
      ),
      throwsArgumentError,
    );

    final preview = await previewer.preview(
      const CounterTargetCorrectionProposal(
        habitId: 'h',
        versionId: 'v1',
        proposedTargetCount: 10,
        proposedUnit: 'pages',
      ),
    );
    expect(await previewer.isStale(preview), isFalse);

    // Adding another event makes the preview stale
    await actions.recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o_26',
      eventId: 'e2',
      quantity: 1,
    );
    expect(await previewer.isStale(preview), isTrue);

    final freshPreview = await previewer.preview(
      const CounterTargetCorrectionProposal(
        habitId: 'h',
        versionId: 'v1',
        proposedTargetCount: 10,
        proposedUnit: 'pages',
      ),
    );
    expect(await previewer.isStale(freshPreview), isFalse);

    // Crossing midnight local-day boundary makes the preview stale
    clock.current = DateTime(2026, 11, 27, 0, 1);
    expect(await previewer.isStale(freshPreview), isTrue);

    final nov27Preview = await previewer.preview(
      const CounterTargetCorrectionProposal(
        habitId: 'h',
        versionId: 'v1',
        proposedTargetCount: 10,
        proposedUnit: 'pages',
      ),
    );
    expect(await previewer.isStale(nov27Preview), isFalse);

    // Pausing the habit changes the read-set snapshot and makes the preview stale
    await CounterLifecycleActionService(db, clock).pause(
      eventId: 'l_pause',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 27),
    );
    expect(await previewer.isStale(nov27Preview), isTrue);

    // Resolving o_26 as failed on Nov 26 (4/5) and proposing target 3 (<= 4) is rejected
    clock.current = DateTime(2026, 11, 28, 9);
    await CounterLifecycleActionService(db, clock).resume(
      eventId: 'l_resume',
      habitId: 'h',
      effectiveDate: LocalDate(2026, 11, 28),
    );
    await actions.recordTodayProgress(
      habitId: 'h',
      occurrenceId: 'o_28',
      eventId: 'e_28',
      quantity: 2,
    );
    await actions.resolveToday(
      habitId: 'h',
      occurrenceId: 'o_28',
      resolutionId: 'r_28',
      state: CounterResolutionState.failed,
    );
    await expectLater(
      previewer.preview(
        const CounterTargetCorrectionProposal(
          habitId: 'h',
          versionId: 'v1',
          proposedTargetCount: 2,
          proposedUnit: 'pages',
        ),
      ),
      throwsStateError,
    );
  });
}
