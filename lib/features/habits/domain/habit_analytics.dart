import '../data/habit_lifecycle.dart';
import '../data/unified_habit_registry.dart';
import 'habit_metadata.dart';
import 'habit_schedule.dart';

/// Normalized daily status across all eight habit tracking types.
enum HabitAnalyticsStatus {
  notApplicable,
  unknown,
  pending,
  partial,
  completed,
  failed,
  recovered,
  excused,
  conflict,
}

/// Item-level recording and completion counts for multi-checklist habits.
class ChecklistCoverageCounts {
  const ChecklistCoverageCounts({
    required this.totalItems,
    required this.recordedItems,
    required this.completedItems,
    required this.recoveredItems,
    required this.failedItems,
    required this.excusedItems,
    required this.pendingItems,
  });

  final int totalItems;
  final int recordedItems;
  final int completedItems;
  final int recoveredItems;
  final int failedItems;
  final int excusedItems;
  final int pendingItems;
}

/// Normalized, deterministic read-only evaluation of one habit on one local date.
class UnifiedHabitDayEvaluation {
  UnifiedHabitDayEvaluation({
    required this.habitId,
    required this.versionId,
    required this.name,
    required this.date,
    required this.trackingType,
    required this.status,
    required this.applicabilityReason,
    required this.priority,
    required this.category,
    required this.symbol,
    required this.isPrivate,
    required this.includeInScore,
    required this.includeInStreak,
    required this.hasMetadata,
    required double partialRatio,
    required this.summaryText,
    required this.hasOccurrence,
    this.checklistCounts,
    this.scoringUnavailable = false,
    this.normalizedScore,
  }) : partialRatio = partialRatio.clamp(0.0, 1.0);

  final String habitId;
  final String? versionId;
  final String name;
  final LocalDate date;
  final HabitTrackingType trackingType;
  final HabitAnalyticsStatus status;
  final HabitApplicabilityReason applicabilityReason;
  final HabitPriority priority;
  final String category;
  final String? symbol;
  final bool isPrivate;
  final bool includeInScore;
  final bool includeInStreak;
  final bool hasMetadata;
  final double partialRatio;
  final String summaryText;
  final bool hasOccurrence;
  final ChecklistCoverageCounts? checklistCounts;
  final bool scoringUnavailable;
  final double? normalizedScore;

  /// Priority weights: Critical 4, High 3, Normal 2, Low 1.
  int get priorityWeight => priority.weight;

  /// Whether the habit was scheduled and active on [date].
  bool get isApplicable =>
      status == HabitAnalyticsStatus.pending ||
      status == HabitAnalyticsStatus.partial ||
      status == HabitAnalyticsStatus.completed ||
      status == HabitAnalyticsStatus.failed ||
      status == HabitAnalyticsStatus.recovered ||
      status == HabitAnalyticsStatus.excused;

  /// Whether an applicable date has a recorded outcome (non-pending).
  bool get isRecordedApplicable =>
      status == HabitAnalyticsStatus.partial ||
      status == HabitAnalyticsStatus.completed ||
      status == HabitAnalyticsStatus.failed ||
      status == HabitAnalyticsStatus.recovered ||
      status == HabitAnalyticsStatus.excused;

  /// Score multiplier per BUSINESS_RULES.md:
  /// completed = 1.0, recovered = 0.75, partial = normalized & clamped [0..1],
  /// failed = 0.0; pending, excused, notApplicable, unknown, conflict, and
  /// habits with [includeInScore] == false are excluded (null).
  double? get scoreMultiplier {
    if (!includeInScore) return null;
    if (scoringUnavailable) return null;
    if (normalizedScore != null &&
        (status == HabitAnalyticsStatus.completed ||
            status == HabitAnalyticsStatus.partial ||
            status == HabitAnalyticsStatus.failed ||
            status == HabitAnalyticsStatus.recovered)) {
      return normalizedScore!.clamp(0.0, 1.0);
    }
    switch (status) {
      case HabitAnalyticsStatus.completed:
        return 1.0;
      case HabitAnalyticsStatus.recovered:
        return 0.75;
      case HabitAnalyticsStatus.partial:
        return partialRatio;
      case HabitAnalyticsStatus.failed:
        return 0.0;
      case HabitAnalyticsStatus.pending ||
          HabitAnalyticsStatus.excused ||
          HabitAnalyticsStatus.notApplicable ||
          HabitAnalyticsStatus.unknown ||
          HabitAnalyticsStatus.conflict:
        return null;
    }
  }
}

