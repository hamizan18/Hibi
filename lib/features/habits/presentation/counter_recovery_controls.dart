import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../data/counter_history_reader.dart';
import '../data/habit_metadata_store.dart';
import '../data/counter_recovery_eligibility.dart';
import '../data/unified_habit_registry.dart';
import '../domain/habit_schedule.dart';

class CounterRecoveryControls extends ConsumerStatefulWidget {
  const CounterRecoveryControls({
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
  ConsumerState<CounterRecoveryControls> createState() =>
      _CounterRecoveryControlsState();
}

class _CounterRecoveryControlsState
    extends ConsumerState<CounterRecoveryControls> {
  final _random = Random.secure();
  final _quantities = <String, TextEditingController>{};
  List<CounterRecoverableDeficit> _deficits = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  CounterRecoveryEligibility get _service => CounterRecoveryEligibility(
    ref.read(databaseProvider),
    ref.read(appClockProvider),
  );

  bool get _isToday {
    final now = ref.read(appClockProvider).now().toLocal();
    return widget.date.compareTo(LocalDate(now.year, now.month, now.day)) == 0;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CounterRecoveryControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.habit.habitId != widget.habit.habitId ||
        oldWidget.date.compareTo(widget.date) != 0 ||
        oldWidget.showPrivateHistory != widget.showPrivateHistory) {
      for (final controller in _quantities.values) {
        controller.dispose();
      }
      _quantities.clear();
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _deficits = const [];
    });
    try {
      final deficits = await _service.find(
        habitId: widget.habit.habitId,
        asOfDate: widget.date,
      );
      final metadata = HabitMetadataStore(ref.read(databaseProvider));
      final visible = <CounterRecoverableDeficit>[];
      for (final deficit in deficits) {
        final versionMetadata = await metadata.findForVersion(
          deficit.versionId,
        );
        if (versionMetadata != null &&
            (widget.showPrivateHistory || !versionMetadata.isPrivate)) {
          visible.add(deficit);
        }
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _deficits = visible;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = 'Could not load recoverable deficits.';
      });
    }
  }

  Future<void> _recover(CounterRecoverableDeficit deficit) async {
    if (_busy) return;
    final quantity = int.tryParse(_quantities[deficit.occurrenceId]!.text);
    if (quantity == null ||
        quantity <= 0 ||
        quantity > deficit.remainingDeficit) {
      setState(
        () => _error = 'Enter a positive whole number no greater than the remaining deficit.',
      );
      return;
    }
    if (!_isToday) {
      setState(() => _error = 'The selected day is no longer today.');
      return;
    }
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = List.generate(
        16,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await _service.recover(
        habitId: widget.habit.habitId,
        date: widget.date,
        occurrenceId: deficit.occurrenceId,
        recoveryId: id,
        quantity: quantity,
      );
      if (!mounted) return;
      widget.onChanged();
      if (generation != _generation) return;
      _quantities[deficit.occurrenceId]?.clear();
      await _load();
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(
        () => _error = 'Could not recover this deficit. Refresh and try again.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    for (final controller in _quantities.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Recover prior deficits'),
        if (_loading) const CircularProgressIndicator(),
        if (_error != null) ...[
          Text(_error!),
          TextButton(
            onPressed: _busy ? null : _load,
            child: const Text('Refresh'),
          ),
        ],
        if (!_loading && _error == null && _deficits.isEmpty)
          const Text('No recoverable deficits.'),
        if (!_loading)
          for (final deficit in _deficits) ...[
            Text(
              '${deficit.date.year.toString().padLeft(4, '0')}-${deficit.date.month.toString().padLeft(2, '0')}-${deficit.date.day.toString().padLeft(2, '0')}: ${deficit.remainingDeficit} ${deficit.unit} remaining',
            ),
            TextField(
              controller: _quantities.putIfAbsent(
                deficit.occurrenceId,
                TextEditingController.new,
              ),
              enabled: !_busy && _isToday,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Recovery quantity'),
            ),
            ElevatedButton(
              onPressed: _busy || !_isToday ? null : () => _recover(deficit),
              child: const Text('Recover'),
            ),
          ],
      ],
    );
  }
}
