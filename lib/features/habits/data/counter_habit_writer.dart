import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/counter_starter_template.dart';
import '../domain/counter_target.dart';
import '../domain/habit_schedule.dart';
import 'habit_lifecycle.dart';
import 'habit_schedule_store.dart';
import 'counter_target_store.dart';

/// Internal write path; historical corrections and user-facing editing are not supported.
class CounterHabitWriter {
  CounterHabitWriter(this._database, this._clock);

  final AppDatabase _database;
  final AppClock _clock;

  /// Explicitly instantiates a counter habit from an optional default or
  /// user-edited starter template without seeding historical occurrences.
  Future<void> createFromStarterTemplate({
    required CounterStarterTemplate template,
    required String habitId,
    required String versionId,
    required String auditId,
    required String lifecycleEventId,
    required DateTime effectiveDate,
    HabitSchedule? schedule,
  }) {
    final startDate = LocalDate(
      effectiveDate.year,
      effectiveDate.month,
      effectiveDate.day,
    );
    return create(
      habitId: habitId,
      versionId: versionId,
      auditId: auditId,
      lifecycleEventId: lifecycleEventId,
      name: template.name,
      effectiveDate: effectiveDate,
      target: template.target,
      schedule: schedule ?? template.defaultSchedule(startDate: startDate),
    );
  }

  Future<void> create({
    required String habitId,
    required String versionId,
    required String auditId,
    required String lifecycleEventId,
    required String name,
    required DateTime effectiveDate,
    required CounterTarget target,
    required HabitSchedule schedule,
  }) => _database.transaction(() async {
    final now = _clock.now();
    final start = _dateKey(effectiveDate);
    if (start.compareTo(_dateKey(now.toLocal())) < 0) {
      throw StateError(
        'Backdated habit creation requires a correction workflow',
      );
    }
    final firstDate = LocalDate(
      effectiveDate.year,
      effectiveDate.month,
      effectiveDate.day,
    );
    if (schedule.endExclusive != null &&
        schedule.endExclusive!.compareTo(firstDate) <= 0) {
      throw ArgumentError('Schedule ends before the habit can start');
    }
    final timestamp = now.toUtc().microsecondsSinceEpoch;
    await _database.customStatement(
      'INSERT INTO habits (id, created_at_utc_us) VALUES (?, ?)',
      [habitId, timestamp],
    );
    await _insertVersion(habitId, versionId, name, start, 1, timestamp, target);
    await HabitScheduleStore(_database).insert(versionId, schedule);
    await HabitLifecycleStore(_database, _CapturedClock(now)).append(
      id: lifecycleEventId,
      habitId: habitId,
      effectiveDate: firstDate,
      state: HabitLifecycleState.active,
    );
    await _writeAudit(auditId, habitId, 'create', null, {
      'version_id': versionId,
      'name': name,
      'effective_start': start,
      'effective_end': null,
      'revision': 1,
      'target_count': target.count,
      'unit': target.unit,
      'schedule': _scheduleValues(schedule),
      'lifecycle': {
        'event_id': lifecycleEventId,
        'state': 'active',
        'effective_date': start,
      },
    }, timestamp);
  });