/// Filter criteria for History and Analytics queries.
/// By default, private or unclassified habits (missing metadata) are excluded.
class HabitAnalyticsFilter {
  const HabitAnalyticsFilter({
    this.habitId,
    this.category,
    this.trackingType,
    this.priority,
    this.includePrivate = false,
  });

  final String? habitId;
  final String? category;
  final HabitTrackingType? trackingType;
  final HabitPriority? priority;
  final bool includePrivate;

  bool matches(UnifiedHabitDayEvaluation evaluation) {
    if (!includePrivate && (!evaluation.hasMetadata || evaluation.isPrivate)) {
      return false;
    }
    if (habitId != null && evaluation.habitId != habitId) {
      return false;
    }
    if (category != null &&
        category!.trim().isNotEmpty &&
        evaluation.category.toLowerCase() != category!.trim().toLowerCase()) {
      return false;
    }
    if (trackingType != null && evaluation.trackingType != trackingType) {
      return false;
    }
    if (priority != null && evaluation.priority != priority) {
      return false;
    }
    return true;
  }

  List<UnifiedHabitDayEvaluation> apply(
    Iterable<UnifiedHabitDayEvaluation> evaluations,
  ) => List.unmodifiable(evaluations.where(matches));
}

enum ScoreAvailability { available, noData }

/// Weighted daily score and separate recording coverage summary.
/// No eligible data produces [ScoreAvailability.noData] ([weightedScorePercent] == null),
/// never 0% or 100%.
class DailyScoreSummary {
  const DailyScoreSummary({
    required this.date,
    required this.availability,
    required this.weightedScorePercent,
    required this.weightedNumerator,
    required this.eligibleWeightSum,
    required this.applicableHabitCount,
    required this.recordedApplicableCount,
    required this.pendingApplicableCount,
    required this.excusedApplicableCount,
    required this.excludedFromScoreCount,
    required this.conflictCount,
    required this.recordingCoveragePercent,
    required this.applicableChecklistItems,
    required this.recordedChecklistItems,
    required this.checklistItemCoveragePercent,
    this.validScoreCount = 0,
    this.unavailableRecordedScoreCount = 0,
  });

  final LocalDate date;
  final ScoreAvailability availability;
  final double? weightedScorePercent;
  final double weightedNumerator;
  final int eligibleWeightSum;
  final int applicableHabitCount;
  final int recordedApplicableCount;
  final int pendingApplicableCount;
  final int excusedApplicableCount;
  final int excludedFromScoreCount;
  final int conflictCount;
  final double? recordingCoveragePercent;
  final int applicableChecklistItems;
  final int recordedChecklistItems;
  final double? checklistItemCoveragePercent;
  final int validScoreCount;
  final int unavailableRecordedScoreCount;
  double? get scoreCoveragePercent =>
      validScoreCount + unavailableRecordedScoreCount == 0
      ? null
      : 100.0 *
            validScoreCount /
            (validScoreCount + unavailableRecordedScoreCount);

  /// True when at least one applicable habit is still pending, ensuring
  /// incomplete recording never looks like 100% full completion.
  bool get isIncompleteRecording =>
      applicableHabitCount > 0 && pendingApplicableCount > 0;
}

/// Pure domain calculator for weighted daily score and recording coverage.
class DailyWeightedScoreCalculator {
  const DailyWeightedScoreCalculator._();

