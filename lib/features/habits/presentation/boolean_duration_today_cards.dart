import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../data/boolean_duration_habit_store.dart';
import '../data/boolean_duration_today_reader.dart';
import '../data/unified_habit_registry.dart';
import '../domain/boolean_duration_habit.dart';
import '../domain/habit_schedule.dart';

final _random = Random.secure();
String _id() => List.generate(
  16,
  (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

bool _isToday(LocalDate date, DateTime now) {
  final local = now.toLocal();
  return date.year == local.year &&
      date.month == local.month &&
      date.day == local.day;
}

class BooleanTodayCard extends ConsumerStatefulWidget {
  const BooleanTodayCard({
    super.key,
    required this.habit,
    required this.date,
    required this.onChanged,
  });
  final UnifiedHabitSummary habit;
  final LocalDate date;
  final VoidCallback onChanged;

  @override
  ConsumerState<BooleanTodayCard> createState() => _BooleanTodayCardState();
}

class _BooleanTodayCardState extends ConsumerState<BooleanTodayCard> {
  BooleanLogState? _state;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  BooleanDurationHabitService get _service => BooleanDurationHabitService(
    ref.read(databaseProvider),
    ref.read(appClockProvider),
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant BooleanTodayCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.habit.habitId != widget.habit.habitId ||
        oldWidget.date.compareTo(widget.date) != 0 ||
        oldWidget.habit.versionId != widget.habit.versionId) {
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _state = null;
    });
    try {
      final state = await _service.readBooleanDay(
        habitId: widget.habit.habitId,
        date: widget.date,
      );
      if (mounted && generation == _generation) {
        setState(() {
          _state = state;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = 'Unable to load status.';
        });
      }
    }
  }

  Future<void> _log(BooleanLogState state) async {
    if (_busy ||
        _loading ||
        _state != null ||
        !_isToday(widget.date, ref.read(appClockProvider).now())) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _service.logBooleanToday(
        habitId: widget.habit.habitId,
        occurrenceId: _id(),
        logId: _id(),
        state: state,
      );
      if (!mounted) return;
      setState(() => _state = state);
      widget.onChanged();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Unable to save status. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled =
        !_loading &&
        !_busy &&
        _error == null &&
        _state == null &&
        _isToday(widget.date, ref.read(appClockProvider).now());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loading)
          const CircularProgressIndicator()
        else
          Text(_state == null ? 'Not recorded yet' : 'Status: ${_state!.name}'),
        if (_error != null) ...[
          Text(_error!),
          if (!_busy)
            TextButton(onPressed: _load, child: const Text('Try again')),
        ],
        Wrap(
          spacing: 8,
          children: [
            for (final state in BooleanLogState.values)
              OutlinedButton(
                onPressed: enabled ? () => _log(state) : null,
                child: Text(switch (state) {
                  BooleanLogState.completed => 'Mark done',
                  BooleanLogState.failed => 'Mark not done',
                  BooleanLogState.excused => 'Excuse today',
                }),
              ),
          ],
        ),
      ],
    );
  }
}

class DurationTodayCard extends ConsumerStatefulWidget {
  const DurationTodayCard({
    super.key,
    required this.habit,
    required this.date,
    required this.onChanged,
  });
  final UnifiedHabitSummary habit;
  final LocalDate date;
  final VoidCallback onChanged;

  @override
  ConsumerState<DurationTodayCard> createState() => _DurationTodayCardState();
}

class _DurationTodayCardState extends ConsumerState<DurationTodayCard> {
  final _seconds = TextEditingController();
  DurationDayProgress? _progress;
  DateTime? _startedAt;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  BooleanDurationHabitService get _service => BooleanDurationHabitService(
    ref.read(databaseProvider),
    ref.read(appClockProvider),
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant DurationTodayCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.habit.habitId != widget.habit.habitId ||
        oldWidget.date.compareTo(widget.date) != 0 ||
        oldWidget.habit.versionId != widget.habit.versionId) {
      _startedAt = null;
      _seconds.clear();
      _load();
    }
  }

  @override
  void dispose() {
    _seconds.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _progress = null;
    });
    try {
      final progress =
          await BooleanDurationTodayReader(
            ref.read(databaseProvider),
            _service,
          ).readDuration(
            habitId: widget.habit.habitId,
            versionId: widget.habit.versionId,
            date: widget.date,
          );
      if (mounted && generation == _generation) {
        setState(() {
          _progress = progress;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = 'Unable to load progress.';
        });
      }
    }
  }

  Future<void> _save(DurationEntryInput entry, {bool timer = false}) async {
    if (_busy ||
        _loading ||
        _progress == null ||
        !_isToday(widget.date, ref.read(appClockProvider).now())) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final progress = await _service.recordDurationEntryToday(
        habitId: widget.habit.habitId,
        occurrenceId: _id(),
        eventId: _id(),
        entry: entry,
      );
      if (!mounted) return;
      setState(() {
        _progress = progress;
        if (timer) {
          _startedAt = null;
        } else {
          _seconds.clear();
        }
      });
      widget.onChanged();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Unable to save duration. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _manual() {
    final text = _seconds.text.trim();
    final seconds = int.tryParse(text);
    if (!RegExp(r'^\d+$').hasMatch(text) || seconds == null || seconds <= 0) {
      setState(() => _error = 'Enter a positive whole number of seconds.');
      return;
    }
    _save(DurationEntryInput.manual(durationSeconds: seconds));
  }

  void _timer() {
    final now = ref.read(appClockProvider).now();
    if (!_isToday(widget.date, now)) {
      setState(() => _error = 'Timer entries can only be saved for today.');
      return;
    }
    if (_startedAt == null) {
      setState(() {
        _startedAt = now;
        _error = null;
      });
      return;
    }
    if (!_isToday(widget.date, _startedAt!) ||
        now.difference(_startedAt!).inSeconds < 1) {
      setState(
        () => _error =
            'The timer must run for at least one second on the same day.',
      );
      return;
    }
    _save(
      DurationEntryInput.timer(startedAtUtc: _startedAt!, endedAtUtc: now),
      timer: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final resolved =
        _progress?.status == DurationEffectiveStatus.failed ||
        _progress?.status == DurationEffectiveStatus.excused;
    final enabled =
        !_loading &&
        !_busy &&
        _progress != null &&
        !resolved &&
        _isToday(widget.date, ref.read(appClockProvider).now());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loading)
          const CircularProgressIndicator()
        else if (_progress == null)
          const Text('Could not load progress')
        else
          Text(
            '${_progress!.status.name}: ${_progress!.totalSeconds} / ${_progress!.targetSeconds} seconds',
          ),
        if (_error != null) Text(_error!),
        if (!_loading && _progress == null)
          TextButton(onPressed: _load, child: const Text('Try again')),
        TextField(
          controller: _seconds,
          enabled: enabled,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Duration in seconds'),
        ),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: enabled ? _manual : null,
              child: const Text('Add time'),
            ),
            OutlinedButton(
              onPressed: enabled ? _timer : null,
              child: Text(
                _startedAt == null ? 'Start timer' : 'Stop and save timer',
              ),
            ),
            if (_startedAt != null)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _startedAt = null;
                        _error = null;
                      }),
                child: const Text('Discard timer'),
              ),
          ],
        ),
        if (_startedAt != null)
          Text(
            'Timer started at ${_startedAt!.toLocal()}. Leaving or refreshing Today, putting the app in the background, or changing private visibility can discard it. Timers cannot cross midnight.',
          ),
      ],
    );
  }
}
