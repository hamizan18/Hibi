import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/counter_correction_preview.dart';
import 'package:hibi/features/habits/data/counter_correction_writer.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_lifecycle_action_service.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_analytics_reader.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_analytics.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as path;

class AcceptanceClock implements AppClock {
  DateTime current = DateTime(2026, 11, 24, 9);
  @override
  DateTime now() => current;
}

void main() {
  test('Milestone 2 acceptance (T-006): deterministic weighted score, recording coverage, exclusions, explicit No Data, streaks across paused/excused dates and historical correction recalculation survive disk restart', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'hibi_m2_acceptance_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final dbFile = File(path.join(tempDir.path, 'hibi_m2.sqlite'));
    final clock = AcceptanceClock();

    final db1 = AppDatabase(NativeDatabase(dbFile));
    try {
      // Habit 1: Quran Reading (Critical weight 4, recovery enabled) starting Nov 24
      await CounterHabitWriter(db1, clock).create(
        habitId: 'h_quran',
        versionId: 'v_q1',
        auditId: 'a_q1',
        lifecycleEventId: 'l_q1',
        name: 'Quran Reading',
        effectiveDate: DateTime(2026, 11, 24),
        target: CounterTarget(count: 10, unit: 'pages'),
        schedule: DailySchedule(start: LocalDate(2026, 11, 24)),
      );
      await HabitMetadataStore(db1).insert(
        'v_q1',
        HabitMetadata(
          category: 'Spiritual',
          priority: HabitPriority.critical,
          isPrivate: false,
          recoveryEnabled: true,
        ),
      );

      final actions = CounterTodayActionService(db1, clock);

      // Nov 24: log 4/10 pages and resolve as failed
      await actions.recordTodayProgress(
        habitId: 'h_quran',
        occurrenceId: 'occ_24',
        eventId: 'ev_24',
        quantity: 4,
      );
      await actions.resolveToday(
        habitId: 'h_quran',
        occurrenceId: 'occ_24',
        resolutionId: 'res_24',
        state: CounterResolutionState.failed,
        reason: 'Late evening',
      );

      // Schedule v_q2 starting Nov 25 with target 10 pages
      await CounterHabitWriter(db1, clock).scheduleVersion(
        habitId: 'h_quran',
        versionId: 'v_q2',
        auditId: 'a_q2',
        name: 'Quran Reading',
        effectiveDate: DateTime(2026, 11, 25),
        target: CounterTarget(count: 10, unit: 'pages'),
        schedule: DailySchedule(start: LocalDate(2026, 11, 25)),
        metadata: HabitMetadata(
          category: 'Spiritual',
          priority: HabitPriority.critical,
          isPrivate: false,
          recoveryEnabled: true,
        ),
      );

      // Nov 25: recover Nov 24 deficit (+6 pages) AND log 5/10 pages on Nov 25 (partial: 50%)
      clock.current = DateTime(2026, 11, 25, 9);
      await actions.recoverPriorDeficit(
        recoveryId: 'rec_24',
        occurrenceId: 'occ_24',
        quantity: 6,
        note: 'Recovered next morning',
      );
      await actions.recordTodayProgress(
        habitId: 'h_quran',
        occurrenceId: 'occ_25',
        eventId: 'ev_25',
        quantity: 5,
      );

      // Schedule pause on Nov 26 and resume on Nov 27
      final lifecycle = CounterLifecycleActionService(db1, clock);
      await lifecycle.pause(
        eventId: 'l_pause_26',
        habitId: 'h_quran',
        effectiveDate: LocalDate(2026, 11, 26),
      );
      await lifecycle.resume(
        eventId: 'l_resume_27',
        habitId: 'h_quran',
        effectiveDate: LocalDate(2026, 11, 27),
      );

      // Advance to Nov 27 (pending today) and inspect analytics BEFORE correction
      clock.current = DateTime(2026, 11, 27, 9);
      final reportBefore = await AnalyticsReportReader(db1).readPeriodReport(
        startInclusive: LocalDate(2026, 11, 23),
        endInclusive: LocalDate(2026, 11, 27),
        filter: const HabitAnalyticsFilter(includePrivate: false),
      );
      // Nov 23 (pre-start): No Data
      expect(
        reportBefore.dailyCells[0].scoreSummary.availability,
        ScoreAvailability.noData,
      );
      // Nov 24 (recovered): 75.0%
      expect(
        reportBefore.dailyCells[1].scoreSummary.weightedScorePercent,
        closeTo(75.0, 0.001),
      );
      // Nov 25 (partial 5/10): 50.0%
      expect(
        reportBefore.dailyCells[2].scoreSummary.weightedScorePercent,
        closeTo(50.0, 0.001),
      );
      // Nov 26 (paused): No Data
      expect(
        reportBefore.dailyCells[3].scoreSummary.availability,
        ScoreAvailability.noData,
      );
      // Nov 27 (pending today): No Data (pendingOnly intensity)
      expect(
        reportBefore.dailyCells[4].scoreSummary.availability,
        ScoreAvailability.noData,
      );
      expect(
        reportBefore.dailyCells[4].intensity,
        HeatmapIntensity.pendingOnly,
      );

      // Streak before correction on Nov 27: Nov 25 was partial (past incomplete), so broken (0)
      final streakBefore = await HabitStreakReader(db1).readStreakForHabit(
        habitId: 'h_quran',
        asOfDate: LocalDate(2026, 11, 27),
        mode: StreakCompletionMode.completedAndRecovered,
      );
      expect(streakBefore.currentStreak, 0);
      expect(streakBefore.state, StreakResolutionState.broken);

      // Preview and confirm historical target correction on v_q2 from 10 to 5 pages
      final proposal = const CounterTargetCorrectionProposal(
        habitId: 'h_quran',
        versionId: 'v_q2',
        proposedTargetCount: 5,
        proposedUnit: 'pages',
        reason: 'Correct v2 target to 5 pages',
      );
      final impact = await AnalyticsCorrectionImpactReader(
        db1,
        clock,
      ).previewImpact(proposal);
      expect(
        impact.dateScoreImpacts.single.beforeScorePercent,
        closeTo(50.0, 0.001),
      );
      expect(
        impact.dateScoreImpacts.single.afterScorePercent,
        closeTo(100.0, 0.001),
      );
      expect(impact.beforeStreakWithRecovery.currentStreak, 0);
      expect(impact.afterStreakWithRecovery.currentStreak, 2);
      expect(impact.beforeStreakCompletedOnly.currentStreak, 0);
      expect(impact.afterStreakCompletedOnly.currentStreak, 1);

      await CounterCorrectionWriter(
        db1,
        clock,
      ).commit(correctionAuditId: 'corr_v2', confirmedPreview: impact.preview);
    } finally {
      await db1.close();
    }

    // Reopen database from disk and verify recalculated score, heatmap, report and streaks
    final db2 = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db2.close);

    final reportAfter = await AnalyticsReportReader(db2).readPeriodReport(
      startInclusive: LocalDate(2026, 11, 23),
      endInclusive: LocalDate(2026, 11, 27),
      filter: const HabitAnalyticsFilter(includePrivate: false),
    );
    // Nov 25 is now completed (5/5 -> 100.0%)!
    expect(
      reportAfter.dailyCells[2].scoreSummary.weightedScorePercent,
      closeTo(100.0, 0.001),
    );
    expect(reportAfter.dailyCells[2].intensity, HeatmapIntensity.full);
    // Average across eligible days (Nov 24 @ 75% and Nov 25 @ 100%) = 87.5%
    expect(reportAfter.averageWeightedScorePercent, closeTo(87.5, 0.001));

    // Streak across Nov 24 (recovered), Nov 25 (completed), Nov 26 (paused/skipped), Nov 27 (pending today) = 2!
    final streakWithRecovery = await HabitStreakReader(db2).readStreakForHabit(
      habitId: 'h_quran',
      asOfDate: LocalDate(2026, 11, 27),
      mode: StreakCompletionMode.completedAndRecovered,
    );
    expect(streakWithRecovery.currentStreak, 2);
    expect(streakWithRecovery.longestStreak, 2);
    expect(streakWithRecovery.state, StreakResolutionState.activePendingToday);

    final streakCompletedOnly = await HabitStreakReader(db2).readStreakForHabit(
      habitId: 'h_quran',
      asOfDate: LocalDate(2026, 11, 27),
      mode: StreakCompletionMode.completedOnly,
    );
    expect(streakCompletedOnly.currentStreak, 1);
    expect(streakCompletedOnly.state, StreakResolutionState.activePendingToday);
  });
}