  static DailyScoreSummary calculate({
    required LocalDate date,
    required Iterable<UnifiedHabitDayEvaluation> evaluations,
  }) {
    var weightedNumerator = 0.0;
    var eligibleWeightSum = 0;
    var applicableHabitCount = 0;
    var recordedApplicableCount = 0;
    var pendingApplicableCount = 0;
    var excusedApplicableCount = 0;
    var excludedFromScoreCount = 0;
    var conflictCount = 0;
    var applicableChecklistItems = 0;
    var recordedChecklistItems = 0;
    var validScoreCount = 0;
    var unavailableRecordedScoreCount = 0;

    for (final eval in evaluations) {
      if (eval.status == HabitAnalyticsStatus.conflict) {
        conflictCount += 1;
        continue;
      }
      if (!eval.isApplicable) {
        continue;
      }
      applicableHabitCount += 1;
      if (eval.status == HabitAnalyticsStatus.pending) {
        pendingApplicableCount += 1;
      } else {
        recordedApplicableCount += 1;
      }
      if (eval.status == HabitAnalyticsStatus.excused) {
        excusedApplicableCount += 1;
      }
      if (!eval.includeInScore) {
        excludedFromScoreCount += 1;
      }

      if (eval.checklistCounts != null) {
        applicableChecklistItems += eval.checklistCounts!.totalItems;
        recordedChecklistItems += eval.checklistCounts!.recordedItems;
      }

      final multiplier = eval.scoreMultiplier;
      if (multiplier != null) {
        validScoreCount += 1;
        final weight = eval.priorityWeight;
        weightedNumerator += weight * multiplier;
        eligibleWeightSum += weight;
      } else if (eval.includeInScore &&
          eval.scoringUnavailable &&
          eval.isRecordedApplicable &&
          eval.status != HabitAnalyticsStatus.excused) {
        unavailableRecordedScoreCount += 1;
      }
    }

    final hasScore = eligibleWeightSum > 0;
    final weightedScorePercent = hasScore
        ? (100.0 * weightedNumerator / eligibleWeightSum).clamp(0.0, 100.0)
        : null;
    final recordingCoveragePercent = applicableHabitCount > 0
        ? (100.0 * recordedApplicableCount / applicableHabitCount).clamp(
            0.0,
            100.0,
          )
        : null;
    final checklistCoveragePercent = applicableChecklistItems > 0
        ? (100.0 * recordedChecklistItems / applicableChecklistItems).clamp(
            0.0,
            100.0,
          )
        : null;

    return DailyScoreSummary(
      date: date,
      availability: hasScore
          ? ScoreAvailability.available
          : ScoreAvailability.noData,
      weightedScorePercent: weightedScorePercent,
      weightedNumerator: weightedNumerator,
      eligibleWeightSum: eligibleWeightSum,
      applicableHabitCount: applicableHabitCount,
      recordedApplicableCount: recordedApplicableCount,
      pendingApplicableCount: pendingApplicableCount,
      excusedApplicableCount: excusedApplicableCount,
      excludedFromScoreCount: excludedFromScoreCount,
      conflictCount: conflictCount,
      recordingCoveragePercent: recordingCoveragePercent,
      applicableChecklistItems: applicableChecklistItems,
      recordedChecklistItems: recordedChecklistItems,
      checklistItemCoveragePercent: checklistCoveragePercent,
      validScoreCount: validScoreCount,
      unavailableRecordedScoreCount: unavailableRecordedScoreCount,
    );
  }
}

/// Configurable accepted completion mode for habit streaks.
enum StreakCompletionMode { completedOnly, completedAndRecovered }

/// Resolution state of a habit's streak as of a reference local date.
enum StreakResolutionState {
  active,
  activePendingToday,
  unresolved,
  broken,
  noApplicableHistory,
  excluded,
}

/// Deterministic summary of a single habit's scheduled-occurrence streak.
class HabitStreakSummary {
  HabitStreakSummary({
    required this.habitId,
    required this.habitName,
    required this.mode,
    required this.state,
    required this.currentStreak,
    required this.longestStreak,
    required this.applicableDaysCount,
    required this.completedDaysCount,
    required this.recoveredDaysCount,
    required this.failedDaysCount,
    required this.excusedDaysCount,
    required this.skippedNotApplicableCount,
    required List<LocalDate> unresolvedPendingDates,
    required this.isPendingToday,
    required this.includeInStreak,
  }) : unresolvedPendingDates = List.unmodifiable(unresolvedPendingDates);

