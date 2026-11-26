import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/habit_metadata.dart';
import '../domain/habit_schedule.dart';
import '../domain/measurement_time_range_habit.dart';
import 'habit_creation_audit.dart';
import 'habit_lifecycle.dart';
import 'habit_metadata_store.dart';
import 'habit_schedule_store.dart';

/// Transactional creation, logging and read-only evaluation for Measurement,
/// Time-of-Day and Range-based habits.
class MeasurementTimeRangeHabitService {
  const MeasurementTimeRangeHabitService(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<void> createMeasurement({
    required String habitId,
    required String versionId,
    required String lifecycleEventId,
    required String name,
    required DateTime effectiveDate,
    required MeasurementTarget target,
    required HabitSchedule schedule,
    HabitMetadata? metadata,
  }) => _db.transaction(() async {
    await _createBaseVersion(
      habitId: habitId,
      versionId: versionId,
      lifecycleEventId: lifecycleEventId,
      name: name,
      effectiveDate: effectiveDate,
      schedule: schedule,
      metadata: metadata,
    );
    final ruleStr = switch (target.rule) {
      MeasurementComparisonRule.atLeast => 'at_least',
      MeasurementComparisonRule.atMost => 'at_most',
      MeasurementComparisonRule.exact => 'exact',
    };
    await _db.customStatement(
      '''
      INSERT INTO habit_typed_targets
        (habit_version_id, tracking_type, scaled_target, decimal_places, unit, comparison_rule)
      VALUES (?, 'measurement', ?, ?, ?, ?)
      ''',
      [
        versionId,
        target.scaledTarget,
        target.decimalPlaces,
        target.unit,
        ruleStr,
      ],
    );
    await writeNonCounterCreationAudit(
      _db,
      habitId: habitId,
      versionId: versionId,
      lifecycleEventId: lifecycleEventId,
      trackingType: 'measurement',
    );
  });

  Future<void> createTimeOfDay({
    required String habitId,
    required String versionId,
    required String lifecycleEventId,
    required String name,
    required DateTime effectiveDate,
    required TimeOfDayTarget target,
    required HabitSchedule schedule,
    HabitMetadata? metadata,
  }) => _db.transaction(() async {
    await _createBaseVersion(
      habitId: habitId,
      versionId: versionId,
      lifecycleEventId: lifecycleEventId,
      name: name,
      effectiveDate: effectiveDate,
      schedule: schedule,
      metadata: metadata,
    );
    final ruleStr = switch (target.rule) {
      TimeComparisonRule.atOrBefore => 'at_or_before',
      TimeComparisonRule.atOrAfter => 'at_or_after',
    };
    await _db.customStatement(
      '''
      INSERT INTO habit_typed_targets
        (habit_version_id, tracking_type, target_minutes_since_midnight, comparison_rule)
      VALUES (?, 'time_of_day', ?, ?)
      ''',
      [versionId, target.targetMinutesSinceMidnight, ruleStr],
    );
    await writeNonCounterCreationAudit(
      _db,
      habitId: habitId,
      versionId: versionId,
      lifecycleEventId: lifecycleEventId,
      trackingType: 'time_of_day',
    );
  });

  Future<void> createRange({
    required String habitId,
    required String versionId,
    required String lifecycleEventId,
    required String name,
    required DateTime effectiveDate,
    required RangeTarget target,
    required HabitSchedule schedule,
    HabitMetadata? metadata,
  }) => _db.transaction(() async {
    await _createBaseVersion(
      habitId: habitId,
      versionId: versionId,
      lifecycleEventId: lifecycleEventId,
      name: name,
      effectiveDate: effectiveDate,
      schedule: schedule,
      metadata: metadata,
    );
    await _db.customStatement(
      '''
      INSERT INTO habit_typed_targets
        (habit_version_id, tracking_type, min_scaled, max_scaled, decimal_places, unit)
      VALUES (?, 'range', ?, ?, ?, ?)
      ''',
      [
        versionId,
        target.minScaled,
        target.maxScaled,
        target.decimalPlaces,
        target.unit,
      ],
    );
    await writeNonCounterCreationAudit(
      _db,
      habitId: habitId,
      versionId: versionId,
      lifecycleEventId: lifecycleEventId,
      trackingType: 'range',
    );
  });

  Future<TypedValueStatus> logMeasurementToday({
    required String habitId,
    required String occurrenceId,
    required String logId,
    required int scaledValue,
    String? reason,
  }) => _db.transaction(() async {
    final now = _clock.now();
    final today = _localDate(now);
    final (occId, versionId) = await _createTodayOccurrence(
      habitId: habitId,
      expectedType: 'measurement',
      today: today,
      candidateOccurrenceId: occurrenceId,
    );
    final targetRow = await _db
        .customSelect(
          'SELECT scaled_target, decimal_places, unit, comparison_rule FROM habit_typed_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingle();
    final target = MeasurementTarget(
      scaledTarget: targetRow.read<int>('scaled_target'),
      decimalPlaces: targetRow.read<int>('decimal_places'),
      unit: targetRow.read<String>('unit'),
      rule: switch (targetRow.read<String>('comparison_rule')) {
        'at_least' => MeasurementComparisonRule.atLeast,
        'at_most' => MeasurementComparisonRule.atMost,
        _ => MeasurementComparisonRule.exact,
      },
    );
    final status = target.evaluate(scaledValue);
    await _db.customStatement(
      '''
      INSERT INTO habit_typed_logs
        (id, occurrence_id, state, scaled_value, reason, occurred_at_utc_us)
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [
        logId,
        occId,
        status.name,
        scaledValue,
        reason,
        now.toUtc().microsecondsSinceEpoch,
      ],
    );
    return status;
  });

  Future<TypedValueStatus> logTimeOfDayToday({
    required String habitId,
    required String occurrenceId,
    required String logId,
    required int minutesSinceMidnight,
    String? reason,
  }) => _db.transaction(() async {
    final now = _clock.now();
    final today = _localDate(now);
    final (occId, versionId) = await _createTodayOccurrence(
      habitId: habitId,
      expectedType: 'time_of_day',
      today: today,
      candidateOccurrenceId: occurrenceId,
    );
    final targetRow = await _db
        .customSelect(
          'SELECT target_minutes_since_midnight, comparison_rule FROM habit_typed_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingle();
    final target = TimeOfDayTarget(
      targetMinutesSinceMidnight: targetRow.read<int>(
        'target_minutes_since_midnight',
      ),
      rule: targetRow.read<String>('comparison_rule') == 'at_or_before'
          ? TimeComparisonRule.atOrBefore
          : TimeComparisonRule.atOrAfter,
    );
    final status = target.evaluate(minutesSinceMidnight);
    await _db.customStatement(
      '''
      INSERT INTO habit_typed_logs
        (id, occurrence_id, state, minutes_since_midnight, reason, occurred_at_utc_us)
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [
        logId,
        occId,
        status.name,
        minutesSinceMidnight,
        reason,
        now.toUtc().microsecondsSinceEpoch,
      ],
    );
    return status;
  });

  Future<TypedValueStatus> logRangeToday({
    required String habitId,
    required String occurrenceId,
    required String logId,
    required int scaledValue,
    String? reason,
  }) => _db.transaction(() async {
    final now = _clock.now();
    final today = _localDate(now);
    final (occId, versionId) = await _createTodayOccurrence(
      habitId: habitId,
      expectedType: 'range',
      today: today,
      candidateOccurrenceId: occurrenceId,
    );
    final targetRow = await _db
        .customSelect(
          'SELECT min_scaled, max_scaled, decimal_places, unit FROM habit_typed_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingle();
    final target = RangeTarget(
      minScaled: targetRow.read<int>('min_scaled'),
      maxScaled: targetRow.read<int>('max_scaled'),
      decimalPlaces: targetRow.read<int>('decimal_places'),
      unit: targetRow.read<String>('unit'),
    );
    final status = target.evaluate(scaledValue);
    await _db.customStatement(
      '''
      INSERT INTO habit_typed_logs
        (id, occurrence_id, state, scaled_value, reason, occurred_at_utc_us)
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [
        logId,
        occId,
        status.name,
        scaledValue,
        reason,
        now.toUtc().microsecondsSinceEpoch,
      ],
    );
    return status;
  });

  Future<void> _createBaseVersion({
    required String habitId,
    required String versionId,
    required String lifecycleEventId,
    required String name,
    required DateTime effectiveDate,
    required HabitSchedule schedule,
    HabitMetadata? metadata,
  }) async {
    final now = _clock.now();
    final startDate = LocalDate(
      effectiveDate.year,
      effectiveDate.month,
      effectiveDate.day,
    );
    final startKey = _dateKey(startDate);
    if (startKey.compareTo(_dateKey(_localDate(now))) < 0) {
      throw StateError('Backdated habit creation requires correction');
    }
    final timestamp = now.toUtc().microsecondsSinceEpoch;
    await _db.customStatement(
      'INSERT INTO habits (id, created_at_utc_us) VALUES (?, ?)',
      [habitId, timestamp],
    );
    await _db.customStatement(
      '''
      INSERT INTO habit_versions
        (id, habit_id, name, effective_start, effective_end, created_at_utc_us, revision)
      VALUES (?, ?, ?, ?, NULL, ?, 1)
      ''',
      [versionId, habitId, name.trim(), startKey, timestamp],
    );
    if (metadata != null) {
      await HabitMetadataStore(_db).insert(versionId, metadata);
    }
    await HabitScheduleStore(_db).insert(versionId, schedule);
    await HabitLifecycleStore(_db, _CapturedClock(now)).append(
      id: lifecycleEventId,
      habitId: habitId,
      effectiveDate: startDate,
      state: HabitLifecycleState.active,
    );
  }

  Future<(String, String)> _createTodayOccurrence({
    required String habitId,
    required String expectedType,
    required LocalDate today,
    required String candidateOccurrenceId,
  }) async {
    final detail = await HabitApplicabilityReader(_db).describe(habitId, today);
    if (detail.applicability != HabitApplicability.applicable ||
        detail.versionId == null) {
      throw StateError('Habit is not applicable today');
    }
    final todayKey = _dateKey(today);
    final targetRow = await _db
        .customSelect(
          'SELECT tracking_type FROM habit_typed_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(detail.versionId!)],
        )
        .getSingleOrNull();
    if (targetRow == null ||
        targetRow.read<String>('tracking_type') != expectedType) {
      throw StateError('Version is not configured for $expectedType tracking');
    }
    await _db.customStatement(
      '''
      INSERT INTO habit_typed_occurrences
        (id, habit_id, habit_version_id, tracking_type, local_date)
      VALUES (?, ?, ?, ?, ?)
      ''',
      [
        candidateOccurrenceId,
        habitId,
        detail.versionId!,
        expectedType,
        todayKey,
      ],
    );
    return (candidateOccurrenceId, detail.versionId!);
  }
}

LocalDate _localDate(DateTime instant) {
  final local = instant.toLocal();
  return LocalDate(local.year, local.month, local.day);
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

class _CapturedClock implements AppClock {
  const _CapturedClock(this.instant);
  final DateTime instant;

  @override
  DateTime now() => instant;
}
