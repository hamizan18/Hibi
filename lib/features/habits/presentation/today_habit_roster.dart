import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/counter_habit_providers.dart';
import '../data/habit_lifecycle.dart';
import '../data/unified_habit_registry.dart';
import '../domain/habit_schedule.dart';
import 'boolean_duration_today_cards.dart';
import 'checklist_avoidance_today_cards.dart';
import 'checklist_recovery_controls.dart';
import 'counter_audit_history_sheet.dart';
import 'counter_correction_controls.dart';
import 'counter_future_version_controls.dart';
import 'counter_lifecycle_controls.dart';
import 'counter_recovery_controls.dart';
import 'counter_today_card.dart';
import 'non_counter_version_audit_controls.dart';
import 'numeric_today_cards.dart';

/// A read-only roster. Opening this widget never creates an occurrence.
class TodayHabitRoster extends ConsumerStatefulWidget {
  const TodayHabitRoster({super.key, required this.date});

  final LocalDate date;

  @override
  ConsumerState<TodayHabitRoster> createState() => _TodayHabitRosterState();
}

class _TodayHabitRosterState extends ConsumerState<TodayHabitRoster> {
  late Future<List<UnifiedHabitSummary>> _roster;
  bool _showPrivate = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TodayHabitRoster oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.date.compareTo(widget.date) != 0) _load();
  }

  void _load() {
    _roster = ref
        .read(unifiedHabitRegistryReaderProvider)
        .readAll(asOfDate: widget.date);
  }

  void _refresh() => setState(_load);

  void _entrySaved() {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Entry saved')));
  }

  void _lifecycleChanged() {
    _refresh();
    _entrySaved();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<UnifiedHabitSummary>>(
      future: _roster,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Column(
            children: [
              const Text('Could not load habits.'),
              TextButton(onPressed: _refresh, child: const Text('Try again')),
            ],
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final visible = snapshot.data!.where((habit) {
          return _showPrivate ||
              (habit.metadata != null && !habit.metadata!.isPrivate);
        }).toList();
        visible.sort((a, b) {
          final order = (a.metadata?.displayOrder ?? 0).compareTo(
            b.metadata?.displayOrder ?? 0,
          );
          return order != 0 ? order : a.habitId.compareTo(b.habitId);
        });
        return IgnorePointer(
          ignoring: snapshot.connectionState != ConnectionState.done,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show private or unclassified habits'),
                subtitle: const Text('Only use this in a private place.'),
                value: _showPrivate,
                onChanged: (value) => setState(() => _showPrivate = value),
              ),
              if (visible.isEmpty)
                const Text(
                  'No visible habits today. Create one to get started.',
                ),
              for (final habit in visible) _habitCard(habit),
              if (snapshot.connectionState != ConnectionState.done)
                const LinearProgressIndicator()
              else
                const SizedBox(height: 4),
            ],
          ),
        );
      },
    );
  }

  Widget _habitCard(UnifiedHabitSummary habit) {
    final applicability = habit.applicability.applicability;
    return Card(
      key: ValueKey(habit.habitId),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              habit.name ?? 'Unconfigured habit',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (applicability == HabitApplicability.unknown)
              const Text('Status unknown: configuration is incomplete.')
            else if (habit.applicability.reason ==
                HabitApplicabilityReason.beforeStart)
              const Text('Not started yet. You can pause from the start date.')
            else if (applicability == HabitApplicability.notApplicable)
              const Text('Not scheduled or not active today.')
            else
              switch (habit.trackingType) {
                HabitTrackingType.counter => CounterTodayCard(
                  habit: habit,
                  date: widget.date,
                  onChanged: _entrySaved,
                ),
                HabitTrackingType.checklist => ChecklistTodayCard(
                  habit: habit,
                  date: widget.date,
                  onChanged: _entrySaved,
                ),
                HabitTrackingType.avoidance => AvoidanceTodayCard(
                  habit: habit,
                  date: widget.date,
                  onChanged: _entrySaved,
                ),
                HabitTrackingType.boolean => BooleanTodayCard(
                  habit: habit,
                  date: widget.date,
                  onChanged: _entrySaved,
                ),
                HabitTrackingType.duration => DurationTodayCard(
                  habit: habit,
                  date: widget.date,
                  onChanged: _entrySaved,
                ),
                HabitTrackingType.measurement ||
                HabitTrackingType.timeOfDay ||
                HabitTrackingType.range => NumericTodayCard(
                  habit: habit,
                  date: widget.date,
                  onChanged: _entrySaved,
                ),
                HabitTrackingType.unconfigured => const Text(
                  'Status unknown: tracking type is not configured.',
                ),
              },
            if (habit.trackingType != HabitTrackingType.unconfigured)
              CounterLifecycleControls(
                habit: habit,
                date: widget.date,
                onChanged: _lifecycleChanged,
              ),
            if (habit.applicability.lifecycleState ==
                    HabitLifecycleState.active &&
                habit.trackingType == HabitTrackingType.counter)
              CounterRecoveryControls(
                habit: habit,
                date: widget.date,
                showPrivateHistory: _showPrivate,
                onChanged: _entrySaved,
              ),
            if (habit.trackingType == HabitTrackingType.counter) ...[
              CounterFutureVersionControls(
                habit: habit,
                date: widget.date,
                showPrivateHistory: _showPrivate,
                onChanged: _lifecycleChanged,
              ),
              CounterCorrectionControls(
                habit: habit,
                date: widget.date,
                showPrivateHistory: _showPrivate,
                onChanged: _lifecycleChanged,
              ),
              CounterAuditHistoryControls(
                habit: habit,
                date: widget.date,
                showPrivateHistory: _showPrivate,
              ),
            ] else if (habit.trackingType != HabitTrackingType.unconfigured)
              NonCounterVersionAndAuditControls(
                habit: habit,
                date: widget.date,
                showPrivateHistory: _showPrivate,
                onChanged: _lifecycleChanged,
              ),
            if (habit.applicability.lifecycleState ==
                    HabitLifecycleState.active &&
                habit.trackingType == HabitTrackingType.checklist)
              ChecklistRecoveryControls(
                habit: habit,
                date: widget.date,
                showPrivateHistory: _showPrivate,
                onChanged: _entrySaved,
              ),
          ],
        ),
      ),
    );
  }
}