  final String habitId;
  final String habitName;
  final StreakCompletionMode mode;
  final StreakResolutionState state;
  final int currentStreak;
  final int longestStreak;
  final int applicableDaysCount;
  final int completedDaysCount;
  final int recoveredDaysCount;
  final int failedDaysCount;
  final int excusedDaysCount;
  final int skippedNotApplicableCount;
  final List<LocalDate> unresolvedPendingDates;
  final bool isPendingToday;
  final bool includeInStreak;
}

/// Pure domain evaluator for scheduled-occurrence habit streaks.
/// Follows BUSINESS_RULES.md:
/// - Follows scheduled occurrences, not raw calendar days.
/// - Unscheduled/paused (notApplicable) and excused dates neither increment nor break.
/// - Past pending makes the streak unresolved; current pending on [asOfDate] does not reset it.
/// - Unknown or conflicting dates make continuity unresolved, including on [asOfDate].
/// - Confirmed failure (or past partial, or recovered under [StreakCompletionMode.completedOnly]) breaks it.
class HabitStreakEvaluator {
  const HabitStreakEvaluator._();

  static HabitStreakSummary evaluate({
    required String habitId,
    required String habitName,
    required LocalDate asOfDate,
    required Iterable<UnifiedHabitDayEvaluation> chronologicalEvaluations,
    StreakCompletionMode mode = StreakCompletionMode.completedAndRecovered,
    bool includeInStreak = true,
  }) {
    final sorted = chronologicalEvaluations.toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    if (!includeInStreak) {
      return HabitStreakSummary(
        habitId: habitId,
        habitName: habitName,
        mode: mode,
        state: StreakResolutionState.excluded,
        currentStreak: 0,
        longestStreak: 0,
        applicableDaysCount: 0,
        completedDaysCount: 0,
        recoveredDaysCount: 0,
        failedDaysCount: 0,
        excusedDaysCount: 0,
        skippedNotApplicableCount: 0,
        unresolvedPendingDates: const [],
        isPendingToday: false,
        includeInStreak: false,
      );
    }

    var currentRun = 0;
    var longestRun = 0;
    var applicableDays = 0;
    var completedDays = 0;
    var recoveredDays = 0;
    var failedDays = 0;
    var excusedDays = 0;
    var skippedNotApplicable = 0;
    var hasUnresolvedSinceLastBreak = false;
    var lastRelevantBroke = false;
    var isPendingToday = false;
    final unresolvedDates = <LocalDate>[];

    for (final eval in sorted) {
      if (eval.date.compareTo(asOfDate) > 0) {
        continue;
      }
      final isToday = eval.date.compareTo(asOfDate) == 0;

      switch (eval.status) {
        case HabitAnalyticsStatus.notApplicable:
          skippedNotApplicable += 1;
        case HabitAnalyticsStatus.unknown || HabitAnalyticsStatus.conflict:
          // Neither applicability nor an outcome is confirmed, so this date
          // cannot join confirmed runs or count as a failure.
          hasUnresolvedSinceLastBreak = true;
          currentRun = 0;
        case HabitAnalyticsStatus.excused:
          applicableDays += 1;
          excusedDays += 1;
        case HabitAnalyticsStatus.completed:
          applicableDays += 1;
          completedDays += 1;
          currentRun += 1;
          lastRelevantBroke = false;
          if (currentRun > longestRun) {
            longestRun = currentRun;
          }
        case HabitAnalyticsStatus.recovered:
          applicableDays += 1;
          recoveredDays += 1;
          if (mode == StreakCompletionMode.completedAndRecovered) {
            currentRun += 1;
            lastRelevantBroke = false;
            if (currentRun > longestRun) {
              longestRun = currentRun;
            }
          } else {
            currentRun = 0;
            hasUnresolvedSinceLastBreak = false;
            lastRelevantBroke = true;
          }
        case HabitAnalyticsStatus.failed:
          applicableDays += 1;
          failedDays += 1;
          currentRun = 0;
          hasUnresolvedSinceLastBreak = false;
          lastRelevantBroke = true;
        case HabitAnalyticsStatus.partial:
          applicableDays += 1;
          if (isToday) {
            isPendingToday = true;
          } else {
            failedDays += 1;
            currentRun = 0;
            hasUnresolvedSinceLastBreak = false;
            lastRelevantBroke = true;
          }
        case HabitAnalyticsStatus.pending:
          applicableDays += 1;
          if (isToday) {
            // Current pending does not immediately reset the streak.
            isPendingToday = true;
          } else {
            // Past pending makes the streak unresolved and resets confirmed continuity after it.
            unresolvedDates.add(eval.date);
            hasUnresolvedSinceLastBreak = true;
            currentRun = 0;
          }
      }
    }

    final StreakResolutionState state;
    if (hasUnresolvedSinceLastBreak) {
      state = StreakResolutionState.unresolved;
    } else if (lastRelevantBroke && currentRun == 0) {
      state = StreakResolutionState.broken;
    } else if (isPendingToday) {
      state = StreakResolutionState.activePendingToday;
    } else if (currentRun > 0) {
      state = StreakResolutionState.active;
    } else {
      state = StreakResolutionState.noApplicableHistory;
    }

    return HabitStreakSummary(
      habitId: habitId,
      habitName: habitName,
      mode: mode,
      state: state,
      currentStreak: currentRun,
      longestStreak: longestRun,
      applicableDaysCount: applicableDays,
      completedDaysCount: completedDays,
      recoveredDaysCount: recoveredDays,
      failedDaysCount: failedDays,
      excusedDaysCount: excusedDays,
      skippedNotApplicableCount: skippedNotApplicable,
      unresolvedPendingDates: unresolvedDates,
      isPendingToday: isPendingToday,
      includeInStreak: true,
    );
  }
}

