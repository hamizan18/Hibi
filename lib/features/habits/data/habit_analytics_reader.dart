import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/counter_progress.dart';
import '../domain/habit_analytics.dart';
import '../domain/habit_schedule.dart';
import 'counter_correction_preview.dart';
import 'unified_habit_history_reader.dart';
import 'unified_habit_registry.dart';

/// Read-only applicable-date streak reader across all configured tracking types.
class HabitStreakReader {
  const HabitStreakReader(this._db);

  final AppDatabase _db;

  Future<HabitStreakSummary> readStreakForHabit({
    required String habitId,
    required LocalDate asOfDate,
    StreakCompletionMode mode = StreakCompletionMode.completedAndRecovered,
  }) => _db.transaction(() async {
    final historyReader = UnifiedHabitHistoryReader(_db);
    final earliestStart = await historyReader.findEarliestVersionStart(habitId);
    if (earliestStart == null || earliestStart.compareTo(asOfDate) > 0) {
      return HabitStreakSummary(
        habitId: habitId,
        habitName: habitId,
        mode: mode,
        state: StreakResolutionState.noApplicableHistory,
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
        includeInStreak: true,
      );
    }

    final evaluations = await historyReader.readHabitRange(
      habitId: habitId,
      startInclusive: earliestStart,
      endInclusive: asOfDate,
    );
    final latest = evaluations.last;
    return HabitStreakEvaluator.evaluate(
      habitId: habitId,
      habitName: latest.name,
      asOfDate: asOfDate,
      chronologicalEvaluations: evaluations,
      mode: mode,
      includeInStreak: latest.includeInStreak,
    );
  });

  Future<List<HabitStreakSummary>> readAllStreaks({
    required LocalDate asOfDate,
    StreakCompletionMode mode = StreakCompletionMode.completedAndRecovered,
    HabitAnalyticsFilter filter = const HabitAnalyticsFilter(),
  }) => _db.transaction(() async {
    final summaries = await UnifiedHabitRegistryReader(_db)
        .readAll(asOfDate: asOfDate);
    final historyReader = UnifiedHabitHistoryReader(_db);
    final results = <HabitStreakSummary>[];

    for (final habit in summaries) {
      if (habit.trackingType == HabitTrackingType.unconfigured) continue;
      final todayEval = await historyReader.readHabitRange(
        habitId: habit.habitId,
        startInclusive: asOfDate,
        endInclusive: asOfDate,
      );
      if (!filter.matches(todayEval.single)) continue;
      results.add(
        await readStreakForHabit(
          habitId: habit.habitId,
          asOfDate: asOfDate,
          mode: mode,
        ),
      );
    }
    return List.unmodifiable(results);
  });
}

/// Read-only calendar month and date-range heatmap reader.
class CalendarHeatmapReader {
  const CalendarHeatmapReader(this._db);

  final AppDatabase _db;

  Future<List<CalendarHeatmapCell>> readMonthHeatmap({
    required int year,
    required int month,
    HabitAnalyticsFilter filter = const HabitAnalyticsFilter(),
  }) {
    final start = LocalDate(year, month, 1);
    final lastDay = DateTime.utc(year, month + 1, 0).day;
    final end = LocalDate(year, month, lastDay);
    return readRangeHeatmap(
      startInclusive: start,
      endInclusive: end,
      filter: filter,
    );
  }

  Future<List<CalendarHeatmapCell>> readRangeHeatmap({
    required LocalDate startInclusive,
    required LocalDate endInclusive,
    HabitAnalyticsFilter filter = const HabitAnalyticsFilter(),
  }) => _db.transaction(() async {
    final rangeMap = await UnifiedHabitHistoryReader(_db).readRange(
      startInclusive: startInclusive,
      endInclusive: endInclusive,
      filter: filter,
    );
    final cells = <CalendarHeatmapCell>[];
    for (final entry in rangeMap.entries) {
      cells.add(
        AnalyticsPeriodReportCalculator.buildCell(
          date: entry.key,
          evaluations: entry.value,
        ),
      );
    }
    return List.unmodifiable(cells);
  });
}

/// Complete Milestone 2 period analytics bundle combining period report and streaks.
class AnalyticsDashboardSnapshot {
  AnalyticsDashboardSnapshot({
    required this.report,
    required List<HabitStreakSummary> streaks,
    required List<String> availableCategories,
    required List<UnifiedHabitSummary> availableHabits,
  }) : streaks = List.unmodifiable(streaks),
       availableCategories = List.unmodifiable(availableCategories),
       availableHabits = List.unmodifiable(availableHabits);

