import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/habit_schedule.dart';
import 'unified_habit_registry.dart';

class NumericTodayData {
  const NumericTodayData({
    required this.target,
    required this.places,
    required this.status,
    required this.canLog,
  });
  final String target;
  final int places;
  final String status;
  final bool canLog;
}

class NumericTodayReader {
  const NumericTodayReader(this.db);
  final AppDatabase db;

  Future<NumericTodayData?> read(
    UnifiedHabitSummary habit,
    LocalDate date,
  ) => db.transaction(() async {
    final version = habit.versionId;
    if (version == null) return null;
    final type = switch (habit.trackingType) {
      HabitTrackingType.measurement => 'measurement',
      HabitTrackingType.timeOfDay => 'time_of_day',
      HabitTrackingType.range => 'range',
      _ => '',
    };
    final target = await db
        .customSelect(
          'SELECT * FROM habit_typed_targets WHERE habit_version_id = ? AND tracking_type = ?',
          variables: [Variable<String>(version), Variable<String>(type)],
        )
        .getSingleOrNull();
    if (target == null) return null;
    final int places;
    final String description;
    if (type == 'time_of_day') {
      places = 0;
      final minutes = target.read<int>('target_minutes_since_midnight');
      final rule = target.read<String>('comparison_rule');
      if (minutes < 0 ||
          minutes > 1439 ||
          !['at_or_before', 'at_or_after'].contains(rule)) {
        return null;
      }
      description =
          '${rule == 'at_or_before' ? 'At or before' : 'At or after'} ${_time(minutes)}';
    } else {
      places = target.read<int>('decimal_places');
      if (places < 0 || places > 6) return null;
      final unit = target.read<String>('unit');
      if (unit.trim().isEmpty) return null;
      if (type == 'measurement') {
        final rule = target.read<String>('comparison_rule');
        final label = switch (rule) {
          'at_least' => 'At least',
          'at_most' => 'At most',
          'exact' => 'Exactly',
          _ => null,
        };
        if (label == null) return null;
        description =
            '$label ${_decimal(target.read<int>('scaled_target'), places)} $unit';
      } else if (type == 'range') {
        final min = target.read<int>('min_scaled');
        final max = target.read<int>('max_scaled');
        if (min > max) return null;
        description = '${_decimal(min, places)}–${_decimal(max, places)} $unit';
      } else {
        return null;
      }
    }
    final key =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final rows = await db
        .customSelect(
          '''SELECT o.habit_version_id, o.tracking_type, l.state, l.scaled_value, l.minutes_since_midnight FROM habit_typed_occurrences o LEFT JOIN habit_typed_logs l ON l.occurrence_id = o.id WHERE o.habit_id = ? AND o.local_date = ?''',
          variables: [Variable<String>(habit.habitId), Variable<String>(key)],
        )
        .get();
    if (rows.isEmpty) {
      return NumericTodayData(
        target: description,
        places: places,
        status: 'Pending',
        canLog: true,
      );
    }
    if (rows.length != 1 ||
        rows.single.read<String>('habit_version_id') != version ||
        rows.single.read<String>('tracking_type') != type) {
      return NumericTodayData(
        target: description,
        places: places,
        status: 'Conflict',
        canLog: false,
      );
    }
    final row = rows.single;
    final state = row.readNullable<String>('state');
    if (state == null) {
      return NumericTodayData(
        target: description,
        places: places,
        status: 'Unknown',
        canLog: false,
      );
    }
    final value = type == 'time_of_day'
        ? row.readNullable<int>('minutes_since_midnight')
        : row.readNullable<int>('scaled_value');
    if (!['completed', 'partial', 'failed', 'excused'].contains(state) ||
        (value == null && state != 'excused')) {
      return NumericTodayData(
        target: description,
        places: places,
        status: 'Unknown',
        canLog: false,
      );
    }
    final label = '${state[0].toUpperCase()}${state.substring(1)}';
    final suffix = value == null
        ? ''
        : ' · ${type == 'time_of_day' ? _time(value) : '${_decimal(value, places)} ${target.read<String>('unit')}'}';
    return NumericTodayData(
      target: description,
      places: places,
      status: '$label$suffix',
      canLog: false,
    );
  });
}

String _time(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
String _decimal(int value, int places) {
  final digits = BigInt.from(value).abs().toString().padLeft(places + 1, '0');
  final sign = value < 0 ? '-' : '';
  return places == 0
      ? '$sign$digits'
      : '$sign${digits.substring(0, digits.length - places)}.${digits.substring(digits.length - places)}';
}
