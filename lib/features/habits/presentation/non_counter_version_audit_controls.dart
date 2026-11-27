import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/app_clock.dart';
import '../../../core/database/app_database.dart';
import '../application/counter_habit_providers.dart';
import '../data/habit_scoring_store.dart';
import '../data/non_counter_version_service.dart';
import '../data/unified_habit_registry.dart';
import '../domain/avoidance_habit.dart';
import '../domain/boolean_duration_habit.dart';
import '../domain/checklist_habit.dart';
import '../domain/dynamic_normalized_scoring.dart';
import '../domain/habit_metadata.dart';
import '../domain/habit_schedule.dart';
import '../domain/measurement_time_range_habit.dart';

enum _NonCounterScheduleKind { daily, weekdays, interval, monthly, oneTime }

/// User-facing controls on Today to inspect a non-counter habit's version
/// timeline, schedule a strictly future version across all seven non-counter
/// tracking types, and open a read-only version/lifecycle/audit inspector sheet.
class NonCounterVersionAndAuditControls extends ConsumerStatefulWidget {
  const NonCounterVersionAndAuditControls({
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
  ConsumerState<NonCounterVersionAndAuditControls> createState() =>
      _NonCounterVersionAndAuditControlsState();
}

class _NonCounterVersionAndAuditControlsState
    extends ConsumerState<NonCounterVersionAndAuditControls> {
  final _random = Random.secure();
  final _name = TextEditingController();
  final _checklistItems = TextEditingController();
  final _maxIncidents = TextEditingController(text: '0');
  final _durationMinutes = TextEditingController(text: '30');
  final _measurementValue = TextEditingController(text: '2.0');
  final _rangeMin = TextEditingController(text: '1.0');
  final _rangeMax = TextEditingController(text: '2.0');
  final _unit = TextEditingController(text: 'units');
  final _timeOfDay = TextEditingController(text: '06:00');
  final _tolerance = TextEditingController();
  final _intervalDays = TextEditingController(text: '2');
  final _monthDay = TextEditingController(text: '1');
  final _category = TextEditingController(text: 'Personal');
  final _description = TextEditingController();
  final _symbol = TextEditingController();
  final _displayOrder = TextEditingController(text: '0');
  final _weekdays = <int>{1, 2, 3, 4, 5};

  NonCounterConfigurationAndAudit? _bundle;
  bool _loading = true;
  bool _busy = false;
  bool _expanded = false;
  String? _error;
  int _generation = 0;

  late LocalDate _effectiveStart;
  _NonCounterScheduleKind _scheduleKind = _NonCounterScheduleKind.daily;
  bool _monthlyLastDayFallback = false;
  bool _checklistItemRecovery = true;
  MeasurementComparisonRule _measurementRule =
      MeasurementComparisonRule.atLeast;
  TimeComparisonRule _timeRule = TimeComparisonRule.atOrBefore;
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

  LocalDate _minAllowedStart(NonCounterConfigurationAndAudit? bundle) {
    final afterToday = _nextDay(_today);
    if (bundle == null || bundle.allVersions.isEmpty) return afterToday;
    final afterLatest = _nextDay(bundle.allVersions.last.effectiveStart);
    return afterLatest.compareTo(afterToday) > 0 ? afterLatest : afterToday;
  }

  @override
  void initState() {
    super.initState();
    _effectiveStart = _nextDay(widget.date);
    _load();
  }

  @override
  void didUpdateWidget(covariant NonCounterVersionAndAuditControls oldWidget) {
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
      _checklistItems,
      _maxIncidents,
      _durationMinutes,
      _measurementValue,
      _rangeMin,
      _rangeMax,
      _unit,
      _timeOfDay,
      _tolerance,
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
      final bundle = await ref
          .read(nonCounterVersionServiceProvider)
          .readConfigurationAndAudit(
            habitId: widget.habit.habitId,
            asOfDate: widget.date,
          );
      final scoring = bundle.allVersions.isEmpty
          ? null
          : await HabitScoringStore(ref.read(databaseProvider))
                .findForVersion(bundle.allVersions.last.id);
      if (!mounted || generation != _generation) return;
      _populateFromLatest(bundle, scoring);
      setState(() {
        _bundle = bundle;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _bundle = null;
        _loading = false;
        _error = 'Could not load version configuration.';
      });
    }
  }

  void _populateFromLatest(
    NonCounterConfigurationAndAudit bundle,
    HabitScoringConfig? scoring,
  ) {
    _effectiveStart = _minAllowedStart(bundle);
    if (bundle.allVersions.isEmpty) return;
    final latest = bundle.allVersions.last;
    _tolerance.clear();
    if (scoring?.tolerance != null) {
      if (latest.trackingType == HabitTrackingType.timeOfDay &&
          scoring!.type == DynamicScoreType.timeOfDay) {
        _tolerance.text = '${scoring.tolerance}';
      } else if (latest.trackingType == HabitTrackingType.range &&
          scoring!.type == DynamicScoreType.range &&
          latest.rangeTarget != null) {
        _tolerance.text = _formatScaled(
          scoring.tolerance!,
          latest.rangeTarget!.decimalPlaces,
        );
      }
    }
    _name.text = latest.name;

    switch (latest.trackingType) {
      case HabitTrackingType.checklist:
        final items = latest.checklistItems ?? const [];
        _checklistItems.text = items.map((e) => e.label).join(', ');
        _checklistItemRecovery = items.isEmpty || items.first.recoveryEnabled;
      case HabitTrackingType.avoidance:
        _maxIncidents.text = '${latest.avoidanceTarget?.maxIncidents ?? 0}';
      case HabitTrackingType.duration:
        final secs = latest.durationTarget?.targetSeconds ?? 1800;
        _durationMinutes.text = '${(secs / 60).ceil()}';
      case HabitTrackingType.measurement:
        final t = latest.measurementTarget;
        if (t != null) {
          _measurementValue.text = _formatScaled(
            t.scaledTarget,
            t.decimalPlaces,
          );
          _unit.text = t.unit;
          _measurementRule = t.rule;
        }
      case HabitTrackingType.timeOfDay:
        final t = latest.timeOfDayTarget;
        if (t != null) {
          final h = (t.targetMinutesSinceMidnight ~/ 60).toString().padLeft(
            2,
            '0',
          );
          final m = (t.targetMinutesSinceMidnight % 60).toString().padLeft(
            2,
            '0',
          );
          _timeOfDay.text = '$h:$m';
          _timeRule = t.rule;
        }
      case HabitTrackingType.range:
        final t = latest.rangeTarget;
        if (t != null) {
          _rangeMin.text = _formatScaled(t.minScaled, t.decimalPlaces);
          _rangeMax.text = _formatScaled(t.maxScaled, t.decimalPlaces);
          _unit.text = t.unit;
        }
      case HabitTrackingType.boolean ||
          HabitTrackingType.counter ||
          HabitTrackingType.unconfigured:
        break;
    }

    switch (latest.schedule) {
      case DailySchedule() || null:
        _scheduleKind = _NonCounterScheduleKind.daily;
      case WeekdaySchedule(:final weekdays):
        _scheduleKind = _NonCounterScheduleKind.weekdays;
        _weekdays
          ..clear()
          ..addAll(weekdays);
      case IntervalSchedule(:final everyDays):
        _scheduleKind = _NonCounterScheduleKind.interval;
        _intervalDays.text = '$everyDays';
      case MonthlyDaySchedule(:final dayOfMonth, :final lastDayFallback):
        _scheduleKind = _NonCounterScheduleKind.monthly;
        _monthDay.text = '$dayOfMonth';
        _monthlyLastDayFallback = lastDayFallback;
      case OneTimeSchedule():
        _scheduleKind = _NonCounterScheduleKind.oneTime;
    }

    final meta = latest.metadata;
    if (meta != null) {
      _includeMetadata = true;
      _category.text = meta.category;
      _description.text = meta.description ?? '';
      _symbol.text = meta.symbol ?? '';
      _priority = meta.priority;
      _isPrivate = meta.isPrivate;
      _recoveryEnabled =
          latest.trackingType != HabitTrackingType.avoidance &&
          meta.recoveryEnabled;
      _includeInScore = meta.includeInScore;
      _includeInStreak = meta.includeInStreak;
      _includeInRewards = meta.includeInRewards;
      _displayOrder.text = '${meta.displayOrder}';
    } else {
      _includeMetadata = false;
    }
  }

  Future<void> _submit() async {
    final bundle = _bundle;
    if (_busy || _loading || bundle == null || bundle.allVersions.isEmpty) {
      return;
    }
    if (widget.date.compareTo(_today) != 0) {
      setState(() {
        _error = 'Future versions can only be scheduled on the current day.';
      });
      return;
    }
    final latest = bundle.allVersions.last;
    if (latest.effectiveEnd != null ||
        latest.trackingType == HabitTrackingType.unconfigured) {
      setState(() {
        _error = 'Habit must have an open configured version.';
      });
      return;
    }
    final minStart = _minAllowedStart(bundle);
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

    HabitSchedule schedule;
    switch (_scheduleKind) {
      case _NonCounterScheduleKind.daily:
        schedule = DailySchedule(start: _effectiveStart);
      case _NonCounterScheduleKind.weekdays:
        if (_weekdays.isEmpty) {
          setState(() => _error = 'Select at least one weekday.');
          return;
        }
        schedule = WeekdaySchedule(
          start: _effectiveStart,
          weekdays: Set<int>.from(_weekdays),
        );
      case _NonCounterScheduleKind.interval:
        final every = int.tryParse(_intervalDays.text.trim());
        if (every == null || every <= 0) {
          setState(() => _error = 'Enter an interval of at least 1 day.');
          return;
        }
        schedule = IntervalSchedule(start: _effectiveStart, everyDays: every);
      case _NonCounterScheduleKind.monthly:
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
      case _NonCounterScheduleKind.oneTime:
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
        recoveryEnabled:
            latest.trackingType != HabitTrackingType.avoidance &&
            _recoveryEnabled,
        includeInScore: _includeInScore,
        includeInStreak: _includeInStreak,
        includeInRewards: _includeInRewards,
        displayOrder: order,
      );
    }

    final effDateTime = DateTime(
      _effectiveStart.year,
      _effectiveStart.month,
      _effectiveStart.day,
    );
    final service = ref.read(nonCounterVersionServiceProvider);

    setState(() {
      _busy = true;
      _error = null;
    });
    final habitId = widget.habit.habitId;
    try {
      switch (latest.trackingType) {
        case HabitTrackingType.checklist:
          final labels = _checklistItems.text
              .split(RegExp(r'[,\n]'))
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          if (labels.isEmpty) {
            setState(() {
              _busy = false;
              _error = 'Enter at least one checklist item label.';
            });
            return;
          }
          await service.scheduleChecklistVersion(
            habitId: habitId,
            versionId: _id(),
            auditId: _id(),
            name: trimmedName,
            effectiveDate: effDateTime,
            items: [
              for (var i = 0; i < labels.length; i++)
                ChecklistItemDefinition(
                  id: _id(),
                  label: labels[i],
                  displayOrder: i,
                  recoveryEnabled: _checklistItemRecovery,
                ),
            ],
            schedule: schedule,
            metadata: metadata,
          );
        case HabitTrackingType.avoidance:
          final maxInc = int.tryParse(_maxIncidents.text.trim());
          if (maxInc == null || maxInc < 0) {
            setState(() {
              _busy = false;
              _error = 'Enter a non-negative integer for max incidents.';
            });
            return;
          }
          await service.scheduleAvoidanceVersion(
            habitId: habitId,
            versionId: _id(),
            auditId: _id(),
            name: trimmedName,
            effectiveDate: effDateTime,
            target: AvoidanceTarget(maxIncidents: maxInc),
            schedule: schedule,
            metadata: metadata,
          );
        case HabitTrackingType.boolean:
          await service.scheduleBooleanVersion(
            habitId: habitId,
            versionId: _id(),
            auditId: _id(),
            name: trimmedName,
            effectiveDate: effDateTime,
            schedule: schedule,
            metadata: metadata,
          );
        case HabitTrackingType.duration:
          final mins = int.tryParse(_durationMinutes.text.trim());
          if (mins == null || mins <= 0) {
            setState(() {
              _busy = false;
              _error = 'Enter a positive whole number of target minutes.';
            });
            return;
          }
          await service.scheduleDurationVersion(
            habitId: habitId,
            versionId: _id(),
            auditId: _id(),
            name: trimmedName,
            effectiveDate: effDateTime,
            target: DurationTarget(targetSeconds: mins * 60),
            schedule: schedule,
            metadata: metadata,
          );
        case HabitTrackingType.measurement:
          final parsed = _parseDecimal(_measurementValue.text.trim());
          final unit = _unit.text.trim();
          if (parsed == null || unit.isEmpty) {
            setState(() {
              _busy = false;
              _error = 'Enter a valid measurement target and nonblank unit.';
            });
            return;
          }
          await service.scheduleMeasurementVersion(
            habitId: habitId,
            versionId: _id(),
            auditId: _id(),
            name: trimmedName,
            effectiveDate: effDateTime,
            target: MeasurementTarget(
              scaledTarget: parsed.$1,
              decimalPlaces: parsed.$2,
              unit: unit,
              rule: _measurementRule,
            ),
            schedule: schedule,
            metadata: metadata,
            scoring: const HabitScoringConfig.measurement(),
          );
        case HabitTrackingType.timeOfDay:
          final minutes = _parseTimeMinutes(_timeOfDay.text.trim());
          if (minutes == null) {
            setState(() {
              _busy = false;
              _error = 'Enter time in HH:MM (00:00 to 23:59).';
            });
            return;
          }
          final tolerance = int.tryParse(_tolerance.text.trim());
          if (tolerance == null || tolerance <= 0) {
            setState(() {
              _busy = false;
              _error = 'Enter a positive whole number of tolerance minutes.';
            });
            return;
          }
          await service.scheduleTimeOfDayVersion(
            habitId: habitId,
            versionId: _id(),
            auditId: _id(),
            name: trimmedName,
            effectiveDate: effDateTime,
            target: TimeOfDayTarget(
              targetMinutesSinceMidnight: minutes,
              rule: _timeRule,
            ),
            schedule: schedule,
            metadata: metadata,
            scoring: HabitScoringConfig.timeOfDay(toleranceMinutes: tolerance),
          );
        case HabitTrackingType.range:
          final minParsed = _parseDecimal(_rangeMin.text.trim());
          final maxParsed = _parseDecimal(_rangeMax.text.trim());
          final unit = _unit.text.trim();
          if (minParsed == null || maxParsed == null || unit.isEmpty) {
            setState(() {
              _busy = false;
              _error = 'Enter valid minimum, maximum and nonblank unit.';
            });
            return;
          }
          final tolerance = _parseDecimal(_tolerance.text.trim());
          if (tolerance == null || tolerance.$1 <= 0) {
            setState(() {
              _busy = false;
              _error = 'Enter a positive score tolerance.';
            });
            return;
          }
          final places = max(max(minParsed.$2, maxParsed.$2), tolerance.$2);
          final minScaled = _rescale(minParsed.$1, minParsed.$2, places);
          final maxScaled = _rescale(maxParsed.$1, maxParsed.$2, places);
          if (minScaled > maxScaled) {
            setState(() {
              _busy = false;
              _error = 'Minimum target must not exceed maximum target.';
            });
            return;
          }
          await service.scheduleRangeVersion(
            habitId: habitId,
            versionId: _id(),
            auditId: _id(),
            name: trimmedName,
            effectiveDate: effDateTime,
            target: RangeTarget(
              minScaled: minScaled,
              maxScaled: maxScaled,
              decimalPlaces: places,
              unit: unit,
            ),
            schedule: schedule,
            metadata: metadata,
            scoring: HabitScoringConfig.range(
              toleranceScaled: _rescale(tolerance.$1, tolerance.$2, places),
            ),
          );
        case HabitTrackingType.counter || HabitTrackingType.unconfigured:
          break;
      }
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

  String _describeVersion(NonCounterVersionSnapshot v) {
    final isPrivateVersion = v.metadata?.isPrivate == true;
    final endStr = v.effectiveEnd == null
        ? 'open'
        : _formatDate(v.effectiveEnd!);
    if (isPrivateVersion && !widget.showPrivateHistory) {
      return 'Revision ${v.revision}: Private version (${_formatDate(v.effectiveStart)} to $endStr)';
    }
    return 'Revision ${v.revision}: ${v.name} — ${v.targetSummary} (${_formatDate(v.effectiveStart)} to $endStr)';
  }

  @override
  Widget build(BuildContext context) {
    final bundle = _bundle;
    final latest = bundle == null || bundle.allVersions.isEmpty
        ? null
        : bundle.allVersions.last;
    final canSchedule =
        !_loading &&
        !_busy &&
        widget.date.compareTo(_today) == 0 &&
        latest != null &&
        latest.effectiveEnd == null &&
        latest.trackingType != HabitTrackingType.unconfigured;

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
        if (!_loading && bundle != null) ...[
          if (bundle.effectiveVersion != null)
            Text('Effective: ${_describeVersion(bundle.effectiveVersion!)}'),
          if (bundle.futureVersions.isNotEmpty) ...[
            const Text('Scheduled future versions:'),
            for (final fv in bundle.futureVersions)
              Text('• ${_describeVersion(fv)}'),
          ],
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: canSchedule
                    ? () => setState(() => _expanded = !_expanded)
                    : null,
                child: Text(
                  _expanded
                      ? 'Cancel future version'
                      : 'Schedule future version',
                ),
              ),
              OutlinedButton(
                onPressed: () {
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (context) => FractionallySizedBox(
                      heightFactor: 0.85,
                      child: NonCounterAuditHistorySheet(
                        habit: widget.habit,
                        date: widget.date,
                        showPrivateHistory: widget.showPrivateHistory,
                      ),
                    ),
                  );
                },
                child: const Text('View history & audit'),
              ),
            ],
          ),
          if (_expanded && canSchedule) ...[
            TextField(
              controller: _name,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Future version name',
              ),
            ),
            ..._buildTypedTargetFields(latest.trackingType),
            DropdownButtonFormField<_NonCounterScheduleKind>(
              initialValue: _scheduleKind,
              decoration: const InputDecoration(labelText: 'Future schedule'),
              items: const [
                DropdownMenuItem(
                  value: _NonCounterScheduleKind.daily,
                  child: Text('Daily'),
                ),
                DropdownMenuItem(
                  value: _NonCounterScheduleKind.weekdays,
                  child: Text('Weekdays'),
                ),
                DropdownMenuItem(
                  value: _NonCounterScheduleKind.interval,
                  child: Text('Interval'),
                ),
                DropdownMenuItem(
                  value: _NonCounterScheduleKind.monthly,
                  child: Text('Monthly'),
                ),
                DropdownMenuItem(
                  value: _NonCounterScheduleKind.oneTime,
                  child: Text('One-time'),
                ),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _scheduleKind = v!),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Save version metadata'),
              value: _includeMetadata,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _includeMetadata = v),
            ),
            if (_includeMetadata)
              TextField(
                controller: _category,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'Future category'),
              ),
            ElevatedButton(
              key: const Key('non-counter-future-version-submit'),
              onPressed: _busy ? null : _submit,
              child: const Text('Save future version'),
            ),
          ],
        ],
      ],
    );
  }

  List<Widget> _buildTypedTargetFields(HabitTrackingType type) {
    switch (type) {
      case HabitTrackingType.checklist:
        return [
          TextField(
            controller: _checklistItems,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Future checklist items (comma-separated)',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow item recovery on future version'),
            value: _checklistItemRecovery,
            onChanged: _busy
                ? null
                : (v) => setState(() => _checklistItemRecovery = v),
          ),
        ];
      case HabitTrackingType.avoidance:
        return [
          TextField(
            controller: _maxIncidents,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Future max incidents',
            ),
          ),
        ];
      case HabitTrackingType.boolean:
        return const [];
      case HabitTrackingType.duration:
        return [
          TextField(
            controller: _durationMinutes,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Future target minutes',
            ),
          ),
        ];
      case HabitTrackingType.measurement:
        return [
          TextField(
            controller: _measurementValue,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Future measurement target',
            ),
          ),
          TextField(
            controller: _unit,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Future target unit'),
          ),
          DropdownButtonFormField<MeasurementComparisonRule>(
            initialValue: _measurementRule,
            decoration: const InputDecoration(labelText: 'Future comparison'),
            items: MeasurementComparisonRule.values
                .map(
                  (rule) =>
                      DropdownMenuItem(value: rule, child: Text(rule.name)),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (v) => setState(() => _measurementRule = v!),
          ),
        ];
      case HabitTrackingType.timeOfDay:
        return [
          TextField(
            controller: _timeOfDay,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Future target time (HH:MM)',
            ),
          ),
          DropdownButtonFormField<TimeComparisonRule>(
            initialValue: _timeRule,
            decoration: const InputDecoration(labelText: 'Future comparison'),
            items: const [
              DropdownMenuItem(
                value: TimeComparisonRule.atOrBefore,
                child: Text('At or before'),
              ),
              DropdownMenuItem(
                value: TimeComparisonRule.atOrAfter,
                child: Text('At or after'),
              ),
              DropdownMenuItem(
                value: TimeComparisonRule.atOrNear,
                child: Text('At or near'),
              ),
            ],
            onChanged: _busy ? null : (v) => setState(() => _timeRule = v!),
          ),
          if (_timeRule == TimeComparisonRule.atOrNear)
            const Text('At or near completes only at the exact target minute.'),
          TextField(
            controller: _tolerance,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Future score tolerance (minutes)',
            ),
          ),
        ];
      case HabitTrackingType.range:
        return [
          TextField(
            controller: _rangeMin,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Future minimum value',
            ),
          ),
          TextField(
            controller: _rangeMax,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Future maximum value',
            ),
          ),
          TextField(
            controller: _unit,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Future target unit'),
          ),
          TextField(
            controller: _tolerance,
            enabled: !_busy,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Future score tolerance (target units)',
            ),
          ),
        ];
      case HabitTrackingType.counter || HabitTrackingType.unconfigured:
        return const [];
    }
  }
}

