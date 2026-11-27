import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/features/habits/data/habit_lifecycle.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/habit_analytics.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

UnifiedHabitDayEvaluation _eval({
  required String habitId,
  required LocalDate date,
  required HabitAnalyticsStatus status,
  HabitPriority priority = HabitPriority.normal,
  String category = 'General',
  HabitTrackingType type = HabitTrackingType.counter,
  bool isPrivate = false,
  bool includeInScore = true,
  bool includeInStreak = true,
  bool hasMetadata = true,
  double partialRatio = 0.0,
  ChecklistCoverageCounts? checklistCounts,
}) => UnifiedHabitDayEvaluation(
  habitId: habitId,
  versionId: 'v_$habitId',
  name: 'Habit $habitId',
  date: date,
  trackingType: type,
  status: status,
  applicabilityReason: status == HabitAnalyticsStatus.notApplicable
      ? HabitApplicabilityReason.unscheduled
      : HabitApplicabilityReason.applicable,
  priority: priority,
  category: category,
  symbol: null,
  isPrivate: isPrivate,
  includeInScore: includeInScore,
  includeInStreak: includeInStreak,
  hasMetadata: hasMetadata,
  partialRatio: partialRatio,
  summaryText: status.name,
  hasOccurrence:
      status != HabitAnalyticsStatus.pending &&
      status != HabitAnalyticsStatus.notApplicable,
  checklistCounts: checklistCounts,
);