/// Visual intensity buckets for calendar heatmap cells.
enum HeatmapIntensity { noData, pendingOnly, low, medium, high, full }

/// One day cell in a calendar or date-range heatmap.
class CalendarHeatmapCell {
  CalendarHeatmapCell({
    required this.date,
    required this.scoreSummary,
    required this.intensity,
    required List<UnifiedHabitDayEvaluation> evaluations,
  }) : evaluations = List.unmodifiable(evaluations);

  final LocalDate date;
  final DailyScoreSummary scoreSummary;
  final HeatmapIntensity intensity;
  final List<UnifiedHabitDayEvaluation> evaluations;
}

/// Per-category weighted score and recording coverage breakdown across a date range.
class CategoryAnalyticsBreakdown {
  const CategoryAnalyticsBreakdown({
    required this.category,
    required this.applicableCount,
    required this.recordedCount,
    required this.pendingCount,
    required this.weightedScorePercent,
    required this.recordingCoveragePercent,
  });

  final String category;
  final int applicableCount;
  final int recordedCount;
  final int pendingCount;
  final double? weightedScorePercent;
  final double? recordingCoveragePercent;
}

/// Per-habit adherence and coverage summary across a date range.
class HabitPeriodSummaryRow {
  const HabitPeriodSummaryRow({
    required this.habitId,
    required this.name,
    required this.category,
    required this.trackingType,
    required this.priority,
    required this.applicableDays,
    required this.completedDays,
    required this.recoveredDays,
    required this.partialDays,
    required this.failedDays,
    required this.pendingDays,
    required this.excusedDays,
    required this.weightedScorePercent,
    required this.recordingCoveragePercent,
  });

  final String habitId;
  final String name;
  final String category;
  final HabitTrackingType trackingType;
  final HabitPriority priority;
  final int applicableDays;
  final int completedDays;
  final int recoveredDays;
  final int partialDays;
  final int failedDays;
  final int pendingDays;
  final int excusedDays;
  final double? weightedScorePercent;
  final double? recordingCoveragePercent;
}

