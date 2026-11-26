import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/habit_schedule.dart';

final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Low-level storage; callers must enforce audit and historical correction rules.
class HabitScheduleStore {
  const HabitScheduleStore(this._database);

  final AppDatabase _database;

  Future<void> insert(String versionId, HabitSchedule schedule) {
    final (recurrence, mask) = switch (schedule) {
      DailySchedule() => ('daily', null),
      WeekdaySchedule(:final weekdays) => (
        'weekdays',
        weekdays.fold<int>(0, (mask, day) => mask | (1 << (day - 1))),
      ),
    };
    return _database.customStatement(
      '''
      INSERT INTO habit_schedules
        (habit_version_id, recurrence, start_date, end_exclusive, weekday_mask)
      VALUES (?, ?, ?, ?, ?)
    ''',
      [
        versionId,
        recurrence,
        _formatDate(schedule.start),
        schedule.endExclusive == null
            ? null
            : _formatDate(schedule.endExclusive!),
        mask,
      ],
    );
  }

  Future<HabitSchedule?> findForVersion(String versionId) async {
    final row = await _database
        .customSelect(
          '''
      SELECT recurrence, start_date, end_exclusive, weekday_mask
      FROM habit_schedules WHERE habit_version_id = ?
    ''',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    final start = _parseDate(row.read<String>('start_date'));
    final rawEnd = row.readNullable<String>('end_exclusive');
    final end = rawEnd == null ? null : _parseDate(rawEnd);
    switch (row.read<String>('recurrence')) {
      case 'daily':
        if (row.readNullable<int>('weekday_mask') != null) {
          throw const FormatException('Daily schedule has weekday data');
        }
        return DailySchedule(start: start, endExclusive: end);
      case 'weekdays':
        final mask = row.readNullable<int>('weekday_mask');
        if (mask == null || mask < 1 || mask > 127) {
          throw const FormatException('Invalid weekday mask');
        }
        return WeekdaySchedule(
          start: start,
          endExclusive: end,
          weekdays: {
            for (var day = 1; day <= 7; day++)
              if ((mask & (1 << (day - 1))) != 0) day,
          },
        );
      default:
        throw const FormatException('Unknown recurrence');
    }
  }
}

String _formatDate(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

LocalDate _parseDate(String value) {
  if (!_datePattern.hasMatch(value)) {
    throw const FormatException('Invalid calendar date');
  }
  return LocalDate(
    int.parse(value.substring(0, 4)),
    int.parse(value.substring(5, 7)),
    int.parse(value.substring(8, 10)),
  );
}
