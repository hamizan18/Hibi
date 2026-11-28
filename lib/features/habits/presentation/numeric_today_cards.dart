import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../application/counter_habit_providers.dart';
import '../data/numeric_today_reader.dart';
import '../data/unified_habit_registry.dart';
import '../domain/habit_schedule.dart';

class NumericTodayCard extends ConsumerStatefulWidget {
  const NumericTodayCard({
    super.key,
    required this.habit,
    required this.date,
    required this.onChanged,
  });
  final UnifiedHabitSummary habit;
  final LocalDate date;
  final VoidCallback onChanged;

  @override
  ConsumerState<NumericTodayCard> createState() => _NumericTodayCardState();
}

class _NumericTodayCardState extends ConsumerState<NumericTodayCard> {
  final _controller = TextEditingController();
  int _dayOffset = 0;
  late Future<NumericTodayData?> _data;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _data = NumericTodayReader(ref.read(databaseProvider))
        .read(widget.habit, widget.date);
  }

  @override
  void didUpdateWidget(covariant NumericTodayCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.habit.habitId != widget.habit.habitId ||
        oldWidget.habit.versionId != widget.habit.versionId ||
        oldWidget.habit.trackingType != widget.habit.trackingType ||
        oldWidget.date.compareTo(widget.date) != 0) {
      _controller.clear();
      _dayOffset = 0;
      _error = null;
      _load();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _isToday() {
    final now = ref.read(appClockProvider).now().toLocal();
    return widget.date.compareTo(LocalDate(now.year, now.month, now.day)) == 0;
  }

  Future<void> _submit(NumericTodayData data) async {
    if (_submitting || !data.canLog) return;
    if (!_isToday()) {
      setState(() => _error = 'Logging is only available for today.');
      return;
    }
    final isTime = widget.habit.trackingType == HabitTrackingType.timeOfDay;
    final value = isTime
        ? _parseTime(_controller.text)
        : _parseDecimal(_controller.text, data.places);
    if (value == null) {
      setState(
        () => _error = isTime
            ? 'Enter a valid time in HH:MM format.'
            : 'Enter a valid number with at most ${data.places} decimal places.',
      );
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final service = ref.read(measurementTimeRangeHabitServiceProvider);
      final occurrence = _id();
      final log = _id();
      switch (widget.habit.trackingType) {
        case HabitTrackingType.measurement:
          await service.logMeasurementToday(
            habitId: widget.habit.habitId,
            occurrenceId: occurrence,
            logId: log,
            scaledValue: value,
          );
        case HabitTrackingType.timeOfDay:
          await service.logTimeOfDayToday(
            habitId: widget.habit.habitId,
            occurrenceId: occurrence,
            logId: log,
            minutesSinceMidnight: value,
            dayOffset: _dayOffset,
          );
        case HabitTrackingType.range:
          await service.logRangeToday(
            habitId: widget.habit.habitId,
            occurrenceId: occurrence,
            logId: log,
            scaledValue: value,
          );
        default:
          throw StateError('Unsupported type');
      }
      if (!mounted) return;
      setState(() {
        _load();
        _submitting = false;
      });
      widget.onChanged();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Could not save the entry. Please try again.';
        _load();
      });
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<NumericTodayData?>(
    future: _data,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.hasError || snapshot.data == null) {
        return const Text('Unable to load this habit.');
      }
      final data = snapshot.data!;
      final isTime = widget.habit.trackingType == HabitTrackingType.timeOfDay;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Target: ${data.target}'),
          Text(data.status),
          if (data.canLog && _isToday()) ...[
            TextField(
              controller: _controller,
              enabled: !_submitting,
              keyboardType: isTime
                  ? TextInputType.datetime
                  : const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
              decoration: InputDecoration(
                labelText: isTime ? 'Time (HH:MM)' : 'Value',
                errorText: _error,
              ),
            ),
            if (isTime)
              DropdownButtonFormField<int>(
                initialValue: _dayOffset,
                decoration: const InputDecoration(
                  labelText: 'Which day was this time?',
                ),
                items: const [
                  DropdownMenuItem(value: -1, child: Text('Previous day')),
                  DropdownMenuItem(value: 0, child: Text('Same day')),
                  DropdownMenuItem(value: 1, child: Text('Next day')),
                ],
                onChanged: _submitting
                    ? null
                    : (value) => setState(() => _dayOffset = value!),
              ),
            ElevatedButton(
              onPressed: _submitting ? null : () => _submit(data),
              child: Text(_submitting ? 'Saving…' : 'Save for today'),
            ),
          ] else if (_error != null)
            Text(_error!),
        ],
      );
    },
  );
}

String _id() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

int? _parseTime(String text) {
  final match = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(text.trim());
  if (match == null) return null;
  final hours = int.parse(match[1]!);
  final minutes = int.parse(match[2]!);
  return hours < 24 && minutes < 60 ? hours * 60 + minutes : null;
}

int? _parseDecimal(String text, int places) {
  final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d+))?$').firstMatch(text.trim());
  if (match == null) return null;
  final fraction = match[3] ?? '';
  if (fraction.length > places) return null;
  final scaled = BigInt.parse(
    '${match[1]}${match[2]}${fraction.padRight(places, '0')}',
  );
  if (scaled < BigInt.from(-9223372036854775807) - BigInt.one ||
      scaled > BigInt.from(9223372036854775807)) {
    return null;
  }
  return scaled.toInt();
}
