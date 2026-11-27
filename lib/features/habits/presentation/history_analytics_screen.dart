import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/counter_habit_providers.dart';
import '../data/habit_analytics_reader.dart';
import '../data/unified_habit_registry.dart';
import '../domain/habit_analytics.dart';
import '../domain/habit_metadata.dart';
import '../domain/habit_schedule.dart';

enum AnalyticsPeriodPreset { last7Days, last30Days, currentMonth }

/// Read-only History and Analytics view for Milestone 2.
/// Displays filter controls, private-visibility switch, interactive calendar/range
/// heatmap, selected-day inspection, per-habit scheduled streaks and period
/// weighted-score/coverage reports without creating occurrences or mutating data.
class HistoryAnalyticsView extends ConsumerStatefulWidget {
  const HistoryAnalyticsView({super.key, required this.asOfDate});

  final LocalDate asOfDate;

  @override
  ConsumerState<HistoryAnalyticsView> createState() =>
      _HistoryAnalyticsViewState();
}

class _HistoryAnalyticsViewState extends ConsumerState<HistoryAnalyticsView> {
  AnalyticsPeriodPreset _preset = AnalyticsPeriodPreset.last7Days;
  StreakCompletionMode _streakMode = StreakCompletionMode.completedAndRecovered;
  bool _showPrivate = false;
  String? _selectedCategory;
  HabitTrackingType? _selectedType;
  HabitPriority? _selectedPriority;
  String? _selectedHabitId;
  late LocalDate _selectedDate;

