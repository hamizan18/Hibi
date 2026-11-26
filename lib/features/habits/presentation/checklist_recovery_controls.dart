import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../data/checklist_recovery_eligibility.dart';
import '../data/unified_habit_registry.dart';
import '../domain/habit_schedule.dart';

final _random = Random.secure();
String _id() => List.generate(
  16,
  (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

class ChecklistRecoveryControls extends ConsumerStatefulWidget {
  const ChecklistRecoveryControls({
    super.key,
    required this.habit,
    required this.date,
    required this.showPrivateHistory,
    required this.onChanged,
  });

  final UnifiedHabitSummary habit;
  final LocalDate date;
  final bool showPrivateHistory;
  final VoidCallback onChanged;

  @override
  ConsumerState<ChecklistRecoveryControls> createState() =>
      _ChecklistRecoveryControlsState();
}

class _ChecklistRecoveryControlsState
    extends ConsumerState<ChecklistRecoveryControls> {
  List<ChecklistRecoveryCandidate>? _items;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int _generation = 0;

  ChecklistRecoveryEligibility get _eligibility => ChecklistRecoveryEligibility(
    ref.read(databaseProvider),
    ref.read(appClockProvider),
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ChecklistRecoveryControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.habit != widget.habit ||
        oldWidget.date.compareTo(widget.date) != 0) {
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _items = null;
      _error = null;
    });
    try {
      final items = await _eligibility.read(
        habitId: widget.habit.habitId,
        date: widget.date,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = 'Unable to load checklist recovery.';
      });
    }
  }

  Future<void> _recover(ChecklistRecoveryCandidate item) async {
    if (_saving) return;
    final generation = _generation;
    final habitId = widget.habit.habitId;
    final date = widget.date;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _eligibility.recover(
        habitId: habitId,
        date: date,
        occurrenceId: item.occurrenceId,
        itemId: item.itemId,
        recoveryId: _id(),
      );
      if (!mounted) return;
      widget.onChanged();
      if (generation == _generation) await _load();
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _items = null;
          _error = 'Unable to recover item. Refresh and try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(appClockProvider).now().toLocal();
    final today =
        widget.date.year == now.year &&
        widget.date.month == now.month &&
        widget.date.day == now.day;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loading) const CircularProgressIndicator(),
        if (_error != null) Text(_error!),
        if (!_loading && _items == null)
          TextButton(onPressed: _load, child: const Text('Retry')),
        if (!_loading && _items != null)
          for (final item in _items!.where(
            (item) => widget.showPrivateHistory || !item.isPrivate,
          ))
            OutlinedButton(
              onPressed: !_saving && today ? () => _recover(item) : null,
              child: Text(
                'Recover ${item.label} (${item.date.year.toString().padLeft(4, '0')}-${item.date.month.toString().padLeft(2, '0')}-${item.date.day.toString().padLeft(2, '0')})',
              ),
            ),
      ],
    );
  }
}
