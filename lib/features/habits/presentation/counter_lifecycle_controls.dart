import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/app_clock.dart';
import '../application/counter_habit_providers.dart';
import '../data/habit_lifecycle.dart';
import '../data/unified_habit_registry.dart';
import '../domain/habit_schedule.dart';

class CounterLifecycleControls extends ConsumerStatefulWidget {
  const CounterLifecycleControls({
    super.key,
    required this.habit,
    required this.date,
    required this.onChanged,
  });

  final UnifiedHabitSummary habit;
  final LocalDate date;
  final VoidCallback onChanged;

  @override
  ConsumerState<CounterLifecycleControls> createState() =>
      _CounterLifecycleControlsState();
}

enum _Action { pause, resume, archive, delete, restore }

class _CounterLifecycleControlsState
    extends ConsumerState<CounterLifecycleControls> {
  final _random = Random.secure();
  List<HabitLifecycleEvent>? _history;
  late LocalDate _effectiveDate;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  LocalDate get _today {
    final now = ref.read(appClockProvider).now().toLocal();
    return LocalDate(now.year, now.month, now.day);
  }

  String _format(LocalDate date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _effectiveDate = widget.date;
    _load();
  }

  @override
  void didUpdateWidget(covariant CounterLifecycleControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.habit.habitId != widget.habit.habitId ||
        oldWidget.date.compareTo(widget.date) != 0) {
      _effectiveDate = widget.date;
      _history = null;
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
      final history = await ref
          .read(habitLifecycleReaderProvider)
          .readHistory(widget.habit.habitId);
      if (!mounted || generation != _generation) return;
      setState(() {
        _history = history;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _history = null;
        _loading = false;
        _error = 'Could not load lifecycle. Please retry.';
      });
    }
  }

  Future<void> _chooseDate() async {
    final today = _today;
    final initial = _effectiveDate.compareTo(today) < 0
        ? today
        : _effectiveDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(today.year, today.month, today.day),
      lastDate: DateTime(9999, 12, 31),
    );
    if (!mounted || picked == null) return;
    setState(() {
      _effectiveDate = LocalDate(picked.year, picked.month, picked.day);
    });
  }

  bool _allowed(_Action action, HabitLifecycleState state) => switch (action) {
    _Action.pause =>
      state == HabitLifecycleState.active ||
          state == HabitLifecycleState.scheduled,
    _Action.resume => state == HabitLifecycleState.paused,
    _Action.archive =>
      state == HabitLifecycleState.active ||
          state == HabitLifecycleState.scheduled ||
          state == HabitLifecycleState.paused,
    _Action.delete => state != HabitLifecycleState.deleted,
    _Action.restore =>
      state == HabitLifecycleState.archived ||
          state == HabitLifecycleState.deleted,
  };

  bool _canPauseFromStart(List<HabitLifecycleEvent>? history) =>
      !_loading &&
      history != null &&
      history.length == 1 &&
      history.first.state == HabitLifecycleState.active &&
      history.first.effectiveDate.compareTo(_today) >= 0 &&
      widget.date.compareTo(_today) == 0;

  Future<void> _pauseFromStart() async {
    final history = _history;
    if (_busy || !_canPauseFromStart(history)) return;
    final initial = history!.first;
    final habitId = widget.habit.habitId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pause from start?'),
        content: Text(
          'Pause this habit from its initial start date, ${_format(initial.effectiveDate)}? Its existing history is preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Pause from start'),
          ),
        ],
      ),
    );
    if (!mounted ||
        confirmed != true ||
        _busy ||
        widget.habit.habitId != habitId ||
        !_canPauseFromStart(_history) ||
        _history!.first.id != initial.id) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final id = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    try {
      await ref
          .read(counterLifecycleActionServiceProvider)
          .pauseFutureStart(
            eventId: id,
            habitId: habitId,
            expectedInitialEventId: initial.id,
          );
      if (!mounted) return;
      widget.onChanged();
      if (mounted && widget.habit.habitId == habitId) await _load();
    } catch (_) {
      if (!mounted || widget.habit.habitId != habitId) return;
      await _load();
      if (mounted && widget.habit.habitId == habitId) {
        setState(() {
          _error = 'Lifecycle change could not be saved. The state or date may have changed; review and retry.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _act(_Action action) async {
    if (_busy ||
        _history == null ||
        _history!.isEmpty ||
        widget.date.compareTo(_today) != 0 ||
        _effectiveDate.compareTo(_today) < 0 ||
        _effectiveDate.compareTo(_history!.last.effectiveDate) <= 0 ||
        !_allowed(action, _history!.last.state)) {
      return;
    }
    final habitId = widget.habit.habitId;
    final date = _effectiveDate;
    if (action == _Action.archive || action == _Action.delete) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            action == _Action.archive ? 'Archive habit?' : 'Soft-delete habit?',
          ),
          content: Text(
            action == _Action.archive
                ? 'Archive this habit effective ${_format(date)}? Its history is preserved.'
                : 'Soft-delete this habit effective ${_format(date)}? Its history is preserved and it can be restored.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                action == _Action.archive ? 'Archive' : 'Soft-delete',
              ),
            ),
          ],
        ),
      );
      if (!mounted ||
          confirmed != true ||
          widget.habit.habitId != habitId ||
          widget.date.compareTo(_today) != 0 ||
          date.compareTo(_today) < 0) {
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final id = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final service = ref.read(counterLifecycleActionServiceProvider);
    try {
      switch (action) {
        case _Action.pause:
          await service.pause(
            eventId: id,
            habitId: habitId,
            effectiveDate: date,
          );
        case _Action.resume:
          await service.resume(
            eventId: id,
            habitId: habitId,
            effectiveDate: date,
          );
        case _Action.archive:
          await service.archive(
            eventId: id,
            habitId: habitId,
            effectiveDate: date,
          );
        case _Action.delete:
          await service.softDelete(
            eventId: id,
            habitId: habitId,
            effectiveDate: date,
          );
        case _Action.restore:
          await service.restore(
            eventId: id,
            habitId: habitId,
            effectiveDate: date,
          );
      }
      if (!mounted) return;
      widget.onChanged();
      if (mounted && widget.habit.habitId == habitId) await _load();
    } catch (_) {
      if (!mounted || widget.habit.habitId != habitId) return;
      await _load();
      if (mounted) {
        setState(() {
          _error = 'Lifecycle change could not be saved. The state or date may have changed; review and retry.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = _history;
    final latest = history == null || history.isEmpty ? null : history.last;
    HabitLifecycleEvent? current;
    if (history != null) {
      for (final event in history) {
        if (event.effectiveDate.compareTo(_today) <= 0) current = event;
      }
    }
    final dateValid =
        latest != null &&
        widget.date.compareTo(_today) == 0 &&
        _effectiveDate.compareTo(_today) >= 0 &&
        _effectiveDate.compareTo(latest.effectiveDate) > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Lifecycle'),
        const Text(
          'Changes take effect on the selected date. Backdating is not allowed; each transition must be later than the latest transition, including scheduled changes. Soft-delete preserves history.',
        ),
        if (_loading) const CircularProgressIndicator(),
        if (_error != null) ...[
          Text(_error!),
          TextButton(
            onPressed: _busy ? null : _load,
            child: const Text('Retry'),
          ),
        ],
        if (!_loading && history != null) ...[
          Text('Current: ${current?.state.name ?? 'not yet started'}'),
          if (latest != null)
            Text(
              'Latest: ${latest.state.name} from ${_format(latest.effectiveDate)}',
            ),
          if (latest == null) const Text('No lifecycle state is available.'),
          TextButton(
            onPressed: _busy || widget.date.compareTo(_today) != 0
                ? null
                : _chooseDate,
            child: Text('Effective date: ${_format(_effectiveDate)}'),
          ),
          if (widget.date.compareTo(_today) != 0)
            const Text(
              'Lifecycle changes are only available on the current day.',
            ),
          if (latest != null && !dateValid)
            const Text(
              'Choose today or a future date later than the latest transition; same-day transitions are not allowed.',
            ),
          if (_canPauseFromStart(history))
            OutlinedButton(
              onPressed: _busy ? null : _pauseFromStart,
              child: const Text('Pause from start'),
            ),
          Wrap(
            spacing: 8,
            children: [
              for (final action in _Action.values)
                OutlinedButton(
                  onPressed:
                      !_busy && dateValid && _allowed(action, latest.state)
                      ? () => _act(action)
                      : null,
                  child: Text(switch (action) {
                    _Action.pause => 'Pause',
                    _Action.resume => 'Resume',
                    _Action.archive => 'Archive',
                    _Action.delete => 'Soft-delete',
                    _Action.restore => 'Restore',
                  }),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