  late Future<AnalyticsDashboardSnapshot> _snapshotFuture;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.asOfDate;
    _load();
  }

  @override
  void didUpdateWidget(covariant HistoryAnalyticsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asOfDate.compareTo(widget.asOfDate) != 0) {
      _selectedDate = widget.asOfDate;
      _load();
    }
  }

  (LocalDate, LocalDate) _resolveRange() {
    final end = widget.asOfDate;
    switch (_preset) {
      case AnalyticsPeriodPreset.last7Days:
        return (_daysBefore(end, 6), end);
      case AnalyticsPeriodPreset.last30Days:
        return (_daysBefore(end, 29), end);
      case AnalyticsPeriodPreset.currentMonth:
        return (LocalDate(end.year, end.month, 1), end);
    }
  }

  LocalDate _daysBefore(LocalDate d, int days) {
    final prev = DateTime.utc(d.year, d.month, d.day - days);
    return LocalDate(prev.year, prev.month, prev.day);
  }

  String _formatDate(LocalDate d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _formatPercent(double? value) =>
      value == null ? 'N/A' : '${value.toStringAsFixed(1)}%';

  void _load() {
    final (start, end) = _resolveRange();
    if (_selectedDate.compareTo(start) < 0 ||
        _selectedDate.compareTo(end) > 0) {
      _selectedDate = widget.asOfDate;
    }
    final generation = ++_loadGeneration;
    final reader = ref.read(analyticsReportReaderProvider);
    final asOfDate = widget.asOfDate;
    final streakMode = _streakMode;
    final category = _selectedCategory;
    final habitId = _selectedHabitId;
    final trackingType = _selectedType;
    final priority = _selectedPriority;
    final includePrivate = _showPrivate;

    Future<AnalyticsDashboardSnapshot> readSnapshot(
      String? selectedCategory,
      String? selectedHabitId,
    ) => reader.readDashboardSnapshot(
      startInclusive: start,
      endInclusive: end,
      asOfDate: asOfDate,
      streakMode: streakMode,
      filter: HabitAnalyticsFilter(
        habitId: selectedHabitId,
        category: selectedCategory,
        trackingType: trackingType,
        priority: priority,
        includePrivate: includePrivate,
      ),
    );

    _snapshotFuture = () async {
      final snapshot = await readSnapshot(category, habitId);
      if (!mounted || generation != _loadGeneration) return snapshot;
      final invalidCategory =
          category != null && !snapshot.availableCategories.contains(category);
      final invalidHabit =
          habitId != null &&
          !snapshot.availableHabits.any((h) => h.habitId == habitId);
      if (!invalidCategory && !invalidHabit) return snapshot;
      if (invalidCategory) _selectedCategory = null;
      if (invalidHabit) _selectedHabitId = null;
      return readSnapshot(_selectedCategory, _selectedHabitId);
    }();
  }

  void _reload() => setState(_load);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AnalyticsDashboardSnapshot>(
      // A privacy change must discard the previous snapshot immediately.
      key: ValueKey(_showPrivate),
      future: _snapshotFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Could not load history and analytics.'),
              TextButton(onPressed: _reload, child: const Text('Try again')),
            ],
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!;
        final report = data.report;
        final selectedCell = report.dailyCells.firstWhere(
          (c) => c.date.compareTo(_selectedDate) == 0,
          orElse: () => report.dailyCells.last,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildFilterCard(data),
            const SizedBox(height: 16),
            _buildHeatmapCard(context, report, selectedCell),
            const SizedBox(height: 16),
            _buildSelectedDayCard(context, selectedCell),
            const SizedBox(height: 16),
            _buildPeriodReportCard(context, report),
            const SizedBox(height: 16),
            _buildStreaksCard(context, data.streaks),
          ],
        );
      },
    );
  }

  Widget _buildFilterCard(AnalyticsDashboardSnapshot data) {
    final categories = data.availableCategories;
    final habits = data.availableHabits;
    final validCategory = categories.contains(_selectedCategory)
        ? _selectedCategory
        : null;
    final validHabit = habits.any((h) => h.habitId == _selectedHabitId)
        ? _selectedHabitId
        : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Filters & Privacy',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show private or unclassified habits'),
              subtitle: const Text('Only use this in a private place.'),
              value: _showPrivate,
              onChanged: (v) {
                _showPrivate = v;
                _reload();
              },
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Last 7 days'),
                  selected: _preset == AnalyticsPeriodPreset.last7Days,
                  onSelected: (_) {
                    _preset = AnalyticsPeriodPreset.last7Days;
                    _reload();
                  },
                ),
                ChoiceChip(
                  label: const Text('Last 30 days'),
                  selected: _preset == AnalyticsPeriodPreset.last30Days,
                  onSelected: (_) {
                    _preset = AnalyticsPeriodPreset.last30Days;
                    _reload();
                  },
                ),
                ChoiceChip(
                  label: const Text('Current month'),
                  selected: _preset == AnalyticsPeriodPreset.currentMonth,
                  onSelected: (_) {
                    _preset = AnalyticsPeriodPreset.currentMonth;
                    _reload();
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              key: ValueKey(('category', validCategory)),
              initialValue: validCategory,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Filter category'),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text(
                    'All categories',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                for (final c in categories)
                  DropdownMenuItem(
                    value: c,
                    child: Text(c, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) {
                _selectedCategory = v;
                _reload();
              },
            ),
            DropdownButtonFormField<HabitTrackingType?>(
              initialValue: _selectedType,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Filter tracking type',
              ),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text(
                    'All tracking types',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                for (final t in HabitTrackingType.values.where(
                  (e) => e != HabitTrackingType.unconfigured,
                ))
                  DropdownMenuItem(
                    value: t,
                    child: Text(t.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) {
                _selectedType = v;
                _reload();
              },
            ),
            DropdownButtonFormField<String?>(
              key: ValueKey(('habit', validHabit)),
              initialValue: validHabit,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Filter habit'),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('All habits', overflow: TextOverflow.ellipsis),
                ),
                for (final h in habits)
                  DropdownMenuItem(
                    value: h.habitId,
                    child: Text(
                      h.name ?? h.habitId,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                _selectedHabitId = v;
                _reload();
              },
            ),
            DropdownButtonFormField<StreakCompletionMode>(
              initialValue: _streakMode,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Streak mode'),
              items: const [
                DropdownMenuItem(
                  value: StreakCompletionMode.completedAndRecovered,
                  child: Text(
                    'Completed + Recovered',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: StreakCompletionMode.completedOnly,
                  child: Text(
                    'Completed only',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: (v) {
                if (v != null) {
                  _streakMode = v;
                  _reload();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeatmapCard(
    BuildContext context,
    PeriodAnalyticsReport report,
    CalendarHeatmapCell selectedCell,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Calendar Heatmap (${_formatDate(report.startInclusive)} to ${_formatDate(report.endInclusive)})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Tap any date to inspect its weighted score, recording coverage and habit statuses.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final cell in report.dailyCells)
                  _buildHeatmapTile(context, cell, selectedCell.date),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeatmapTile(
    BuildContext context,
    CalendarHeatmapCell cell,
    LocalDate selectedDate,
  ) {
    final isSelected = cell.date.compareTo(selectedDate) == 0;
    final dateStr = _formatDate(cell.date);
    final shortDate =
        '${cell.date.month.toString().padLeft(2, '0')}-${cell.date.day.toString().padLeft(2, '0')}';
    final s = cell.scoreSummary;
    final scoreLabel = s.availability == ScoreAvailability.noData
        ? 'N/A'
        : '${s.weightedScorePercent!.toStringAsFixed(0)}%';
    final incompleteTag = s.isIncompleteRecording
        ? ' (partial log)'
        : s.unavailableRecordedScoreCount > 0
        ? ' (partial score)'
        : '';

    return Semantics(
      selected: isSelected,
      label:
          '$dateStr, score $scoreLabel$incompleteTag, intensity ${cell.intensity.name}',
      child: OutlinedButton(
        key: Key('heatmap-cell-$dateStr'),
        style: OutlinedButton.styleFrom(
          side: isSelected
              ? BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                )
              : null,
        ),
        onPressed: () => setState(() => _selectedDate = cell.date),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(shortDate),
            Text('$scoreLabel$incompleteTag'),
            Text('intensity: ${cell.intensity.name}'),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectedDayCard(
    BuildContext context,
    CalendarHeatmapCell selectedCell,
  ) {
    final s = selectedCell.scoreSummary;
    final dateStr = _formatDate(selectedCell.date);
    final scoreStr = _formatPercent(s.weightedScorePercent);
    final incompleteNote = s.isIncompleteRecording
        ? ' (incomplete recording: ${s.pendingApplicableCount} pending)'
        : '';

    return Card(
      key: const Key('selected-day-inspection-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Selected Day: $dateStr',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('Daily weighted score: $scoreStr$incompleteNote'),
            Text(
              'Score coverage: ${s.validScoreCount} scored, '
              '${s.unavailableRecordedScoreCount} recorded N/A '
              '(${_formatPercent(s.scoreCoveragePercent)})',
            ),
            if (s.unavailableRecordedScoreCount > 0)
              const Text(
                'Score is incomplete: recorded outcomes with unavailable scores are excluded.',
              ),
            Text(
              'Habit recording coverage: ${s.recordedApplicableCount}/${s.applicableHabitCount} '
              '(${_formatPercent(s.recordingCoveragePercent)})',
            ),
            if (s.applicableChecklistItems > 0)
              Text(
                'Checklist item coverage: ${s.recordedChecklistItems}/${s.applicableChecklistItems} '
                '(${_formatPercent(s.checklistItemCoveragePercent)})',
              ),
            const SizedBox(height: 8),
            if (selectedCell.evaluations.isEmpty)
              const Text('No visible habits for this filter on this date.')
            else
              for (final eval in selectedCell.evaluations)
                Text(
                  '• ${eval.name} [${eval.category}, weight ${eval.priorityWeight}]: '
                  '${eval.status.name} (${eval.summaryText})'
                  '${eval.includeInScore ? (eval.scoringUnavailable && eval.isRecordedApplicable && eval.status != HabitAnalyticsStatus.excused ? ' [score N/A]' : '') : ' [excluded from score]'}',
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeriodReportCard(
    BuildContext context,
    PeriodAnalyticsReport report,
  ) {
    return Card(
      key: const Key('period-analytics-report-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Period Summary Report',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Average daily weighted score: ${_formatPercent(report.averageWeightedScorePercent)}',
            ),
            Text(
              'Overall period weighted score: ${_formatPercent(report.overallWeightedScorePercent)}',
            ),
            Text(
              'Score coverage: ${report.validScoreCount} scored, '
              '${report.unavailableRecordedScoreCount} recorded N/A '
              '(${_formatPercent(report.scoreCoveragePercent)})',
            ),
            if (report.unavailableRecordedScoreCount > 0)
              const Text(
                'Period score is incomplete: recorded outcomes with unavailable scores are excluded.',
              ),
            Text(
              'Eligible score days: ${report.eligibleScoreDays} | '
              'No Data days: ${report.noDataDays} | '
              'Incomplete recording days: ${report.incompleteRecordingDays}',
            ),
            Text(
              'Overall habit recording coverage: ${report.totalRecordedHabits}/${report.totalApplicableHabits} '
              '(${_formatPercent(report.overallRecordingCoveragePercent)})',
            ),
            Text(
              'Overall checklist item coverage: ${_formatPercent(report.overallChecklistItemCoveragePercent)}',
            ),
            Text(
              'Status counts — Completed: ${report.totalCompletedHabits} | '
              'Recovered: ${report.totalRecoveredHabits} | '
              'Partial: ${report.totalPartialHabits} | '
              'Failed: ${report.totalFailedHabits} | '
              'Pending: ${report.totalPendingHabits} | '
              'Excused: ${report.totalExcusedHabits}',
            ),
            if (report.categoryBreakdowns.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Category breakdown',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final cat in report.categoryBreakdowns)
                Text(
                  '• ${cat.category}: score ${_formatPercent(cat.weightedScorePercent)}, '
                  'coverage ${cat.recordedCount}/${cat.applicableCount} '
                  '(${_formatPercent(cat.recordingCoveragePercent)})',
                ),
            ],
            if (report.habitSummaries.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Per-habit period breakdown',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final h in report.habitSummaries)
                Text(
                  '• ${h.name} (${h.trackingType.name}, weight ${h.priority.weight}): '
                  'score ${_formatPercent(h.weightedScorePercent)}, '
                  'coverage ${_formatPercent(h.recordingCoveragePercent)} '
                  '[completed ${h.completedDays}, recovered ${h.recoveredDays}, '
                  'partial ${h.partialDays}, failed ${h.failedDays}, '
                  'pending ${h.pendingDays}, excused ${h.excusedDays}]',
                ),
            ],
            const SizedBox(height: 12),
            Text(
              report.disclaimer,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStreaksCard(
    BuildContext context,
    List<HabitStreakSummary> streaks,
  ) {
    return Card(
      key: const Key('habit-streaks-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Scheduled-Occurrence Streaks',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Unscheduled, paused and excused dates neither increment nor break streaks. '
              'Past pending dates and unknown or conflicting data make a streak unresolved; '
              'current-day pending does not reset it.',
            ),
            const SizedBox(height: 12),
            if (streaks.isEmpty)
              const Text('No visible habits for streak evaluation.')
            else
              for (final s in streaks) ...[
                Text(
                  '• ${s.habitName}: current ${s.currentStreak} | '
                  'longest ${s.longestStreak} | state: ${s.state.name}',
                ),
                Text(
                  '  Applicable: ${s.applicableDaysCount}, completed: ${s.completedDaysCount}, '
                  'recovered: ${s.recoveredDaysCount}, failed: ${s.failedDaysCount}, '
                  'excused: ${s.excusedDaysCount}, skipped unscheduled/paused: ${s.skippedNotApplicableCount}',
                ),
                if (s.unresolvedPendingDates.isNotEmpty)
                  Text(
                    '  Unresolved past pending dates: '
                    '${s.unresolvedPendingDates.map(_formatDate).join(', ')}',
                  ),
              ],
          ],
        ),
      ),
    );
  }
}
