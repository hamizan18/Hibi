import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/app_clock.dart';
import '../application/counter_habit_providers.dart';
import '../data/counter_resolution.dart';
import '../data/unified_habit_registry.dart';
import '../domain/counter_day_status.dart';
import '../domain/habit_schedule.dart';

class CounterTodayCard extends ConsumerStatefulWidget {
  const CounterTodayCard({
    super.key,
    required this.habit,
    required this.date,
    required this.onChanged,
  });

  final UnifiedHabitSummary habit;
  final LocalDate date;
  final VoidCallback onChanged;

  @override
  ConsumerState<CounterTodayCard> createState() => _CounterTodayCardState();
}

class _CounterTodayCardState extends ConsumerState<CounterTodayCard> {
  final _quantity = TextEditingController();
  final _random = Random.secure();
  CounterDayEvaluation? _evaluation;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  String _id() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  bool get _isToday {
    final now = ref.read(appClockProvider).now().toLocal();
    return widget.date.year == now.year &&
        widget.date.month == now.month &&
        widget.date.day == now.day;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CounterTodayCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.habit.habitId != widget.habit.habitId ||
        oldWidget.date.compareTo(widget.date) != 0) {
      _quantity.clear();
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _evaluation = null;
      _error = null;
    });
    try {
      final value = await ref
          .read(counterDayReaderProvider)
          .evaluate(habitId: widget.habit.habitId, date: widget.date);
      if (!mounted || generation != _generation) return;
      setState(() {
        _evaluation = value;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = 'Unable to load counter today.';
      });
    }
  }

  Future<void> _submit({CounterResolutionState? resolution}) async {
    if (_busy || _loading || !_isToday || _evaluation == null) return;
    final status = _evaluation!.effectiveStatus;
    if (status != CounterDayEffectiveStatus.pending &&
        status != CounterDayEffectiveStatus.partial) {
      return;
    }
    int? quantity;
    if (resolution == null) {
      final text = _quantity.text.trim();
      quantity = RegExp(r'^[0-9]+$').hasMatch(text) ? int.tryParse(text) : null;
      final total = _evaluation!.day.recorded?.progress.total ?? 0;
      if (quantity == null ||
          quantity <= 0 ||
          quantity > 9223372036854775807 - total) {
        setState(
          () => _error = 'Enter a positive whole number that fits the total.',
        );
        return;
      }
    }
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = ref.read(counterTodayActionServiceProvider);
      final result = resolution == null
          ? await service.recordTodayProgress(
              habitId: widget.habit.habitId,
              occurrenceId: _id(),
              eventId: _id(),
              quantity: quantity!,
            )
          : await service.resolveToday(
              habitId: widget.habit.habitId,
              occurrenceId: _id(),
              resolutionId: _id(),
              state: resolution,
            );
      if (!mounted) return;
      widget.onChanged();
      if (generation != _generation) return;
      setState(() {
        _evaluation = result;
        _quantity.clear();
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _evaluation = null;
        _error = 'Unable to save. Reload and try again.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    _quantity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final evaluation = _evaluation;
    final status = evaluation?.effectiveStatus;
    final canAct =
        !_loading &&
        !_busy &&
        _isToday &&
        (status == CounterDayEffectiveStatus.pending ||
            status == CounterDayEffectiveStatus.partial);
    final recorded = evaluation?.day.recorded;
    final target =
        recorded?.progress.target ?? evaluation?.configuredTarget?.count;
    final unit = recorded?.unit ?? evaluation?.configuredTarget?.unit;
    final total = recorded?.progress.total;
    final label = switch (status) {
      CounterDayEffectiveStatus.notApplicable => 'Not applicable',
      CounterDayEffectiveStatus.unknown => 'Unknown',
      CounterDayEffectiveStatus.pending => 'Pending',
      CounterDayEffectiveStatus.partial => 'In progress',
      CounterDayEffectiveStatus.completed => 'Completed',
      CounterDayEffectiveStatus.failed => 'Failed',
      CounterDayEffectiveStatus.recovered => 'Recovered',
      CounterDayEffectiveStatus.excused => 'Excused',
      CounterDayEffectiveStatus.conflict => 'Conflict',
      null => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loading) const CircularProgressIndicator(),
        if (label != null) Text(label),
        if (target != null && unit != null && evaluation != null)
          Text(
            total == null
                ? 'Target: $target $unit'
                : 'Progress: $total / $target $unit',
          ),
        if (!_isToday) const Text('Actions are available only for today.'),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (!_loading && evaluation == null)
          TextButton(
            onPressed: _busy ? null : _load,
            child: const Text('Reload'),
          ),
        TextField(
          controller: _quantity,
          enabled: canAct,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Progress amount'),
        ),
        Wrap(
          spacing: 8,
          children: [
            ElevatedButton(
              onPressed: canAct ? () => _submit() : null,
              child: const Text('Add progress'),
            ),
            TextButton(
              onPressed: canAct
                  ? () => _submit(resolution: CounterResolutionState.failed)
                  : null,
              child: const Text('Mark failed'),
            ),
            TextButton(
              onPressed: canAct
                  ? () => _submit(resolution: CounterResolutionState.excused)
                  : null,
              child: const Text('Excuse'),
            ),
          ],
        ),
      ],
    );
  }
}