  final PeriodAnalyticsReport report;
  final List<HabitStreakSummary> streaks;
  final List<String> availableCategories;
  final List<UnifiedHabitSummary> availableHabits;
}

/// Read-only period analytics report and dashboard snapshot reader.
class AnalyticsReportReader {
  const AnalyticsReportReader(this._db);

  final AppDatabase _db;

  Future<PeriodAnalyticsReport> readPeriodReport({
    required LocalDate startInclusive,
    required LocalDate endInclusive,
    HabitAnalyticsFilter filter = const HabitAnalyticsFilter(),
  }) => _db.transaction(() async {
    final rangeMap = await UnifiedHabitHistoryReader(_db).readRange(
      startInclusive: startInclusive,
      endInclusive: endInclusive,
      filter: filter,
    );
    return AnalyticsPeriodReportCalculator.buildReport(
      startInclusive: startInclusive,
      endInclusive: endInclusive,
      evaluationsByDate: rangeMap,
    );
  });

  Future<AnalyticsDashboardSnapshot> readDashboardSnapshot({
    required LocalDate startInclusive,
    required LocalDate endInclusive,
    required LocalDate asOfDate,
    StreakCompletionMode streakMode =
        StreakCompletionMode.completedAndRecovered,
    HabitAnalyticsFilter filter = const HabitAnalyticsFilter(),
  }) => _db.transaction(() async {
    final report = await readPeriodReport(
      startInclusive: startInclusive,
      endInclusive: endInclusive,
      filter: filter,
    );
    final streaks = await HabitStreakReader(_db)
        .readAllStreaks(asOfDate: asOfDate, mode: streakMode, filter: filter);
    final allHabits = await UnifiedHabitRegistryReader(_db)
        .readAll(asOfDate: asOfDate);
    final visibleHabits = allHabits.where((h) {
      if (h.trackingType == HabitTrackingType.unconfigured) return false;
      return filter.includePrivate ||
          (h.metadata != null && !h.metadata!.isPrivate);
    }).toList();
    final categories = <String>{
      for (final h in visibleHabits) h.metadata?.category ?? 'Unclassified',
    }.toList()..sort();

    return AnalyticsDashboardSnapshot(
      report: report,
      streaks: streaks,
      availableCategories: categories,
      availableHabits: visibleHabits,
    );
  });
}

/// Per-date score impact of a proposed counter target correction.
class CorrectionDateScoreImpact {
  const CorrectionDateScoreImpact({
    required this.date,
    required this.beforeScorePercent,
    required this.afterScorePercent,
  });

  final LocalDate date;
  final double? beforeScorePercent;
  final double? afterScorePercent;
}

/// Read-only preview of how a proposed counter target correction changes
/// Milestone 2 daily weighted scores and scheduled-occurrence streaks.
class AnalyticsCorrectionImpactPreview {
  AnalyticsCorrectionImpactPreview({
    required this.preview,
    required List<CorrectionDateScoreImpact> dateScoreImpacts,
    required this.beforeStreakWithRecovery,
    required this.afterStreakWithRecovery,
    required this.beforeStreakCompletedOnly,
    required this.afterStreakCompletedOnly,
  }) : dateScoreImpacts = List.unmodifiable(dateScoreImpacts);

  final CounterCorrectionPreview preview;
  final List<CorrectionDateScoreImpact> dateScoreImpacts;
  final HabitStreakSummary beforeStreakWithRecovery;
  final HabitStreakSummary afterStreakWithRecovery;
  final HabitStreakSummary beforeStreakCompletedOnly;
  final HabitStreakSummary afterStreakCompletedOnly;
}