void main() {
  test('DailyWeightedScoreCalculator computes priority-weighted scores, separates recording and checklist coverage, and returns explicit No Data', () {
    final date = LocalDate(2026, 11, 26);

    // 1. No eligible records (all pending/excused/notApplicable/excluded) -> No Data, never 0% or 100%
    final noDataSummary = DailyWeightedScoreCalculator.calculate(
      date: date,
      evaluations: [
        _eval(
          habitId: 'h_pend',
          date: date,
          status: HabitAnalyticsStatus.pending,
          priority: HabitPriority.critical,
        ),
        _eval(
          habitId: 'h_exc',
          date: date,
          status: HabitAnalyticsStatus.excused,
          priority: HabitPriority.high,
        ),
        _eval(
          habitId: 'h_excl',
          date: date,
          status: HabitAnalyticsStatus.completed,
          priority: HabitPriority.normal,
          includeInScore: false,
        ),
        _eval(
          habitId: 'h_na',
          date: date,
          status: HabitAnalyticsStatus.notApplicable,
        ),
      ],
    );
    expect(noDataSummary.availability, ScoreAvailability.noData);
    expect(noDataSummary.weightedScorePercent, isNull);
    expect(noDataSummary.applicableHabitCount, 3);
    expect(noDataSummary.recordedApplicableCount, 2);
    expect(noDataSummary.pendingApplicableCount, 1);
    expect(noDataSummary.isIncompleteRecording, isTrue);
    expect(
      noDataSummary.recordingCoveragePercent,
      closeTo(200.0 / 3.0, 0.0001),
    );

    // 2. Mixed priority weights:
    // - Critical (4) completed (1.0) -> 4.0
    // - High (3) recovered (0.75) -> 2.25
    // - Normal (2) partial (0.5) -> 1.0
    // - Low (1) failed (0.0) -> 0.0
    // - Pending (weight 4) -> excluded from score denominator, flags incomplete recording
    // Numerator = 4.0 + 2.25 + 1.0 + 0.0 = 7.25; Denominator = 4 + 3 + 2 + 1 = 10 -> 72.5%
    final mixedSummary = DailyWeightedScoreCalculator.calculate(
      date: date,
      evaluations: [
        _eval(
          habitId: 'h_crit',
          date: date,
          status: HabitAnalyticsStatus.completed,
          priority: HabitPriority.critical,
        ),
        _eval(
          habitId: 'h_high',
          date: date,
          status: HabitAnalyticsStatus.recovered,
          priority: HabitPriority.high,
        ),
        _eval(
          habitId: 'h_norm',
          date: date,
          status: HabitAnalyticsStatus.partial,
          priority: HabitPriority.normal,
          partialRatio: 0.5,
          type: HabitTrackingType.checklist,
          checklistCounts: const ChecklistCoverageCounts(
            totalItems: 5,
            recordedItems: 4,
            completedItems: 2,
            recoveredItems: 0,
            failedItems: 2,
            excusedItems: 0,
            pendingItems: 1,
          ),
        ),
        _eval(
          habitId: 'h_low',
          date: date,
          status: HabitAnalyticsStatus.failed,
          priority: HabitPriority.low,
        ),
        _eval(
          habitId: 'h_pend',
          date: date,
          status: HabitAnalyticsStatus.pending,
          priority: HabitPriority.critical,
        ),
      ],
    );
    expect(mixedSummary.availability, ScoreAvailability.available);
    expect(mixedSummary.weightedScorePercent, closeTo(72.5, 0.0001));
    expect(mixedSummary.eligibleWeightSum, 10);
    expect(mixedSummary.applicableHabitCount, 5);
    expect(mixedSummary.recordedApplicableCount, 4);
    expect(mixedSummary.pendingApplicableCount, 1);
    expect(mixedSummary.isIncompleteRecording, isTrue);
    expect(mixedSummary.recordingCoveragePercent, closeTo(80.0, 0.0001));
    expect(mixedSummary.checklistItemCoveragePercent, closeTo(80.0, 0.0001));
  });

  test('HabitStreakEvaluator skips unscheduled/paused/excused dates, distinguishes completedOnly vs completedAndRecovered, and handles past vs current pending', () {
    LocalDate d(int day) => LocalDate(2026, 11, day);

    // Timeline Nov 20..26:
    // Nov 20: completed (streak 1)
    // Nov 21: notApplicable (paused/unscheduled -> streak stays 1)
    // Nov 22: recovered (streak 2 in completedAndRecovered, broken -> 0 in completedOnly)
    // Nov 23: excused (streak stays 2 in completedAndRecovered)
    // Nov 24: completed (streak 3 in completedAndRecovered, 1 in completedOnly)
    // Nov 25: completed (streak 4 in completedAndRecovered, 2 in completedOnly)
    // Nov 26 (today): pending (does not reset streak -> activePendingToday)
    final evals = [
      _eval(habitId: 'h', date: d(20), status: HabitAnalyticsStatus.completed),
      _eval(
        habitId: 'h',
        date: d(21),
        status: HabitAnalyticsStatus.notApplicable,
      ),
      _eval(habitId: 'h', date: d(22), status: HabitAnalyticsStatus.recovered),
      _eval(habitId: 'h', date: d(23), status: HabitAnalyticsStatus.excused),
      _eval(habitId: 'h', date: d(24), status: HabitAnalyticsStatus.completed),
      _eval(habitId: 'h', date: d(25), status: HabitAnalyticsStatus.completed),
      _eval(habitId: 'h', date: d(26), status: HabitAnalyticsStatus.pending),
    ];

    final withRecovery = HabitStreakEvaluator.evaluate(
      habitId: 'h',
      habitName: 'Quran Reading',
      asOfDate: d(26),
      chronologicalEvaluations: evals,
      mode: StreakCompletionMode.completedAndRecovered,
    );
    expect(withRecovery.currentStreak, 4);
    expect(withRecovery.longestStreak, 4);
    expect(withRecovery.state, StreakResolutionState.activePendingToday);
    expect(withRecovery.skippedNotApplicableCount, 1);
    expect(withRecovery.excusedDaysCount, 1);

    final completedOnly = HabitStreakEvaluator.evaluate(
      habitId: 'h',
      habitName: 'Quran Reading',
      asOfDate: d(26),
      chronologicalEvaluations: evals,
      mode: StreakCompletionMode.completedOnly,
    );
    expect(completedOnly.currentStreak, 2);
    expect(completedOnly.longestStreak, 2);
    expect(completedOnly.state, StreakResolutionState.activePendingToday);

    // Past pending on Nov 24 makes the streak unresolved
    final withPastPending = [
      _eval(habitId: 'h', date: d(23), status: HabitAnalyticsStatus.completed),
      _eval(habitId: 'h', date: d(24), status: HabitAnalyticsStatus.pending),
      _eval(habitId: 'h', date: d(25), status: HabitAnalyticsStatus.completed),
    ];
    final unresolved = HabitStreakEvaluator.evaluate(
      habitId: 'h',
      habitName: 'Quran Reading',
      asOfDate: d(25),
      chronologicalEvaluations: withPastPending,
    );
    expect(unresolved.state, StreakResolutionState.unresolved);
    expect(unresolved.unresolvedPendingDates.length, 1);
    expect(unresolved.unresolvedPendingDates.single.compareTo(d(24)), 0);
    expect(unresolved.currentStreak, 1);

    // Excluded from streak
    final excluded = HabitStreakEvaluator.evaluate(
      habitId: 'h',
      habitName: 'Private Habit',
      asOfDate: d(25),
      chronologicalEvaluations: withPastPending,
      includeInStreak: false,
    );
    expect(excluded.state, StreakResolutionState.excluded);
    expect(excluded.currentStreak, 0);
  });
}
