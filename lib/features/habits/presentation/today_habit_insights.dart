import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/counter_habit_providers.dart';
import '../domain/habit_analytics.dart';
import '../domain/habit_schedule.dart';

/// Read-only, privacy-filtered recent scores and scheduled-occurrence streaks.
class TodayHabitInsights extends ConsumerStatefulWidget {
  const TodayHabitInsights({super.key, required this.date, required this.includePrivate, required this.revision});

  final LocalDate date;
  final bool includePrivate;
  final int revision;

  @override
  ConsumerState<TodayHabitInsights> createState() => _TodayHabitInsightsState();
}

class _TodayHabitInsightsState extends ConsumerState<TodayHabitInsights> {
  late Future<(List<CalendarHeatmapCell>, List<HabitStreakSummary>)> _data;
  LocalDate? _selected;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TodayHabitInsights oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.date != widget.date || oldWidget.includePrivate != widget.includePrivate || oldWidget.revision != widget.revision) {
      if (oldWidget.date != widget.date || oldWidget.includePrivate != widget.includePrivate) _selected = null;
      _load();
    }
  }

  void _load() {
    final date = widget.date;
    final startDate = DateTime.utc(date.year, date.month, date.day).subtract(const Duration(days: 6));
    final start = startDate.year < 1 ? LocalDate(1, 1, 1) : LocalDate(startDate.year, startDate.month, startDate.day);
    final filter = HabitAnalyticsFilter(includePrivate: widget.includePrivate);
    final heatmap = ref.read(calendarHeatmapReaderProvider);
    final streaks = ref.read(habitStreakReaderProvider);
    _data = () async {
      final cells = await heatmap.readRangeHeatmap(startInclusive: start, endInclusive: date, filter: filter);
      final summaries = await streaks.readAllStreaks(asOfDate: date, filter: filter);
      return (cells, summaries);
    }();
  }

  String _date(LocalDate date) => '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String _score(CalendarHeatmapCell cell) {
    final score = cell.scoreSummary.weightedScorePercent;
    return score == null ? 'No score data' : '${score.toStringAsFixed(0)}%';
  }

  String _streak(HabitStreakSummary streak) => switch (streak.state) {
    StreakResolutionState.noApplicableHistory => 'No streak data',
    StreakResolutionState.excluded => 'Streak excluded',
    StreakResolutionState.unresolved => 'Streak unresolved',
    StreakResolutionState.activePendingToday => '${streak.currentStreak} scheduled completions · today pending',
    StreakResolutionState.active => '${streak.currentStreak} scheduled completions',
    StreakResolutionState.broken => 'Streak broken',
  };

  String _status(HabitAnalyticsStatus status) => switch (status) {
    HabitAnalyticsStatus.notApplicable => 'Not scheduled or active',
    HabitAnalyticsStatus.unknown => 'Unknown',
    HabitAnalyticsStatus.pending => 'Pending',
    HabitAnalyticsStatus.partial => 'Partial',
    HabitAnalyticsStatus.completed => 'Completed',
    HabitAnalyticsStatus.failed => 'Failed',
    HabitAnalyticsStatus.recovered => 'Recovered',
    HabitAnalyticsStatus.excused => 'Excused',
    HabitAnalyticsStatus.conflict => 'Conflict',
  };

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<(List<CalendarHeatmapCell>, List<HabitStreakSummary>)>(
          // Never retain a private snapshot while the privacy filter changes.
          key: ValueKey(widget.includePrivate),
          future: _data,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Could not load insights.'),
                TextButton(onPressed: () => setState(_load), child: const Text('Try again')),
              ]);
            }
            if (snapshot.connectionState != ConnectionState.done || !snapshot.hasData) {
              return const Text('Loading insights…');
            }
            final (cells, streaks) = snapshot.data!;
            if (cells.isEmpty) return const Text('No insight data');
            final selected = cells.where((cell) => cell.date == (_selected ?? widget.date)).firstOrNull ?? cells.last;
            final colors = Theme.of(context).colorScheme;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Your last 7 days', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text('Weighted score · select a day for details'),
              const SizedBox(height: 12),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final cell in cells)
                  ActionChip(
                    backgroundColor: cell.date == selected.date ? colors.primaryContainer : null,
                    tooltip: '${_date(cell.date)}: ${_score(cell)}',
                    label: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('${cell.date.month}/${cell.date.day}'),
                      if (cell.scoreSummary.weightedScorePercent != null)
                        SizedBox(
                          width: 40,
                          child: LinearProgressIndicator(
                            value: cell.scoreSummary.weightedScorePercent! / 100,
                          ),
                        )
                      else
                        const SizedBox(height: 4),
                      Text(_score(cell) == 'No score data' ? '—' : _score(cell)),
                    ]),
                    onPressed: () => setState(() => _selected = cell.date),
                  ),
              ]),
              const SizedBox(height: 12),
              Text('${_date(selected.date)} · ${_score(selected)}', style: Theme.of(context).textTheme.titleSmall),
              if (selected.scoreSummary.isIncompleteRecording) const Text('Some habits are still pending.'),
              if (selected.evaluations.isEmpty) const Text('No visible habit data for this day.')
              else for (final evaluation in selected.evaluations)
                Text('${evaluation.name}: ${_status(evaluation.status)}'),
              const SizedBox(height: 12),
              Text('Current streaks', style: Theme.of(context).textTheme.titleSmall),
              if (streaks.isEmpty) const Text('No streak data')
              else for (final streak in streaks) Text('${streak.habitName}: ${_streak(streak)}'),
            ]);
          },
        ),
      ),
    );
  }
}
