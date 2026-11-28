import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../application/counter_habit_providers.dart';
import '../domain/avoidance_habit.dart';
import '../domain/boolean_duration_habit.dart';
import '../domain/checklist_habit.dart';
import '../domain/counter_target.dart';
import '../domain/dynamic_normalized_scoring.dart';
import '../domain/habit_metadata.dart';
import '../domain/habit_schedule.dart';
import '../domain/measurement_time_range_habit.dart';
import '../domain/starter_template_catalog.dart';

enum _TrackingType {
  counter,
  checklist,
  avoidance,
  boolean,
  duration,
  measurement,
  timeOfDay,
  range,
}

enum _ScheduleType { daily, weekdays, interval, monthly, oneTime }

class HabitBuilderScreen extends ConsumerStatefulWidget {
  const HabitBuilderScreen({super.key});

  @override
  ConsumerState<HabitBuilderScreen> createState() => _HabitBuilderScreenState();
}

class _HabitBuilderScreenState extends ConsumerState<HabitBuilderScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _category = TextEditingController(text: 'Personal');
  final _description = TextEditingController();
  final _symbol = TextEditingController();
  final _target = TextEditingController(text: '1');
  final _unit = TextEditingController(text: 'times');
  final _items = TextEditingController();
  final _places = TextEditingController(text: '0');
  final _minimum = TextEditingController(text: '0');
  final _maximum = TextEditingController(text: '1');
  final _time = TextEditingController(text: '09:00');
  final _tolerance = TextEditingController();
  final _interval = TextEditingController(text: '2');
  final _monthDay = TextEditingController(text: '1');
  final _order = TextEditingController(text: '0');
  final _weekdays = <int>{1, 2, 3, 4, 5};
  _TrackingType _type = _TrackingType.counter;
  _ScheduleType _schedule = _ScheduleType.daily;
  String _template = 'None';
  DateTime? _start;
  HabitPriority _priority = HabitPriority.normal;
  MeasurementComparisonRule _measurementRule =
      MeasurementComparisonRule.atLeast;
  TimeComparisonRule _timeRule = TimeComparisonRule.atOrBefore;
  bool _fallback = false, _private = false, _recovery = false;
  bool _score = true, _streak = true, _rewards = true, _submitting = false;

  @override
  void dispose() {
    for (final controller in [
      _name,
      _category,
      _description,
      _symbol,
      _target,
      _unit,
      _items,
      _places,
      _minimum,
      _maximum,
      _time,
      _tolerance,
      _interval,
      _monthDay,
      _order,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  DateTime get _today {
    final now = ref.read(appClockProvider).now().toLocal();
    return DateTime(now.year, now.month, now.day);
  }

  void _selectTemplate(String value) {
    setState(() {
      _template = value;
      _private = false;
      _recovery = false;
      _category.text = 'Personal';
      _name.clear();
      _symbol.clear();
      _target.text = '1';
      _unit.text = 'times';
      _items.clear();
      switch (value) {
        case 'Self Control':
          final template = StarterTemplateCatalog.selfControl;
          _type = _TrackingType.avoidance;
          _name.text = template.name;
          _symbol.text = template.symbol;
          _target.text = '${template.target.maxIncidents}';
          _private = template.isPrivate;
        case 'Quran Reading':
          final template = StarterTemplateCatalog.quranReading;
          _type = _TrackingType.counter;
          _name.text = template.name;
          _symbol.text = template.symbol;
          _target.text = '${template.target.count}';
          _unit.text = template.target.unit;
          _recovery = true;
        case 'Daily Prayers':
          final template = StarterTemplateCatalog.dailyPrayers;
          _type = _TrackingType.checklist;
          _name.text = template.name;
          _symbol.text = template.symbol;
          _items.text = template.itemLabels.join('\n');
          _recovery = template.recoveryEnabled;
        case 'Push Up':
          final template = StarterTemplateCatalog.pushUp;
          _type = _TrackingType.counter;
          _name.text = template.name;
          _symbol.text = template.symbol;
          _target.text = '${template.target.count}';
          _unit.text = template.target.unit;
        case 'None':
          _type = _TrackingType.counter;
      }
    });
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Required' : null;
  String? _integer(String? value, {int min = 0, int? max}) {
    final n = int.tryParse(value?.trim() ?? '');
    return n == null || n < min || (max != null && n > max)
        ? 'Enter a valid value'
        : null;
  }

  // Parse decimal text directly into SQLite's signed 64-bit integer range.
  int? _scaled(String text, int places) {
    final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d+))?$').firstMatch(text.trim());
    if (match == null) return null;
    final fraction = match.group(3) ?? '';
    if (fraction.length > places) return null;
    final digits =
        '${match.group(1) == '-' ? '-' : ''}${match.group(2)}${fraction.padRight(places, '0')}';
    final big = BigInt.tryParse(digits);
    if (big == null ||
        big < BigInt.parse('-9223372036854775808') ||
        big > BigInt.parse('9223372036854775807')) {
      return null;
    }
    return big.toInt();
  }

  String? _scaledValidator(String? text) {
    final places = int.tryParse(_places.text);
    if (places == null ||
        places < 0 ||
        places > 6 ||
        _scaled(text ?? '', places) == null) {
      return 'Enter a valid value';
    }
    return null;
  }

  int? _minutes(String text) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(text.trim());
    if (match == null) return null;
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    return hour < 24 && minute < 60 ? hour * 60 + minute : null;
  }

  String _id() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  HabitSchedule _buildSchedule(LocalDate start) => switch (_schedule) {
    _ScheduleType.daily => DailySchedule(start: start),
    _ScheduleType.weekdays => WeekdaySchedule(
      start: start,
      weekdays: _weekdays,
    ),
    _ScheduleType.interval => IntervalSchedule(
      start: start,
      everyDays: int.parse(_interval.text.trim()),
    ),
    _ScheduleType.monthly => MonthlyDaySchedule(
      start: start,
      dayOfMonth: int.parse(_monthDay.text.trim()),
      lastDayFallback: _fallback,
    ),
    _ScheduleType.oneTime => OneTimeSchedule(date: start),
  };

  Future<void> _submit() async {
    if (_submitting || !(_form.currentState?.validate() ?? false)) return;
    final date = _start ?? _today;
    if (date.isBefore(_today)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Start date must be today or later')),
      );
      return;
    }
    if (_schedule == _ScheduleType.weekdays && _weekdays.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one weekday')),
      );
      return;
    }
    if (_type == _TrackingType.range &&
        _scaled(_minimum.text, int.parse(_places.text))! >
            _scaled(_maximum.text, int.parse(_places.text))!) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Maximum must be at least the minimum')),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      final habitId = _id(), versionId = _id(), eventId = _id();
      final schedule = _buildSchedule(
        LocalDate(date.year, date.month, date.day),
      );
      final metadata = HabitMetadata(
        category: _category.text,
        description: _description.text.trim().isEmpty
            ? null
            : _description.text,
        symbol: _symbol.text.trim().isEmpty ? null : _symbol.text,
        priority: _priority,
        isPrivate: _private,
        recoveryEnabled: _type != _TrackingType.avoidance && _recovery,
        includeInScore: _score,
        includeInStreak: _streak,
        includeInRewards: _rewards,
        displayOrder: int.parse(_order.text.trim()),
      );
      final name = _name.text.trim();
      switch (_type) {
        case _TrackingType.counter:
          await ref.read(databaseProvider).transaction(() async {
            await ref
                .read(counterHabitWriterProvider)
                .create(
                  habitId: habitId,
                  versionId: versionId,
                  auditId: _id(),
                  lifecycleEventId: eventId,
                  name: name,
                  effectiveDate: date,
                  target: CounterTarget(
                    count: int.parse(_target.text.trim()),
                    unit: _unit.text,
                  ),
                  schedule: schedule,
                );
            await ref
                .read(habitMetadataStoreProvider)
                .insert(versionId, metadata);
          });
        case _TrackingType.checklist:
          final labels = _items.text
              .split('\n')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList();
          await ref
              .read(checklistHabitServiceProvider)
              .create(
                habitId: habitId,
                versionId: versionId,
                lifecycleEventId: eventId,
                name: name,
                effectiveDate: date,
                items: [
                  for (var i = 0; i < labels.length; i++)
                    ChecklistItemDefinition(
                      id: _id(),
                      label: labels[i],
                      displayOrder: i,
                      recoveryEnabled: _recovery,
                    ),
                ],
                schedule: schedule,
                metadata: metadata,
              );
        case _TrackingType.avoidance:
          await ref
              .read(avoidanceHabitServiceProvider)
              .create(
                habitId: habitId,
                versionId: versionId,
                lifecycleEventId: eventId,
                name: name,
                effectiveDate: date,
                target: AvoidanceTarget(
                  maxIncidents: int.parse(_target.text.trim()),
                ),
                schedule: schedule,
                metadata: metadata,
              );
        case _TrackingType.boolean:
          await ref
              .read(booleanDurationHabitServiceProvider)
              .createBoolean(
                habitId: habitId,
                versionId: versionId,
                lifecycleEventId: eventId,
                name: name,
                effectiveDate: date,
                schedule: schedule,
                metadata: metadata,
              );
        case _TrackingType.duration:
          await ref
              .read(booleanDurationHabitServiceProvider)
              .createDuration(
                habitId: habitId,
                versionId: versionId,
                lifecycleEventId: eventId,
                name: name,
                effectiveDate: date,
                target: DurationTarget(
                  targetSeconds: int.parse(_target.text.trim()),
                ),
                schedule: schedule,
                metadata: metadata,
              );
        case _TrackingType.measurement:
          final places = int.parse(_places.text.trim());
          await ref
              .read(measurementTimeRangeHabitServiceProvider)
              .createMeasurement(
                habitId: habitId,
                versionId: versionId,
                lifecycleEventId: eventId,
                name: name,
                effectiveDate: date,
                target: MeasurementTarget(
                  scaledTarget: _scaled(_target.text, places)!,
                  decimalPlaces: places,
                  unit: _unit.text,
                  rule: _measurementRule,
                ),
                schedule: schedule,
                metadata: metadata,
                scoring: const HabitScoringConfig.measurement(),
              );
        case _TrackingType.timeOfDay:
          await ref
              .read(measurementTimeRangeHabitServiceProvider)
              .createTimeOfDay(
                habitId: habitId,
                versionId: versionId,
                lifecycleEventId: eventId,
                name: name,
                effectiveDate: date,
                target: TimeOfDayTarget(
                  targetMinutesSinceMidnight: _minutes(_time.text)!,
                  rule: _timeRule,
                ),
                schedule: schedule,
                metadata: metadata,
                scoring: HabitScoringConfig.timeOfDay(
                  toleranceMinutes: int.parse(_tolerance.text.trim()),
                ),
              );
        case _TrackingType.range:
          final places = int.parse(_places.text.trim());
          await ref
              .read(measurementTimeRangeHabitServiceProvider)
              .createRange(
                habitId: habitId,
                versionId: versionId,
                lifecycleEventId: eventId,
                name: name,
                effectiveDate: date,
                target: RangeTarget(
                  minScaled: _scaled(_minimum.text, places)!,
                  maxScaled: _scaled(_maximum.text, places)!,
                  decimalPlaces: places,
                  unit: _unit.text,
                ),
                schedule: schedule,
                metadata: metadata,
                scoring: HabitScoringConfig.range(
                  toleranceScaled: _scaled(_tolerance.text, places)!,
                ),
              );
      }
      ref.invalidate(counterTodayRosterProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not create habit. Please try again.'),
          ),
        );
      }
      if (mounted) setState(() => _submitting = false);
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Habit created')));
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go('/');
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? Function(String?)? validator,
    bool number = false,
    int lines = 1,
  }) => TextFormField(
    controller: controller,
    enabled: !_submitting,
    maxLines: lines,
    keyboardType: number
        ? const TextInputType.numberWithOptions(signed: true, decimal: true)
        : null,
    decoration: InputDecoration(labelText: label),
    validator: validator,
  );

  Widget _suggestedField({
    required String label,
    required String explanation,
    required TextEditingController controller,
    required List<String> suggestions,
    required String? Function(String?) validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _field(label, controller, validator: validator),
        const SizedBox(height: 8),
        Text(explanation),
        const SizedBox(height: 8),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) => Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final suggestion in suggestions)
                ChoiceChip(
                  label: Text(suggestion),
                  selected: value.text == suggestion,
                  onSelected: _submitting
                      ? null
                      : (_) => controller.text = suggestion,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _section({
    required IconData icon,
    required String title,
    required String description,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Icon(icon, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(description, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(height: 24),
              children[i],
            ],
          ],
        ),
      ),
    );
  }

  Widget _switchOption({
    required String label,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return Row(
      children: [
        Expanded(child: ExcludeSemantics(child: Text(label))),
        Semantics(
          label: label,
          child: Switch(
            key: ValueKey('builder-switch-$label'),
            value: value,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final date = _start ?? _today;
    return Scaffold(
      appBar: AppBar(title: const Text('Habit Builder')),
      body: SafeArea(
        top: false,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Make space for what matters',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Start with a small step. Choose a template or make a habit your own.',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 24),
                    _section(
                      icon: Icons.auto_awesome_outlined,
                      title: 'The basics',
                      description: 'Give your habit a name and make it yours.',
                      children: [
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: _template,
                          decoration: const InputDecoration(
                            labelText: 'Starter template',
                          ),
                          items:
                              const [
                                    'None',
                                    'Self Control',
                                    'Quran Reading',
                                    'Daily Prayers',
                                    'Push Up',
                                  ]
                                  .map(
                                    (v) => DropdownMenuItem(
                                      value: v,
                                      child: Text(v),
                                    ),
                                  )
                                  .toList(),
                          onChanged: _submitting
                              ? null
                              : (v) => _selectTemplate(v!),
                        ),
                        _field('Name', _name, validator: _required),
                        _suggestedField(
                          label: 'Category',
                          explanation: 'Group similar habits, or type your own category.',
                          controller: _category,
                          suggestions: const ['Personal', 'Health', 'Fitness', 'Learning'],
                          validator: _required,
                        ),
                        _field('Description', _description),
                        _field('Symbol', _symbol),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _section(
                      icon: Icons.track_changes_outlined,
                      title: 'How will you track it?',
                      description:
                          'Choose the kind of progress you want to record.',
                      children: [
                        DropdownButtonFormField<_TrackingType>(
                          isExpanded: true,
                          initialValue: _type,
                          decoration: const InputDecoration(
                            labelText: 'Tracking type',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: _TrackingType.counter,
                              child: Text('Counter'),
                            ),
                            DropdownMenuItem(
                              value: _TrackingType.checklist,
                              child: Text('Checklist'),
                            ),
                            DropdownMenuItem(
                              value: _TrackingType.avoidance,
                              child: Text('Avoidance'),
                            ),
                            DropdownMenuItem(
                              value: _TrackingType.boolean,
                              child: Text('Boolean'),
                            ),
                            DropdownMenuItem(
                              value: _TrackingType.duration,
                              child: Text('Duration'),
                            ),
                            DropdownMenuItem(
                              value: _TrackingType.measurement,
                              child: Text('Measurement'),
                            ),
                            DropdownMenuItem(
                              value: _TrackingType.timeOfDay,
                              child: Text('Time of Day'),
                            ),
                            DropdownMenuItem(
                              value: _TrackingType.range,
                              child: Text('Range'),
                            ),
                          ],
                          onChanged: _submitting
                              ? null
                              : (v) => setState(() => _type = v!),
                        ),
                        if (_type == _TrackingType.counter ||
                            _type == _TrackingType.avoidance ||
                            _type == _TrackingType.duration)
                          _field(
                            _type == _TrackingType.avoidance
                                ? 'Maximum incidents'
                                : _type == _TrackingType.duration
                                ? 'Target seconds'
                                : 'Target',
                            _target,
                            number: true,
                            validator: (v) => _integer(
                              v,
                              min: _type == _TrackingType.avoidance ? 0 : 1,
                            ),
                          ),
                        if (_type == _TrackingType.checklist)
                          _field(
                            'Checklist items (one per line)',
                            _items,
                            lines: 4,
                            validator: _required,
                          ),
                        if (_type == _TrackingType.measurement ||
                            _type == _TrackingType.range) ...[
                          _field(
                            'Decimal places',
                            _places,
                            number: true,
                            validator: (v) => _integer(v, max: 6),
                          ),
                          if (_type == _TrackingType.measurement)
                            _field(
                              'Target',
                              _target,
                              number: true,
                              validator: _scaledValidator,
                            ),
                          if (_type == _TrackingType.range) ...[
                            _field(
                              'Minimum',
                              _minimum,
                              number: true,
                              validator: _scaledValidator,
                            ),
                            _field(
                              'Maximum',
                              _maximum,
                              number: true,
                              validator: _scaledValidator,
                            ),
                            _field(
                              'Score tolerance (target units)',
                              _tolerance,
                              number: true,
                              validator: (v) {
                                final error = _scaledValidator(v);
                                if (error != null) return error;
                                return _scaled(v!, int.parse(_places.text))! > 0
                                    ? null
                                    : 'Enter a positive tolerance';
                              },
                            ),
                          ],
                        ],
                        if (_type == _TrackingType.counter ||
                            _type == _TrackingType.measurement ||
                            _type == _TrackingType.range)
                          _suggestedField(
                            label: 'Unit',
                            explanation: 'What are you counting or measuring? Choose one or type your own.',
                            controller: _unit,
                            suggestions: const ['times', 'reps', 'minutes', 'pages'],
                            validator: (v) => _required(v) == null
                                ? null
                                : 'Enter a valid value',
                          ),
                        if (_type == _TrackingType.measurement)
                          DropdownButtonFormField<MeasurementComparisonRule>(
                            isExpanded: true,
                            initialValue: _measurementRule,
                            decoration: const InputDecoration(
                              labelText: 'Comparison',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: MeasurementComparisonRule.atLeast,
                                child: Text('At least'),
                              ),
                              DropdownMenuItem(
                                value: MeasurementComparisonRule.atMost,
                                child: Text('At most'),
                              ),
                              DropdownMenuItem(
                                value: MeasurementComparisonRule.exact,
                                child: Text('Exact'),
                              ),
                            ],
                            onChanged: _submitting
                                ? null
                                : (v) => setState(() => _measurementRule = v!),
                          ),
                        if (_type == _TrackingType.timeOfDay) ...[
                          _field(
                            'Target time (HH:MM)',
                            _time,
                            validator: (v) => _minutes(v ?? '') == null
                                ? 'Enter a valid value'
                                : null,
                          ),
                          DropdownButtonFormField<TimeComparisonRule>(
                            isExpanded: true,
                            initialValue: _timeRule,
                            decoration: const InputDecoration(
                              labelText: 'Comparison',
                            ),
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
                            onChanged: _submitting
                                ? null
                                : (v) => setState(() => _timeRule = v!),
                          ),
                          if (_timeRule == TimeComparisonRule.atOrNear)
                            const Text(
                              'At or near completes only at the exact target minute.',
                            ),
                          _field(
                            'Score tolerance (minutes)',
                            _tolerance,
                            number: true,
                            validator: (v) => _integer(v, min: 1),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 16),
                    _section(
                      icon: Icons.event_repeat_outlined,
                      title: 'Make a plan',
                      description:
                          'Choose when this habit fits into your life.',
                      children: [
                        DropdownButtonFormField<_ScheduleType>(
                          isExpanded: true,
                          initialValue: _schedule,
                          decoration: const InputDecoration(
                            labelText: 'Schedule',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: _ScheduleType.daily,
                              child: Text('Daily'),
                            ),
                            DropdownMenuItem(
                              value: _ScheduleType.weekdays,
                              child: Text('Weekdays'),
                            ),
                            DropdownMenuItem(
                              value: _ScheduleType.interval,
                              child: Text('Interval'),
                            ),
                            DropdownMenuItem(
                              value: _ScheduleType.monthly,
                              child: Text('Monthly'),
                            ),
                            DropdownMenuItem(
                              value: _ScheduleType.oneTime,
                              child: Text('One-time'),
                            ),
                          ],
                          onChanged: _submitting
                              ? null
                              : (v) => setState(() => _schedule = v!),
                        ),
                        if (_schedule == _ScheduleType.weekdays)
                          Wrap(
                            children: [
                              for (var i = 1; i <= 7; i++)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: FilterChip(
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
                                    onSelected: _submitting
                                        ? null
                                        : (selected) => setState(() {
                                            if (selected) {
                                              _weekdays.add(i);
                                            } else {
                                              _weekdays.remove(i);
                                            }
                                          }),
                                  ),
                                ),
                            ],
                          ),
                        if (_schedule == _ScheduleType.interval)
                          _field(
                            'Every days',
                            _interval,
                            number: true,
                            validator: (v) => _integer(v, min: 1),
                          ),
                        if (_schedule == _ScheduleType.monthly) ...[
                          _field(
                            'Day of month',
                            _monthDay,
                            number: true,
                            validator: (v) => _integer(v, min: 1, max: 31),
                          ),
                          _switchOption(
                            label: 'Use last day when date is missing',
                            value: _fallback,
                            onChanged: _submitting
                                ? null
                                : (v) => setState(() => _fallback = v),
                          ),
                        ],
                        ListTile(
                          title: const Text('Start date'),
                          subtitle: Text(
                            '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
                          ),
                          trailing: const Icon(Icons.calendar_today),
                          onTap: _submitting
                              ? null
                              : () async {
                                  final today = _today;
                                  final selected = await showDatePicker(
                                    context: context,
                                    initialDate: date.isBefore(today)
                                        ? today
                                        : date,
                                    firstDate: today,
                                    lastDate: DateTime(9999, 12, 30),
                                  );
                                  if (selected != null && mounted) {
                                    setState(() => _start = selected);
                                  }
                                },
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _section(
                      icon: Icons.tune_outlined,
                      title: 'Your preferences',
                      description:
                          'Adjust privacy, recovery and progress settings.',
                      children: [
                        DropdownButtonFormField<HabitPriority>(
                          isExpanded: true,
                          initialValue: _priority,
                          decoration: const InputDecoration(
                            labelText: 'Priority',
                          ),
                          items: HabitPriority.values
                              .map(
                                (v) => DropdownMenuItem(
                                  value: v,
                                  child: Text(
                                    v.name[0].toUpperCase() +
                                        v.name.substring(1),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: _submitting
                              ? null
                              : (v) => setState(() => _priority = v!),
                        ),
                        _field(
                          'Display order',
                          _order,
                          number: true,
                          validator: (v) => _integer(v),
                        ),
                        _switchOption(
                          label: 'Private',
                          value: _private,
                          onChanged: _submitting
                              ? null
                              : (v) => setState(() => _private = v),
                        ),
                        const Text(
                          'Private habits stay hidden until you show them. App Lock is available in More. The local database is not encrypted.',
                        ),
                        if (_type != _TrackingType.avoidance)
                          _switchOption(
                            label: 'Enable recovery',
                            value: _recovery,
                            onChanged: _submitting
                                ? null
                                : (v) => setState(() => _recovery = v),
                          ),
                        _switchOption(
                          label: 'Include in score',
                          value: _score,
                          onChanged: _submitting
                              ? null
                              : (v) => setState(() => _score = v),
                        ),
                        _switchOption(
                          label: 'Include in streak',
                          value: _streak,
                          onChanged: _submitting
                              ? null
                              : (v) => setState(() => _streak = v),
                        ),
                        _switchOption(
                          label: 'Include in rewards',
                          value: _rewards,
                          onChanged: _submitting
                              ? null
                              : (v) => setState(() => _rewards = v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _submitting ? null : _submit,
                      child: const Text('Create habit'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