/// Deterministic period analytics report for a date interval.
class PeriodAnalyticsReport {
  PeriodAnalyticsReport({
    required this.startInclusive,
    required this.endInclusive,
    required this.totalCalendarDays,
    required this.eligibleScoreDays,
    required this.noDataDays,
    required this.incompleteRecordingDays,
    required this.averageWeightedScorePercent,
    required this.overallWeightedScorePercent,
    required this.overallRecordingCoveragePercent,
    required this.overallChecklistItemCoveragePercent,
    required this.totalApplicableHabits,
    required this.totalRecordedHabits,
    required this.totalPendingHabits,
    required this.totalCompletedHabits,
    required this.totalRecoveredHabits,
    required this.totalPartialHabits,
    required this.totalFailedHabits,
    required this.totalExcusedHabits,
    this.validScoreCount = 0,
    this.unavailableRecordedScoreCount = 0,
    required List<CalendarHeatmapCell> dailyCells,
    required List<CategoryAnalyticsBreakdown> categoryBreakdowns,
    required List<HabitPeriodSummaryRow> habitSummaries,
  }) : dailyCells = List.unmodifiable(dailyCells),
       categoryBreakdowns = List.unmodifiable(categoryBreakdowns),
       habitSummaries = List.unmodifiable(habitSummaries);

  static const String nonJudgmentalDisclaimer =
      'Scores reflect recorded schedule adherence only and never measure human worth or faith.';

  final LocalDate startInclusive;
  final LocalDate endInclusive;
  final int totalCalendarDays;
  final int eligibleScoreDays;
  final int noDataDays;
  final int incompleteRecordingDays;
  final double? averageWeightedScorePercent;
  final double? overallWeightedScorePercent;
  final double? overallRecordingCoveragePercent;
  final double? overallChecklistItemCoveragePercent;
  final int totalApplicableHabits;
  final int totalRecordedHabits;
  final int totalPendingHabits;
  final int totalCompletedHabits;
  final int totalRecoveredHabits;
  final int totalPartialHabits;
  final int totalFailedHabits;
  final int totalExcusedHabits;
  final int validScoreCount;
  final int unavailableRecordedScoreCount;
  double? get scoreCoveragePercent =>
      validScoreCount + unavailableRecordedScoreCount == 0
      ? null
      : 100.0 *
            validScoreCount /
            (validScoreCount + unavailableRecordedScoreCount);
  final List<CalendarHeatmapCell> dailyCells;
  final List<CategoryAnalyticsBreakdown> categoryBreakdowns;
  final List<HabitPeriodSummaryRow> habitSummaries;

  String get disclaimer => nonJudgmentalDisclaimer;
}

/// Pure domain calculator for heatmap cells and period analytics reports.
class AnalyticsPeriodReportCalculator {
  const AnalyticsPeriodReportCalculator._();

  static HeatmapIntensity classifyIntensity(DailyScoreSummary summary) {
    if (summary.availability == ScoreAvailability.noData) {
      return summary.pendingApplicableCount > 0
          ? HeatmapIntensity.pendingOnly
          : HeatmapIntensity.noData;
    }
    final score = summary.weightedScorePercent!;
    if (score >= 100.0 &&
        !summary.isIncompleteRecording &&
        summary.unavailableRecordedScoreCount == 0) {
      return HeatmapIntensity.full;
    }
    if (score >= 75.0) return HeatmapIntensity.high;
    if (score >= 40.0) return HeatmapIntensity.medium;
    return HeatmapIntensity.low;
  }

  static CalendarHeatmapCell buildCell({
    required LocalDate date,
    required List<UnifiedHabitDayEvaluation> evaluations,
  }) {
    final summary = DailyWeightedScoreCalculator.calculate(
      date: date,
      evaluations: evaluations,
    );
    return CalendarHeatmapCell(
      date: date,
      scoreSummary: summary,
      intensity: classifyIntensity(summary),
      evaluations: evaluations,
    );
  }

