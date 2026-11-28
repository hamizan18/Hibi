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
          return const Text('Loading habits…');
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
          return const Text('Loading habits…');
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
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  title: const Text('Show private habits'),
                  subtitle: const Text(
                    'Also shows habits with unknown privacy. Use in a private place.',
                  ),
                  value: _showPrivate,
                  onChanged: (value) => setState(() => _showPrivate = value),
                ),
              ),
              if (visible.isEmpty)
                const Card(
                  margin: EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Text(
                      'No habits to show. Add a habit or show private habits.',
                    ),
                  ),
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
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outlineVariant
              .withValues(alpha: 0.4),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              habit.name ?? 'Habit needs setup',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            if (applicability == HabitApplicability.unknown)
              const Text('Finish setting up this habit to see its status.')
            else if (habit.applicability.reason ==
                HabitApplicabilityReason.beforeStart)
              const Text(
                'This habit has not started yet. You can pause it from its start date.',
              )
            else if (applicability == HabitApplicability.notApplicable)
              const Text('Not scheduled or active today.')
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
                  'Finish choosing how to track this habit.',
                ),
              },
            if (habit.trackingType != HabitTrackingType.unconfigured) ...[
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text('Habit options'),
                children: [
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
                  ] else
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
            ],
          ],
        ),
      ),
    );
  }
}