  Future<void> scheduleVersion({
    required String habitId,
    required String versionId,
    required String auditId,
    required String name,
    required DateTime effectiveDate,
    required CounterTarget target,
    required HabitSchedule schedule,
  }) => _database.transaction(() async {
    final now = _clock.now();
    final start = _dateKey(effectiveDate);
    if (start.compareTo(_dateKey(now.toLocal())) <= 0) {
      throw StateError(
        'Current or backdated changes require a correction workflow',
      );
    }
    final versionStart = LocalDate(
      effectiveDate.year,
      effectiveDate.month,
      effectiveDate.day,
    );
    if (schedule.endExclusive != null &&
        schedule.endExclusive!.compareTo(versionStart) <= 0) {
      throw ArgumentError('Schedule ends before the version can start');
    }
    final row = await _database
        .customSelect(
          '''
      SELECT v.id, v.name, v.effective_start, v.effective_end, v.revision,
             t.target_count, t.unit
      FROM habit_versions v
      LEFT JOIN habit_counter_targets t ON t.habit_version_id = v.id
      WHERE v.habit_id = ? ORDER BY v.effective_start DESC LIMIT 1
    ''',
          variables: [Variable<String>(habitId)],
        )
        .getSingleOrNull();
    if (row == null ||
        row.readNullable<String>('effective_end') != null ||
        row.readNullable<int>('target_count') == null ||
        row.readNullable<String>('unit') == null) {
      throw StateError('Habit must have an open counter version');
    }
    final oldStart = row.read<String>('effective_start');
    if (start.compareTo(oldStart) <= 0) {
      throw StateError('New version must start after the latest version');
    }
    final oldId = row.read<String>('id');
    final revision = row.read<int>('revision');
    final scheduleStore = HabitScheduleStore(_database);
    final previousSchedule = await scheduleStore.findForVersion(oldId);
    final oldValues = <String, Object?>{
      'version_id': oldId,
      'name': row.read<String>('name'),
      'effective_start': oldStart,
      'effective_end': null,
      'revision': revision,
      'target_count': row.read<int>('target_count'),
      'unit': row.read<String>('unit'),
      'schedule': previousSchedule == null
          ? null
          : _scheduleValues(previousSchedule),
    };
    final timestamp = now.toUtc().microsecondsSinceEpoch;
    await _database.customStatement(
      'UPDATE habit_versions SET effective_end = ? WHERE id = ?',
      [start, oldId],
    );
    await _insertVersion(
      habitId,
      versionId,
      name,
      start,
      revision + 1,
      timestamp,
      target,
    );
    await scheduleStore.insert(versionId, schedule);
    await _writeAudit(auditId, habitId, 'schedule_version', oldValues, {
      'closed_version': {...oldValues, 'effective_end': start},
      'new_version': {
        'version_id': versionId,
        'name': name,
        'effective_start': start,
        'effective_end': null,
        'revision': revision + 1,
        'target_count': target.count,
        'unit': target.unit,
        'schedule': _scheduleValues(schedule),
      },
    }, timestamp);
  });

  Future<void> _insertVersion(
    String habitId,
    String versionId,
    String name,
    String start,
    int revision,
    int timestamp,
    CounterTarget target,
  ) async {
    await _database.customStatement(
      '''
      INSERT INTO habit_versions (id, habit_id, name, effective_start, effective_end, created_at_utc_us, revision)
      VALUES (?, ?, ?, ?, NULL, ?, ?)
    ''',
      [versionId, habitId, name, start, timestamp, revision],
    );
    await CounterTargetStore(_database).insert(versionId, target);
  }

  Future<void> _writeAudit(
    String auditId,
    String habitId,
    String operation,
    Map<String, Object?>? previous,
    Map<String, Object?> updated,
    int timestamp,
  ) => _database.customStatement(
    '''
        INSERT INTO habit_version_audit (id, habit_id, operation, previous_values, updated_values, occurred_at_utc_us)
        VALUES (?, ?, ?, ?, ?, ?)
      ''',
    [
      auditId,
      habitId,
      operation,
      previous == null ? null : jsonEncode(previous),
      jsonEncode(updated),
      timestamp,
    ],
  );
}

String _dateKey(DateTime date) {
  if (date.year < 1 || date.year > 9999) {
    throw RangeError.range(date.year, 1, 9999, 'year');
  }
  return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

String _localDateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

Map<String, Object?> _scheduleValues(HabitSchedule schedule) => {
  'recurrence': switch (schedule) {
    DailySchedule() => 'daily',
    WeekdaySchedule() => 'weekdays',
  },
  'start_date': _localDateKey(schedule.start),
  'end_exclusive': schedule.endExclusive == null
      ? null
      : _localDateKey(schedule.endExclusive!),
  'weekdays': switch (schedule) {
    DailySchedule() => null,
    WeekdaySchedule(:final weekdays) => weekdays.toList()..sort(),
  },
};

class _CapturedClock implements AppClock {
  const _CapturedClock(this.instant);
  final DateTime instant;

  @override
  DateTime now() => instant;
}
