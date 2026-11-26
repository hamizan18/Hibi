import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../application/counter_habit_providers.dart';
import '../data/avoidance_habit_store.dart';
import '../data/checklist_today_reader.dart';
import '../data/habit_lifecycle.dart';
import '../data/unified_habit_registry.dart';
import '../domain/avoidance_habit.dart';
import '../domain/checklist_habit.dart';
import '../domain/habit_schedule.dart';

final _random = Random.secure();
String _id() => List.generate(
  16,
  (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

bool _isToday(LocalDate date, DateTime now) =>
    date.year == now.year && date.month == now.month && date.day == now.day;

String _label(String value) => value[0].toUpperCase() + value.substring(1);

class ChecklistTodayCard extends ConsumerStatefulWidget {
  const ChecklistTodayCard({
    super.key,
    required this.habit,
    required this.date,
    required this.onChanged,
  });

  final UnifiedHabitSummary habit;
  final LocalDate date;
  final VoidCallback onChanged;

  @override
  ConsumerState<ChecklistTodayCard> createState() => _ChecklistTodayCardState();
}

class _ChecklistTodayCardState extends ConsumerState<ChecklistTodayCard> {
  List<ChecklistItemEvaluation>? _items;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ChecklistTodayCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.habit.habitId != widget.habit.habitId ||
        oldWidget.habit.versionId != widget.habit.versionId ||
        oldWidget.date.compareTo(widget.date) != 0) {
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final versionId = widget.habit.versionId;
      if (versionId == null) throw StateError('Missing version');
      final definitions = await ChecklistTodayReader(ref.read(databaseProvider))
          .readDefinitions(versionId);
      final day = await ref
          .read(checklistHabitServiceProvider)
          .readDay(habitId: widget.habit.habitId, date: widget.date);
      if (definitions.isEmpty ||
          day.applicability != HabitApplicability.applicable) {
        throw StateError('Checklist unavailable');
      }
      final items =
          day.progress?.items ??
          ChecklistDayProgress.evaluate(
            definitions: definitions,
            loggedStates: {},
            recoveredItemIds: {},
          ).items;
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = null;
        _loading = false;
        _error = 'Unable to load checklist.';
      });
    }
  }

  Future<void> _log(
    ChecklistItemEvaluation item,
    ChecklistItemLogState state,
  ) async {
    if (_saving || item.state != ChecklistItemEffectiveState.pending) return;
    if (!_isToday(widget.date, ref.read(appClockProvider).now())) {
      setState(() => _error = 'Only today can be logged.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(checklistHabitServiceProvider)
          .logItemToday(
            habitId: widget.habit.habitId,
            occurrenceId: _id(),
            logId: _id(),
            itemId: item.definition.id,
            state: state,
          );
      widget.onChanged();
      if (mounted) await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Unable to save checklist item. Please refresh and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = _isToday(widget.date, ref.watch(appClockProvider).now());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loading) const CircularProgressIndicator(),
        if (_error != null) Text(_error!),
        if (!_loading && _items == null)
          TextButton(onPressed: _load, child: const Text('Retry')),
        if (!_loading && _items != null)
          for (final item in _items!)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${item.definition.label}: ${_label(item.state.name)}'),
                if (item.state == ChecklistItemEffectiveState.pending)
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final state in ChecklistItemLogState.values)
                        OutlinedButton(
                          onPressed: !_saving && today
                              ? () => _log(item, state)
                              : null,
                          child: Text(
                            '${_label(state.name)} ${item.definition.label}',
                          ),
                        ),
                    ],
                  ),
              ],
            ),
      ],
    );
  }
}

class AvoidanceTodayCard extends ConsumerStatefulWidget {
  const AvoidanceTodayCard({
    super.key,
    required this.habit,
    required this.date,
    required this.onChanged,
  });

  final UnifiedHabitSummary habit;
  final LocalDate date;
  final VoidCallback onChanged;

  @override
  ConsumerState<AvoidanceTodayCard> createState() => _AvoidanceTodayCardState();
}

class _AvoidanceTodayCardState extends ConsumerState<AvoidanceTodayCard> {
  AvoidanceDayView? _day;
  bool _confirmationConflict = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AvoidanceTodayCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.habit.habitId != widget.habit.habitId ||
        oldWidget.habit.versionId != widget.habit.versionId ||
        oldWidget.date.compareTo(widget.date) != 0) {
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final day = await ref
          .read(avoidanceHabitServiceProvider)
          .readDay(habitId: widget.habit.habitId, date: widget.date);
      if (day.applicability != HabitApplicability.applicable ||
          widget.habit.versionId == null) {
        throw StateError('Unavailable');
      }
      final snapshot = day.occurrenceId == null
          ? null
          : await AvoidanceTodayReader(ref.read(databaseProvider))
                .readResolutionIncidentCount(day.occurrenceId!);
      if (!mounted || generation != _generation) return;
      setState(() {
        _day = day;
        _confirmationConflict =
            day.progress?.resolution ==
                AvoidanceResolutionState.confirmedCompleted &&
            snapshot != day.progress!.incidentCount;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _day = null;
        _loading = false;
        _error = 'Unable to load avoidance status.';
      });
    }
  }

  Future<void> _write({required bool incident}) async {
    if (_saving) return;
    if (!_isToday(widget.date, ref.read(appClockProvider).now())) {
      setState(() => _error = 'Only today can be logged.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final service = ref.read(avoidanceHabitServiceProvider);
      if (incident) {
        await service.recordIncidentToday(
          habitId: widget.habit.habitId,
          occurrenceId: _id(),
          incidentId: _id(),
        );
      } else {
        await service.resolveToday(
          habitId: widget.habit.habitId,
          occurrenceId: _id(),
          resolutionId: _id(),
          state: AvoidanceResolutionState.confirmedCompleted,
        );
      }
      widget.onChanged();
      if (mounted) await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Unable to save. Please refresh and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final day = _day;
    final today = _isToday(widget.date, ref.watch(appClockProvider).now());
    final progress = day?.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loading) const CircularProgressIndicator(),
        if (_error != null) Text(_error!),
        if (!_loading && day == null)
          TextButton(onPressed: _load, child: const Text('Retry')),
        if (!_loading && day != null) ...[
          Text(
            'Status: ${_confirmationConflict && progress?.status != AvoidanceEffectiveStatus.failed
                ? 'Conflict'
                : progress == null
                ? 'Pending'
                : _label(progress.status.name)}',
          ),
          if (_confirmationConflict)
            const Text('Incidents changed after confirmation.'),
          if (progress != null) Text('Incidents: ${progress.incidentCount}'),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: !_saving && today
                    ? () => _write(incident: true)
                    : null,
                child: const Text('Record incident'),
              ),
              OutlinedButton(
                onPressed:
                    !_saving &&
                        today &&
                        progress?.resolution == null &&
                        progress?.status != AvoidanceEffectiveStatus.failed
                    ? () => _write(incident: false)
                    : null,
                child: const Text('Confirm completion'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
