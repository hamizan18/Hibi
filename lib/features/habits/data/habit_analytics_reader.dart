import 'dart:convert';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/counter_progress.dart';
import '../domain/habit_analytics.dart';
import '../domain/habit_schedule.dart';
import 'counter_correction_preview.dart';
import 'counter_recovery_store.dart';
import 'habit_lifecycle.dart';
import 'habit_metadata_store.dart';
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
  }) => _readStreakForHabit(
    habitId: habitId,
    asOfDate: asOfDate,
    mode: mode,
    includePrivate: true,
  );

  Future<HabitStreakSummary> _readStreakForHabit({
    required String habitId,
    required LocalDate asOfDate,
    required StreakCompletionMode mode,
    required bool includePrivate,
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
    // A hidden date is a privacy boundary, not a skipped occurrence: using
    // either its status or earlier visible dates could reveal continuity across it.
    var visibleStart = 0;
    if (!includePrivate) {
      for (var i = 0; i < evaluations.length; i++) {
        if (!evaluations[i].hasMetadata || evaluations[i].isPrivate) {
          visibleStart = i + 1;
        }
      }
    }
    return HabitStreakEvaluator.evaluate(
      habitId: habitId,
      habitName: latest.name,
      asOfDate: asOfDate,
      chronologicalEvaluations: evaluations.skip(visibleStart),
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
        await _readStreakForHabit(
          habitId: habit.habitId,
          asOfDate: asOfDate,
          mode: mode,
          includePrivate: filter.includePrivate,
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
    // Category choices describe the whole selected period, independently of
    // the selected category and other filters, but never bypass privacy.
    final categoryDays = await UnifiedHabitHistoryReader(_db).readRange(
      startInclusive: startInclusive,
      endInclusive: endInclusive,
      filter: HabitAnalyticsFilter(includePrivate: filter.includePrivate),
    );
    final categories = <String>{
      for (final evaluations in categoryDays.values)
        for (final evaluation in evaluations)
          if (evaluation.trackingType != HabitTrackingType.unconfigured &&
              evaluation.applicabilityReason !=
                  HabitApplicabilityReason.beforeStart)
            evaluation.category,
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

// The normal correction preview API remains usable without analytics. An
// analytics-derived preview carries its extra read set privately, so callers
// that pass impact.preview directly to the writer cannot lose the binding.
class _ImpactBoundCorrectionPreview extends CounterCorrectionPreview
    implements CorrectionPreviewImpactBinding {
  _ImpactBoundCorrectionPreview(
    CounterCorrectionPreview source,
    this._database,
    this._snapshot,
  ) : super(
        proposal: source.proposal,
        previewedOnLocalDate: source.previewedOnLocalDate,
        versionName: source.versionName,
        effectiveStart: source.effectiveStart,
        effectiveEnd: source.effectiveEnd,
        originalTarget: source.originalTarget,
        proposedTarget: source.proposedTarget,
        affectedOccurrences: source.affectedOccurrences,
        totalAffectedEventCount: source.totalAffectedEventCount,
        totalAffectedResolutionCount: source.totalAffectedResolutionCount,
        totalAffectedRecoveryCount: source.totalAffectedRecoveryCount,
        scoreImpact: source.scoreImpact,
        streakImpact: source.streakImpact,
        rewardImpact: source.rewardImpact,
        achievementImpact: source.achievementImpact,
        englishConfirmationSummary: source.englishConfirmationSummary,
        snapshotSignature: source.snapshotSignature,
      );

  final AppDatabase _database;
  final String _snapshot;

  @override
  Future<bool> isImpactStale(AppDatabase database) async =>
      !identical(_database, database) ||
      await _impactSnapshot(database) != _snapshot;
}

// Include every habit table rather than only the corrected version: score
// inputs span habits, and streaks span the corrected habit's entire history.
// This deliberately errs on the side of rejecting an unrelated habit change.
// The data remains private and is never added to the public preview or audit.
Future<String> _impactSnapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND (name = 'habits' OR substr(name, 1, 6) = 'habit_') ORDER BY name",
      )
      .get();
  final snapshot = <String, List<String>>{};
  for (final table in tables) {
    final name = table.read<String>('name');
    final quotedName = name.replaceAll('"', '""');
    final rows = await db.customSelect('SELECT * FROM "$quotedName"').get();
    snapshot[name] = [for (final row in rows) jsonEncode(row.data)]..sort();
  }
  return jsonEncode(snapshot);
}

/// Evaluates score and streak impact inside one read-only transaction.
/// By default private and unclassified versions are hidden: the corrected
/// version must be public, daily scores exclude hidden contributions, and a
/// hidden streak date cuts off that date and all earlier history. Explicitly
/// set [includePrivate] to reveal those versions and their contributions.
class AnalyticsCorrectionImpactReader {
  const AnalyticsCorrectionImpactReader(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<AnalyticsCorrectionImpactPreview> previewImpact(
    CounterTargetCorrectionProposal proposal, {
    bool includePrivate = false,
  }) => _db.transaction(() async {
    if (!includePrivate) {
      final metadata = await HabitMetadataStore(_db)
          .findForVersion(proposal.versionId);
      if (metadata == null || metadata.isPrivate) {
        throw StateError(
          'Reveal private history before previewing this version',
        );
      }
    }
    final preview = await CounterCorrectionPreviewer(
      _db,
      _clock,
    ).preview(proposal);
    final asOfDate = preview.previewedOnLocalDate;
    final historyReader = UnifiedHabitHistoryReader(_db);

    final impactByDate = <LocalDate, CounterCorrectionOccurrenceImpact>{
      for (final occ in preview.affectedOccurrences) occ.date: occ,
    };
    final recoveryTotals = <LocalDate, int>{};
    final recoveryReader = CounterRecoveryReader(_db);
    for (final occ in preview.affectedOccurrences) {
      if (occ.recoveryCount > 0) {
        final recoveries = await recoveryReader.findForOccurrence(
          occ.occurrenceId,
        );
        recoveryTotals[occ.date] = recoveries.fold<int>(
          0,
          (sum, recovery) => sum + recovery.quantity,
        );
      }
    }

    final dateScoreImpacts = <CorrectionDateScoreImpact>[];
    for (final occ in preview.affectedOccurrences) {
      final dayEvals = await historyReader.readDay(
        date: occ.date,
        filter: HabitAnalyticsFilter(includePrivate: includePrivate),
      );
      final beforeSummary = DailyWeightedScoreCalculator.calculate(
        date: occ.date,
        evaluations: dayEvals,
      );
      final afterEvals = [
        for (final eval in dayEvals)
          if (eval.habitId == proposal.habitId)
            _applyProposedOccurrenceImpact(
              eval,
              occ,
              recoveryTotals[occ.date] ?? 0,
            )
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
    var visibleStart = 0;
    if (!includePrivate) {
      for (var i = 0; i < beforeHabitEvals.length; i++) {
        if (!beforeHabitEvals[i].hasMetadata || beforeHabitEvals[i].isPrivate) {
          visibleStart = i + 1;
        }
      }
    }
    final visibleHabitEvals = beforeHabitEvals.skip(visibleStart).toList();
    final afterHabitEvals = [
      for (final eval in visibleHabitEvals)
        if (impactByDate.containsKey(eval.date))
          _applyProposedOccurrenceImpact(
            eval,
            impactByDate[eval.date]!,
            recoveryTotals[eval.date] ?? 0,
          )
        else
          eval,
    ];
    final includeInStreak = visibleHabitEvals.isEmpty
        ? true
        : visibleHabitEvals.last.includeInStreak;

    final snapshot = await _impactSnapshot(_db);
    if (await CounterCorrectionPreviewer(_db, _clock).isStale(preview)) {
      throw StateError(
        'Correction preview became stale while calculating impact',
      );
    }
    return AnalyticsCorrectionImpactPreview(
      preview: _ImpactBoundCorrectionPreview(preview, _db, snapshot),
      dateScoreImpacts: dateScoreImpacts,
      beforeStreakWithRecovery: HabitStreakEvaluator.evaluate(
        habitId: proposal.habitId,
        habitName: preview.versionName,
        asOfDate: asOfDate,
        chronologicalEvaluations: visibleHabitEvals,
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
        chronologicalEvaluations: visibleHabitEvals,
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
    int recoveredTotal,
  ) {
    final HabitAnalyticsStatus proposedStatus;
    if (original.status == HabitAnalyticsStatus.failed ||
        original.status == HabitAnalyticsStatus.recovered) {
      proposedStatus =
          impact.recordedTotal + recoveredTotal >= impact.proposedTarget
          ? HabitAnalyticsStatus.recovered
          : HabitAnalyticsStatus.failed;
    } else if (original.status == HabitAnalyticsStatus.excused ||
        original.status == HabitAnalyticsStatus.conflict ||
        original.status == HabitAnalyticsStatus.unknown ||
        original.status == HabitAnalyticsStatus.notApplicable) {
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
      normalizedScore: original.normalizedScore,
      scoringUnavailable: original.scoringUnavailable,
      summaryText: original.summaryText,
      hasOccurrence: original.hasOccurrence,
    );
  }
}