/// Read-only modal inspector displaying a non-counter habit's version timeline,
/// lifecycle history and `habit_version_audit` snapshots with private redaction.
class NonCounterAuditHistorySheet extends ConsumerStatefulWidget {
  const NonCounterAuditHistorySheet({
    super.key,
    required this.habit,
    required this.date,
    required this.showPrivateHistory,
  });

  final UnifiedHabitSummary habit;
  final LocalDate date;
  final bool showPrivateHistory;

  @override
  ConsumerState<NonCounterAuditHistorySheet> createState() =>
      _NonCounterAuditHistorySheetState();
}

class _NonCounterAuditHistorySheetState
    extends ConsumerState<NonCounterAuditHistorySheet> {
  late Future<NonCounterConfigurationAndAudit> _bundle;

  String _formatDate(LocalDate d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _bundle = ref
        .read(nonCounterVersionServiceProvider)
        .readConfigurationAndAudit(
          habitId: widget.habit.habitId,
          asOfDate: widget.date,
        );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<NonCounterConfigurationAndAudit>(
          future: _bundle,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Could not load version and audit history.'),
                  TextButton(
                    onPressed: () => setState(_load),
                    child: const Text('Retry'),
                  ),
                ],
              );
            }
            final data = snapshot.data!;
            final hasPrivateVersion =
                widget.habit.metadata?.isPrivate == true ||
                data.allVersions.any((v) => v.metadata?.isPrivate == true);
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
                    'Configured versions (${data.allVersions.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final v in data.allVersions)
                    Text(
                      '• Revision ${v.revision}: ${v.name} — ${v.targetSummary} '
                      '(${_formatDate(v.effectiveStart)} to ${v.effectiveEnd == null ? 'open' : _formatDate(v.effectiveEnd!)})',
                    ),
                  const Divider(height: 24),
                  Text(
                    'Version audits (${data.versionAudits.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final va in data.versionAudits)
                    Text('• [${va.operation}] id=${va.id}'),
                  const SizedBox(height: 8),
                  Text(
                    'Lifecycle events (${data.lifecycleHistory.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final le in data.lifecycleHistory)
                    Text(
                      '• ${_formatDate(le.effectiveDate)}: ${le.previousState?.name ?? 'none'} -> ${le.state.name}'
                      '${le.reason == null ? '' : ' (${le.reason})'}',
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

(int, int)? _parseDecimal(String text) {
  final match = RegExp(r'^(-?)([0-9]+)(?:\.([0-9]{1,6}))?$').firstMatch(text);
  if (match == null) return null;
  final neg = match.group(1) == '-';
  final whole = match.group(2)!;
  final frac = match.group(3) ?? '';
  final places = frac.length;
  final scaled = int.tryParse('$whole$frac');
  if (scaled == null) return null;
  return (neg ? -scaled : scaled, places);
}

int _rescale(int value, int fromPlaces, int toPlaces) {
  var result = value;
  for (var i = fromPlaces; i < toPlaces; i++) {
    result *= 10;
  }
  return result;
}

int? _parseTimeMinutes(String text) {
  final match = RegExp(r'^([0-9]{1,2}):([0-9]{2})$').firstMatch(text);
  if (match == null) return null;
  final h = int.parse(match.group(1)!);
  final m = int.parse(match.group(2)!);
  if (h < 0 || h > 23 || m < 0 || m > 59) return null;
  return h * 60 + m;
}

String _formatScaled(int scaled, int decimalPlaces) {
  if (decimalPlaces <= 0) return '$scaled';
  final negative = scaled < 0;
  final absVal = scaled.abs().toString().padLeft(decimalPlaces + 1, '0');
  final split = absVal.length - decimalPlaces;
  final whole = absVal.substring(0, split);
  final frac = absVal.substring(split);
  return '${negative ? '-' : ''}$whole.$frac';
}