  static PeriodAnalyticsReport buildReport({
    required LocalDate startInclusive,
    required LocalDate endInclusive,
    required Map<LocalDate, List<UnifiedHabitDayEvaluation>> evaluationsByDate,
  }) {
    if (endInclusive.compareTo(startInclusive) < 0) {
      throw ArgumentError('endInclusive must not precede startInclusive');
    }

    final dailyCells = <CalendarHeatmapCell>[];
    var eligibleScoreDays = 0;
    var noDataDays = 0;
    var incompleteRecordingDays = 0;
    var dailyScoreSum = 0.0;
    var totalWeightedNumerator = 0.0;
    var totalEligibleWeight = 0;
    var totalApplicable = 0;
    var totalRecorded = 0;
    var totalPending = 0;
    var totalCompleted = 0;
    var totalRecovered = 0;
    var totalPartial = 0;
    var totalFailed = 0;
    var totalExcused = 0;
    var totalChecklistApplicable = 0;
    var totalChecklistRecorded = 0;
    var validScoreCount = 0;
    var unavailableRecordedScoreCount = 0;

    final byCategory = <String, List<UnifiedHabitDayEvaluation>>{};
    final byHabit = <String, List<UnifiedHabitDayEvaluation>>{};

    var cursor = startInclusive;
    while (cursor.compareTo(endInclusive) <= 0) {
      final dayEvals = evaluationsByDate[cursor] ?? const [];
      final cell = buildCell(date: cursor, evaluations: dayEvals);
      dailyCells.add(cell);

      final s = cell.scoreSummary;
      if (s.availability == ScoreAvailability.available) {
        eligibleScoreDays += 1;
        dailyScoreSum += s.weightedScorePercent!;
      } else {
        noDataDays += 1;
      }
      if (s.isIncompleteRecording) {
        incompleteRecordingDays += 1;
      }
      totalWeightedNumerator += s.weightedNumerator;
      totalEligibleWeight += s.eligibleWeightSum;
      totalApplicable += s.applicableHabitCount;
      totalRecorded += s.recordedApplicableCount;
      totalPending += s.pendingApplicableCount;
      totalChecklistApplicable += s.applicableChecklistItems;
      totalChecklistRecorded += s.recordedChecklistItems;
      validScoreCount += s.validScoreCount;
      unavailableRecordedScoreCount += s.unavailableRecordedScoreCount;

      for (final eval in dayEvals) {
        byHabit.putIfAbsent(eval.habitId, () => []).add(eval);
        if (eval.isApplicable) {
          byCategory.putIfAbsent(eval.category, () => []).add(eval);
        }
        switch (eval.status) {
          case HabitAnalyticsStatus.completed:
            totalCompleted += 1;
          case HabitAnalyticsStatus.recovered:
            totalRecovered += 1;
          case HabitAnalyticsStatus.partial:
            totalPartial += 1;
          case HabitAnalyticsStatus.failed:
            totalFailed += 1;
          case HabitAnalyticsStatus.excused:
            totalExcused += 1;
          case HabitAnalyticsStatus.pending ||
              HabitAnalyticsStatus.notApplicable ||
              HabitAnalyticsStatus.unknown ||
              HabitAnalyticsStatus.conflict:
            break;
        }
      }

      final next = DateTime.utc(cursor.year, cursor.month, cursor.day + 1);
      cursor = LocalDate(next.year, next.month, next.day);
    }

    final categoryKeys = byCategory.keys.toList()..sort();
    final categoryBreakdowns = <CategoryAnalyticsBreakdown>[];
    for (final cat in categoryKeys) {
      final list = byCategory[cat]!;
      var app = 0;
      var rec = 0;
      var pend = 0;
      var num = 0.0;
      var den = 0;
      for (final e in list) {
        if (!e.isApplicable) continue;
        app += 1;
        if (e.status == HabitAnalyticsStatus.pending) {
          pend += 1;
        } else {
          rec += 1;
        }
        final mult = e.scoreMultiplier;
        if (mult != null) {
          num += e.priorityWeight * mult;
          den += e.priorityWeight;
        }
      }
      categoryBreakdowns.add(
        CategoryAnalyticsBreakdown(
          category: cat,
          applicableCount: app,
          recordedCount: rec,
          pendingCount: pend,
          weightedScorePercent: den > 0 ? (100.0 * num / den) : null,
          recordingCoveragePercent: app > 0 ? (100.0 * rec / app) : null,
        ),
      );
    }

    final habitIds = byHabit.keys.toList()..sort();
    final habitSummaries = <HabitPeriodSummaryRow>[];
    for (final id in habitIds) {
      final list = byHabit[id]!;
      final latest = list.last;
      var app = 0;
      var comp = 0;
      var recov = 0;
      var part = 0;
      var fail = 0;
      var pend = 0;
      var exc = 0;
      var num = 0.0;
      var den = 0;
      for (final e in list) {
        if (!e.isApplicable) continue;
        app += 1;
        switch (e.status) {
          case HabitAnalyticsStatus.completed:
            comp += 1;
          case HabitAnalyticsStatus.recovered:
            recov += 1;
          case HabitAnalyticsStatus.partial:
            part += 1;
          case HabitAnalyticsStatus.failed:
            fail += 1;
          case HabitAnalyticsStatus.pending:
            pend += 1;
          case HabitAnalyticsStatus.excused:
            exc += 1;
          case HabitAnalyticsStatus.notApplicable ||
              HabitAnalyticsStatus.unknown ||
              HabitAnalyticsStatus.conflict:
            break;
        }
        final mult = e.scoreMultiplier;
        if (mult != null) {
          num += e.priorityWeight * mult;
          den += e.priorityWeight;
        }
      }
      final recorded = comp + recov + part + fail + exc;
      habitSummaries.add(
        HabitPeriodSummaryRow(
          habitId: id,
          name: latest.name,
          category: latest.category,
          trackingType: latest.trackingType,
          priority: latest.priority,
          applicableDays: app,
          completedDays: comp,
          recoveredDays: recov,
          partialDays: part,
          failedDays: fail,
          pendingDays: pend,
          excusedDays: exc,
          weightedScorePercent: den > 0 ? (100.0 * num / den) : null,
          recordingCoveragePercent: app > 0 ? (100.0 * recorded / app) : null,
        ),
      );
    }

    return PeriodAnalyticsReport(
      startInclusive: startInclusive,
      endInclusive: endInclusive,
      totalCalendarDays: dailyCells.length,
      eligibleScoreDays: eligibleScoreDays,
      noDataDays: noDataDays,
      incompleteRecordingDays: incompleteRecordingDays,
      averageWeightedScorePercent: eligibleScoreDays > 0
          ? (dailyScoreSum / eligibleScoreDays)
          : null,
      overallWeightedScorePercent: totalEligibleWeight > 0
          ? (100.0 * totalWeightedNumerator / totalEligibleWeight)
          : null,
      overallRecordingCoveragePercent: totalApplicable > 0
          ? (100.0 * totalRecorded / totalApplicable)
          : null,
      overallChecklistItemCoveragePercent: totalChecklistApplicable > 0
          ? (100.0 * totalChecklistRecorded / totalChecklistApplicable)
          : null,
      totalApplicableHabits: totalApplicable,
      totalRecordedHabits: totalRecorded,
      totalPendingHabits: totalPending,
      totalCompletedHabits: totalCompleted,
      totalRecoveredHabits: totalRecovered,
      totalPartialHabits: totalPartial,
      totalFailedHabits: totalFailed,
      totalExcusedHabits: totalExcused,
      validScoreCount: validScoreCount,
      unavailableRecordedScoreCount: unavailableRecordedScoreCount,
      dailyCells: dailyCells,
      categoryBreakdowns: categoryBreakdowns,
      habitSummaries: habitSummaries,
    );
  }
}
