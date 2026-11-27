import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/counter_habit_providers.dart';
import '../data/counter_audit_reader.dart';
import '../data/counter_habit_overview_reader.dart';
import '../data/unified_habit_registry.dart';
import '../domain/habit_schedule.dart';

/// Read-only controls and modal inspector for a counter habit's 7-day range
/// history, range summary and six-stream local audit trail.
/// Opening or viewing never creates occurrences or mutates database records.
class CounterAuditHistoryControls extends ConsumerWidget {
  const CounterAuditHistoryControls({
    super.key,
    required this.habit,
    required this.date,
    required this.showPrivateHistory,
  });

  final UnifiedHabitSummary habit;
  final LocalDate date;
  final bool showPrivateHistory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: OutlinedButton(
        onPressed: () {
          showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (context) => FractionallySizedBox(
              heightFactor: 0.85,
              child: CounterAuditHistorySheet(
                habit: habit,
                date: date,
                showPrivateHistory: showPrivateHistory,
              ),
            ),
          );
        },
        child: const Text('View history & audit'),
      ),
    );
  }
}

class CounterAuditHistorySheet extends ConsumerStatefulWidget {
  const CounterAuditHistorySheet({
    super.key,
    required this.habit,
    required this.date,
    required this.showPrivateHistory,
  });

  final UnifiedHabitSummary habit;
  final LocalDate date;
  final bool showPrivateHistory;

  @override
  ConsumerState<CounterAuditHistorySheet> createState() =>
      _CounterAuditHistorySheetState();
}

class _CounterAuditHistorySheetState
    extends ConsumerState<CounterAuditHistorySheet> {
  late Future<({CounterHabitOverview overview, CounterAuditTrail audit})>
  _bundle;

  String _formatDate(LocalDate d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  LocalDate _daysBefore(LocalDate d, int days) {
    final prev = DateTime.utc(d.year, d.month, d.day - days);
    return LocalDate(prev.year, prev.month, prev.day);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final start = _daysBefore(widget.date, 6);
    _bundle = () async {
      final overview = await ref
          .read(counterHabitOverviewReaderProvider)
          .read(
            habitId: widget.habit.habitId,
            asOfDate: widget.date,
            rangeStartInclusive: start,
            rangeEndInclusive: widget.date,
          );
      final audit = await ref
          .read(counterAuditReaderProvider)
          .readForHabit(widget.habit.habitId);
      return (overview: overview, audit: audit);
    }();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<({CounterHabitOverview overview, CounterAuditTrail audit})>(
          future: _bundle,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Could not load history and audit trail.'),
                  TextButton(
                    onPressed: () => setState(_load),
                    child: const Text('Retry'),
                  ),
                ],
              );
            }
            final overview = snapshot.data!.overview;
            final audit = snapshot.data!.audit;
            final hasPrivateVersion =
                widget.habit.metadata?.isPrivate == true ||
                overview.configuration.allVersions.any(
                  (v) => v.metadata?.isPrivate == true,
                );
            if (hasPrivateVersion && !widget.showPrivateHistory) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'History & Audit',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Private historical configuration and audit details are hidden. '
                    'Enable "Show private or unclassified habits" on Today to inspect them.',
                  ),
                ],
              );
            }

            final summary = overview.rangeSummary;
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'History & Audit: ${widget.habit.name ?? widget.habit.habitId}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '7-day summary (${_formatDate(overview.rangeHistory.first.date)} to ${_formatDate(widget.date)})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    'Applicable: ${summary.applicableDays} | Completed: ${summary.completedDays} | '
                    'Partial: ${summary.partialDays} | Failed: ${summary.failedDays} | '
                    'Recovered: ${summary.recoveredDays} | Excused: ${summary.excusedDays} | '
                    'Pending: ${summary.pendingDays} | Conflict: ${summary.conflictDays}',
                  ),
                  Text(
                    'Recorded total: ${summary.recordedQuantityTotal} | '
                    'Recovered total: ${summary.recoveredQuantityTotal} | '
                    'Remaining deficit: ${summary.remainingDeficitTotal}',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Daily evaluations',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final item in overview.rangeHistory)
                    Text(
                      '• ${_formatDate(item.date)}: ${item.evaluation.effectiveStatus.name}'
                      '${item.evaluation.day.recorded == null ? '' : ' (${item.evaluation.day.recorded!.progress.total}/${item.evaluation.day.recorded!.progress.target} ${item.evaluation.day.recorded!.unit})'}',
                    ),
                  const Divider(height: 24),
                  Text(
                    'Version audits (${audit.versionAudits.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final va in audit.versionAudits)
                    Text('• [${va.operation}] id=${va.id}'),
                  const SizedBox(height: 8),
                  Text(
                    'Historical target correction audits (${audit.correctionAudits.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final ca in audit.correctionAudits)
                    Text(
                      '• [${_formatDate(ca.effectiveStart)} to ${ca.effectiveEnd == null ? 'open' : _formatDate(ca.effectiveEnd!)}] '
                      '${ca.previousTargetCount} -> ${ca.updatedTargetCount} ${ca.unit}'
                      '${ca.reason == null ? '' : ' (${ca.reason})'}',
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Lifecycle events (${audit.lifecycleEvents.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final le in audit.lifecycleEvents)
                    Text(
                      '• ${_formatDate(le.effectiveDate)}: ${le.previousState?.name ?? 'none'} -> ${le.state.name}'
                      '${le.reason == null ? '' : ' (${le.reason})'}',
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Progress event audits (${audit.eventAudits.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final ea in audit.eventAudits)
                    Text(
                      '• ${_formatDate(ea.occurrenceDate)}: +${ea.quantity} (event ${ea.eventId})',
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Explicit resolution audits (${audit.resolutionAudits.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final ra in audit.resolutionAudits)
                    Text(
                      '• ${_formatDate(ra.occurrenceDate)}: ${ra.resolution.state.name} '
                      '(${ra.resolution.progress}/${ra.resolution.target})'
                      '${ra.resolution.reason == null ? '' : ' — ${ra.resolution.reason}'}',
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Recovery audits (${audit.recoveryAudits.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final rec in audit.recoveryAudits)
                    Text(
                      '• For ${_formatDate(rec.occurrenceDate)} on ${_formatDate(rec.recovery.recoveryDate)}: '
                      '+${rec.recovery.quantity} (remaining deficit ${rec.recovery.remainingDeficit})'
                      '${rec.recovery.note == null ? '' : ' — ${rec.recovery.note}'}',
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
