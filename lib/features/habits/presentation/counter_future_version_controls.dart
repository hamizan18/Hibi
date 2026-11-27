import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/app_clock.dart';
import '../application/counter_habit_providers.dart';
import '../data/counter_configuration_reader.dart';
import '../data/unified_habit_registry.dart';
import '../domain/counter_target.dart';
import '../domain/habit_metadata.dart';
import '../domain/habit_schedule.dart';

enum _FutureScheduleKind { daily, weekdays, interval, monthly, oneTime }

/// User-facing workflow to inspect a counter habit's version timeline and
/// schedule a strictly future counter version while preserving history.
class CounterFutureVersionControls extends ConsumerStatefulWidget {
  const CounterFutureVersionControls({
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
  ConsumerState<CounterFutureVersionControls> createState() =>
      _CounterFutureVersionControlsState();
}

class _CounterFutureVersionControlsState
    extends ConsumerState<CounterFutureVersionControls> {
  final _random = Random.secure();
  final _name = TextEditingController();
  final _targetCount = TextEditingController();
  final _unit = TextEditingController();
  final _intervalDays = TextEditingController(text: '2');
  final _monthDay = TextEditingController(text: '1');
  final _category = TextEditingController(text: 'Personal');
  final _description = TextEditingController();
  final _symbol = TextEditingController();
  final _displayOrder = TextEditingController(text: '0');
  final _weekdays = <int>{1, 2, 3, 4, 5};

  CounterHabitConfiguration? _config;
  bool _loading = true;
  bool _busy = false;
  bool _expanded = false;
  String? _error;
  int _generation = 0;

  late LocalDate _effectiveStart;
  _FutureScheduleKind _scheduleKind = _FutureScheduleKind.daily;
  bool _monthlyLastDayFallback = false;
  bool _includeMetadata = false;
  HabitPriority _priority = HabitPriority.normal;
  bool _isPrivate = false;
  bool _recoveryEnabled = false;
  bool _includeInScore = true;
  bool _includeInStreak = true;
  bool _includeInRewards = true;

  LocalDate get _today {
    final now = ref.read(appClockProvider).now().toLocal();
    return LocalDate(now.year, now.month, now.day);
  }

  String _id() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  String _formatDate(LocalDate d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  LocalDate _nextDay(LocalDate d) {
    final next = DateTime.utc(d.year, d.month, d.day + 1);
    return LocalDate(next.year, next.month, next.day);
  }

  LocalDate _minAllowedStart(CounterHabitConfiguration? config) {
    final afterToday = _nextDay(_today);
    if (config == null || config.allVersions.isEmpty) return afterToday;
    final afterLatest = _nextDay(config.allVersions.last.effectiveStart);
    return afterLatest.compareTo(afterToday) > 0 ? afterLatest : afterToday;
  }

  @override
  void initState() {
    super.initState();
    _effectiveStart = _nextDay(widget.date);
    _load();
  }

  @override
  void didUpdateWidget(covariant CounterFutureVersionControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.habit.habitId != widget.habit.habitId ||
        oldWidget.date.compareTo(widget.date) != 0) {
      _expanded = false;
      _load();
    }
  }

  @override
  void dispose() {
    _generation++;
    for (final c in [
      _name,
      _targetCount,
      _unit,
      _intervalDays,
      _monthDay,
      _category,
      _description,
      _symbol,
      _displayOrder,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final config = await ref
          .read(counterConfigurationReaderProvider)
          .read(habitId: widget.habit.habitId, asOfDate: widget.date);
      if (!mounted || generation != _generation) return;
      _populateDefaultsFromLatest(config);
      setState(() {
        _config = config;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _config = null;
        _loading = false;
        _error = 'Could not load version configuration.';
      });
    }
  }

  void _populateDefaultsFromLatest(CounterHabitConfiguration config) {
    _effectiveStart = _minAllowedStart(config);
    if (config.allVersions.isEmpty) return;
    final latest = config.allVersions.last;
    _name.text = latest.name;
    if (latest.target != null) {
      _targetCount.text = '${latest.target!.count}';
      _unit.text = latest.target!.unit;
    }
    final sched = latest.schedule;
    switch (sched) {
      case DailySchedule() || null:
        _scheduleKind = _FutureScheduleKind.daily;
      case WeekdaySchedule(:final weekdays):
        _scheduleKind = _FutureScheduleKind.weekdays;
        _weekdays
          ..clear()
          ..addAll(weekdays);
      case IntervalSchedule(:final everyDays):
        _scheduleKind = _FutureScheduleKind.interval;
        _intervalDays.text = '$everyDays';
      case MonthlyDaySchedule(:final dayOfMonth, :final lastDayFallback):
        _scheduleKind = _FutureScheduleKind.monthly;
        _monthDay.text = '$dayOfMonth';
        _monthlyLastDayFallback = lastDayFallback;
      case OneTimeSchedule():
        _scheduleKind = _FutureScheduleKind.oneTime;
    }
    final meta = latest.metadata;
    if (meta != null) {
      _includeMetadata = true;
      _category.text = meta.category;
      _description.text = meta.description ?? '';
      _symbol.text = meta.symbol ?? '';
      _priority = meta.priority;
      _isPrivate = meta.isPrivate;
      _recoveryEnabled = meta.recoveryEnabled;
      _includeInScore = meta.includeInScore;
      _includeInStreak = meta.includeInStreak;
      _includeInRewards = meta.includeInRewards;
      _displayOrder.text = '${meta.displayOrder}';
    } else {
      _includeMetadata = false;
    }
  }

  Future<void> _pickStartDate() async {
    final minDate = _minAllowedStart(_config);
    final initial = _effectiveStart.compareTo(minDate) < 0
        ? minDate
        : _effectiveStart;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(minDate.year, minDate.month, minDate.day),
      lastDate: DateTime(9999, 12, 30),
    );
    if (!mounted || picked == null) return;
    setState(() {
      _effectiveStart = LocalDate(picked.year, picked.month, picked.day);
    });
  }

  Future<void> _submit() async {
    final config = _config;
    if (_busy || _loading || config == null || config.allVersions.isEmpty) {
      return;
    }
    if (widget.date.compareTo(_today) != 0) {
      setState(() {
        _error = 'Future versions can only be scheduled on the current day.';
      });
      return;
    }
    final latest = config.allVersions.last;
    if (latest.effectiveEnd != null || latest.target == null) {
      setState(() {
        _error =
            'Habit must have an open counter version to schedule a change.';
      });
      return;
    }
    final minStart = _minAllowedStart(config);
    if (_effectiveStart.compareTo(minStart) < 0) {
      setState(() {
        _error =
            'Effective start date must be ${_formatDate(minStart)} or later.';
      });
      return;
    }
    final trimmedName = _name.text.trim();
    if (trimmedName.isEmpty) {
      setState(() => _error = 'Enter a nonblank version name.');
      return;
    }
    final countText = _targetCount.text.trim();
    final count = RegExp(r'^[0-9]+$').hasMatch(countText)
        ? int.tryParse(countText)
        : null;
    if (count == null || count <= 0) {
      setState(() => _error = 'Enter a positive whole-number target count.');
      return;
    }
    final trimmedUnit = _unit.text.trim();
    if (trimmedUnit.isEmpty) {
      setState(() => _error = 'Enter a nonblank target unit.');
      return;
    }

    HabitSchedule schedule;
    switch (_scheduleKind) {
      case _FutureScheduleKind.daily:
        schedule = DailySchedule(start: _effectiveStart);
      case _FutureScheduleKind.weekdays:
        if (_weekdays.isEmpty) {
          setState(() => _error = 'Select at least one weekday.');
          return;
        }
        schedule = WeekdaySchedule(
          start: _effectiveStart,
          weekdays: Set<int>.from(_weekdays),
        );
      case _FutureScheduleKind.interval:
        final every = int.tryParse(_intervalDays.text.trim());
        if (every == null || every <= 0) {
          setState(() => _error = 'Enter an interval of at least 1 day.');
          return;
        }
        schedule = IntervalSchedule(start: _effectiveStart, everyDays: every);
      case _FutureScheduleKind.monthly:
        final day = int.tryParse(_monthDay.text.trim());
        if (day == null || day < 1 || day > 31) {
          setState(() => _error = 'Enter a day of month between 1 and 31.');
          return;
        }
        schedule = MonthlyDaySchedule(
          start: _effectiveStart,
          dayOfMonth: day,
          lastDayFallback: _monthlyLastDayFallback,
        );
      case _FutureScheduleKind.oneTime:
        schedule = OneTimeSchedule(date: _effectiveStart);
    }

    HabitMetadata? metadata;
    if (_includeMetadata) {
      final cat = _category.text.trim();
      final order = int.tryParse(_displayOrder.text.trim());
      if (cat.isEmpty || order == null) {
        setState(
          () => _error = 'Enter a valid metadata category and display order.',
        );
        return;
      }
      metadata = HabitMetadata(
        category: cat,
        description: _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
        symbol: _symbol.text.trim().isEmpty ? null : _symbol.text.trim(),
        priority: _priority,
        isPrivate: _isPrivate,
        recoveryEnabled: _recoveryEnabled,
        includeInScore: _includeInScore,
        includeInStreak: _includeInStreak,
        includeInRewards: _includeInRewards,
        displayOrder: order,
      );
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final habitId = widget.habit.habitId;
    try {
      await ref
          .read(counterHabitWriterProvider)
          .scheduleVersion(
            habitId: habitId,
            versionId: _id(),
            auditId: _id(),
            name: trimmedName,
            effectiveDate: DateTime(
              _effectiveStart.year,
              _effectiveStart.month,
              _effectiveStart.day,
            ),
            target: CounterTarget(count: count, unit: trimmedUnit),
            schedule: schedule,
            metadata: metadata,
          );
      if (!mounted) return;
      _expanded = false;
      widget.onChanged();
      if (mounted && widget.habit.habitId == habitId) {
        await _load();
      }
    } catch (_) {
      if (!mounted || widget.habit.habitId != habitId) return;
      await _load();
      if (mounted && widget.habit.habitId == habitId) {
        setState(() {
          _error = 'Could not schedule future version. Check effective date and existing occurrences.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String _describeVersion(CounterVersionSnapshot v) {
    final isPrivateVersion = v.metadata?.isPrivate == true;
    if (isPrivateVersion && !widget.showPrivateHistory) {
      return 'Revision ${v.revision}: Private version (${_formatDate(v.effectiveStart)} to ${v.effectiveEnd == null ? 'open' : _formatDate(v.effectiveEnd!)})';
    }
    final targetStr = v.target == null
        ? 'unconfigured target'
        : '${v.target!.count} ${v.target!.unit}';
    final endStr = v.effectiveEnd == null
        ? 'open'
        : _formatDate(v.effectiveEnd!);
    return 'Revision ${v.revision}: ${v.name} — $targetStr (${_formatDate(v.effectiveStart)} to $endStr)';
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    final latest = config == null || config.allVersions.isEmpty
        ? null
        : config.allVersions.last;
    final canSchedule =
        !_loading &&
        !_busy &&
        widget.date.compareTo(_today) == 0 &&
        latest != null &&
        latest.effectiveEnd == null &&
        latest.target != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        const Text('Version timeline & future configuration'),
        if (_loading) const CircularProgressIndicator(),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (!_loading && config != null) ...[
          if (config.effectiveVersion != null)
            Text('Effective: ${_describeVersion(config.effectiveVersion!)}'),
          if (config.futureVersions.isNotEmpty) ...[
            const Text('Scheduled future versions:'),
            for (final fv in config.futureVersions)
              Text('• ${_describeVersion(fv)}'),
          ],
          OutlinedButton(
            onPressed: canSchedule
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: Text(
              _expanded ? 'Cancel future version' : 'Schedule future version',
            ),
          ),
          if (_expanded && canSchedule) ...[
            TextField(
              controller: _name,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Future version name',
              ),
            ),
            TextField(
              controller: _targetCount,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Future target count',
              ),
            ),
            TextField(
              controller: _unit,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Future target unit',
              ),
            ),
            DropdownButtonFormField<_FutureScheduleKind>(
              initialValue: _scheduleKind,
              decoration: const InputDecoration(labelText: 'Future schedule'),
              items: const [
                DropdownMenuItem(
                  value: _FutureScheduleKind.daily,
                  child: Text('Daily'),
                ),
                DropdownMenuItem(
                  value: _FutureScheduleKind.weekdays,
                  child: Text('Weekdays'),
                ),
                DropdownMenuItem(
                  value: _FutureScheduleKind.interval,
                  child: Text('Interval'),
                ),
                DropdownMenuItem(
                  value: _FutureScheduleKind.monthly,
                  child: Text('Monthly'),
                ),
                DropdownMenuItem(
                  value: _FutureScheduleKind.oneTime,
                  child: Text('One-time'),
                ),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _scheduleKind = v!),
            ),
            if (_scheduleKind == _FutureScheduleKind.weekdays)
              Wrap(
                spacing: 6,
                children: [
                  for (var i = 1; i <= 7; i++)
                    FilterChip(
                      label: Text(
                        const [
                          'Mon',
                          'Tue',
                          'Wed',
                          'Thu',
                          'Fri',
                          'Sat',
                          'Sun',
                        ][i - 1],
                      ),
                      selected: _weekdays.contains(i),
                      onSelected: _busy
                          ? null
                          : (selected) => setState(() {
                              if (selected) {
                                _weekdays.add(i);
                              } else {
                                _weekdays.remove(i);
                              }
                            }),
                    ),
                ],
              ),
            if (_scheduleKind == _FutureScheduleKind.interval)
              TextField(
                controller: _intervalDays,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Future every days',
                ),
              ),
            if (_scheduleKind == _FutureScheduleKind.monthly) ...[
              TextField(
                controller: _monthDay,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Future day of month',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Fallback to last day of month'),
                value: _monthlyLastDayFallback,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _monthlyLastDayFallback = v),
              ),
            ],
            TextButton(
              onPressed: _busy ? null : _pickStartDate,
              child: Text(
                'Future effective start: ${_formatDate(_effectiveStart)}',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Save version metadata'),
              value: _includeMetadata,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _includeMetadata = v),
            ),
            if (_includeMetadata) ...[
              TextField(
                controller: _category,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'Future category'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Future version is private'),
                value: _isPrivate,
                onChanged: _busy ? null : (v) => setState(() => _isPrivate = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Enable recovery on future version'),
                value: _recoveryEnabled,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _recoveryEnabled = v),
              ),
            ],
            ElevatedButton(
              key: const Key('counter-future-version-submit'),
              onPressed: _busy ? null : _submit,
              child: const Text('Save future version'),
            ),
          ],
        ],
      ],
    );
  }
}