/// Evaluates the exact before/after Milestone 2 score and streak impact for a
/// counter target correction proposal inside one read-only transaction.
class AnalyticsCorrectionImpactReader {
  const AnalyticsCorrectionImpactReader(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<AnalyticsCorrectionImpactPreview> previewImpact(
    CounterTargetCorrectionProposal proposal,
  ) => _db.transaction(() async {
    final preview = await CounterCorrectionPreviewer(
      _db,
      _clock,
    ).preview(proposal);
    final asOfDate = preview.previewedOnLocalDate;
    final historyReader = UnifiedHabitHistoryReader(_db);

    final impactByDate = <LocalDate, CounterCorrectionOccurrenceImpact>{
      for (final occ in preview.affectedOccurrences) occ.date: occ,
    };

    final dateScoreImpacts = <CorrectionDateScoreImpact>[];
    for (final occ in preview.affectedOccurrences) {
      final dayEvals = await historyReader.readDay(date: occ.date);
      final beforeSummary = DailyWeightedScoreCalculator.calculate(
        date: occ.date,
        evaluations: dayEvals,
      );
      final afterEvals = [
        for (final eval in dayEvals)
          if (eval.habitId == proposal.habitId)
            _applyProposedOccurrenceImpact(eval, occ)
          else
            eval,
      ];
      final afterSummary = DailyWeightedScoreCalculator.calculate(
        date: occ.date,
        evaluations: afterEvals,
      );
      dateScoreImpacts.add(
        CorrectionDateScoreImpact(
          date: occ.date,
          beforeScorePercent: beforeSummary.weightedScorePercent,
          afterScorePercent: afterSummary.weightedScorePercent,
        ),
      );
    }

    final earliest =
        await historyReader.findEarliestVersionStart(proposal.habitId) ??
        asOfDate;
    final beforeHabitEvals = await historyReader.readHabitRange(
      habitId: proposal.habitId,
      startInclusive: earliest,
      endInclusive: asOfDate,
    );
    final afterHabitEvals = [
      for (final eval in beforeHabitEvals)
        if (impactByDate.containsKey(eval.date))
          _applyProposedOccurrenceImpact(eval, impactByDate[eval.date]!)
        else
          eval,
    ];
    final includeInStreak = beforeHabitEvals.isEmpty
        ? true
        : beforeHabitEvals.last.includeInStreak;

    return AnalyticsCorrectionImpactPreview(
      preview: preview,
      dateScoreImpacts: dateScoreImpacts,
      beforeStreakWithRecovery: HabitStreakEvaluator.evaluate(
        habitId: proposal.habitId,
        habitName: preview.versionName,
        asOfDate: asOfDate,
        chronologicalEvaluations: beforeHabitEvals,
        mode: StreakCompletionMode.completedAndRecovered,
        includeInStreak: includeInStreak,
      ),
      afterStreakWithRecovery: HabitStreakEvaluator.evaluate(
        habitId: proposal.habitId,
        habitName: preview.versionName,
        asOfDate: asOfDate,
        chronologicalEvaluations: afterHabitEvals,
        mode: StreakCompletionMode.completedAndRecovered,
        includeInStreak: includeInStreak,
      ),
      beforeStreakCompletedOnly: HabitStreakEvaluator.evaluate(
        habitId: proposal.habitId,
        habitName: preview.versionName,
        asOfDate: asOfDate,
        chronologicalEvaluations: beforeHabitEvals,
        mode: StreakCompletionMode.completedOnly,
        includeInStreak: includeInStreak,
      ),
      afterStreakCompletedOnly: HabitStreakEvaluator.evaluate(
        habitId: proposal.habitId,
        habitName: preview.versionName,
        asOfDate: asOfDate,
        chronologicalEvaluations: afterHabitEvals,
        mode: StreakCompletionMode.completedOnly,
        includeInStreak: includeInStreak,
      ),
    );
  });

  UnifiedHabitDayEvaluation _applyProposedOccurrenceImpact(
    UnifiedHabitDayEvaluation original,
    CounterCorrectionOccurrenceImpact impact,
  ) {
    final HabitAnalyticsStatus proposedStatus;
    if (original.status == HabitAnalyticsStatus.failed ||
        original.status == HabitAnalyticsStatus.recovered ||
        original.status == HabitAnalyticsStatus.excused) {
      proposedStatus = original.status;
    } else {
      proposedStatus = switch (impact.proposedProgressStatus) {
        CounterProgressStatus.pending => HabitAnalyticsStatus.pending,
        CounterProgressStatus.partial => HabitAnalyticsStatus.partial,
        CounterProgressStatus.completed => HabitAnalyticsStatus.completed,
      };
    }
    final ratio = (impact.recordedTotal / impact.proposedTarget).clamp(
      0.0,
      1.0,
    );
    return UnifiedHabitDayEvaluation(
      habitId: original.habitId,
      versionId: original.versionId,
      name: original.name,
      date: original.date,
      trackingType: original.trackingType,
      status: proposedStatus,
      applicabilityReason: original.applicabilityReason,
      priority: original.priority,
      category: original.category,
      symbol: original.symbol,
      isPrivate: original.isPrivate,
      includeInScore: original.includeInScore,
      includeInStreak: original.includeInStreak,
      hasMetadata: original.hasMetadata,
      partialRatio: ratio,
      summaryText: original.summaryText,
      hasOccurrence: original.hasOccurrence,
    );
  }
}
