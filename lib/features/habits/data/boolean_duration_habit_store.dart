import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/boolean_duration_habit.dart';
import '../domain/habit_metadata.dart';
import '../domain/habit_schedule.dart';
import 'habit_creation_audit.dart';
import 'habit_lifecycle.dart';
import 'habit_metadata_store.dart';
import 'habit_schedule_store.dart';

/// Transactional creation, logging and read-only evaluation for Boolean and
/// Duration (manual and timer) habits.
class BooleanDurationHabitService {
  const BooleanDurationHabitService(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<void> createBoolean({
    required String habitId,
    required String versionId,
    required String lifecycleEventId,
    required String name,
    required DateTime effectiveDate,
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
      INSERT INTO habit_typed_targets (habit_version_id, tracking_type)
      VALUES (?, 'boolean')
      ''',
      [versionId],
    );
    await writeNonCounterCreationAudit(
      _db,
      habitId: habitId,
      versionId: versionId,
      lifecycleEventId: lifecycleEventId,
      trackingType: 'boolean',
    );
  });

  Future<void> createDuration({
    required String habitId,
    required String versionId,
    required String lifecycleEventId,
    required String name,
    required DateTime effectiveDate,
    required DurationTarget target,
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
        (habit_version_id, tracking_type, target_seconds)
      VALUES (?, 'duration', ?)
      ''',
      [versionId, target.targetSeconds],
    );
    await writeNonCounterCreationAudit(
      _db,
      habitId: habitId,
      versionId: versionId,
      lifecycleEventId: lifecycleEventId,
      trackingType: 'duration',
    );
  });

  Future<BooleanLogState> logBooleanToday({
    required String habitId,
    required String occurrenceId,
    required String logId,
    required BooleanLogState state,
    String? reason,
  }) => _db.transaction(() async {
    final now = _clock.now();
    final today = _localDate(now);
    final actualOccId = await _getOrCreateTypedOccurrence(
      habitId: habitId,
      expectedType: 'boolean',
      today: today,
      candidateOccurrenceId: occurrenceId,
    );
    await _db.customStatement(
      '''
      INSERT INTO habit_typed_logs
        (id, occurrence_id, state, reason, occurred_at_utc_us)
      VALUES (?, ?, ?, ?, ?)
      ''',
      [
        logId,
        actualOccId,
        state.name,
        reason,
        now.toUtc().microsecondsSinceEpoch,
      ],
    );
    return state;
  });

  Future<DurationDayProgress> recordDurationEntryToday({
    required String habitId,
    required String occurrenceId,
    required String eventId,
    required DurationEntryInput entry,
  }) => _db.transaction(() async {
    final now = _clock.now();
    final today = _localDate(now);
    final actualOccId = await _getOrCreateTypedOccurrence(
      habitId: habitId,
      expectedType: 'duration',
      today: today,
      candidateOccurrenceId: occurrenceId,
    );
    final existingResolution = await _db
        .customSelect(
          'SELECT id FROM habit_typed_logs WHERE occurrence_id = ?',
          variables: [Variable<String>(actualOccId)],
        )
        .getSingleOrNull();
    if (existingResolution != null) {
      throw StateError('Resolved duration occurrence requires correction');
    }
    await _db.customStatement(
      '''
      INSERT INTO habit_duration_events
        (id, occurrence_id, duration_seconds, source, started_at_utc_us,
         ended_at_utc_us, occurred_at_utc_us)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        eventId,
        actualOccId,
        entry.durationSeconds,
        entry.source.name,
        entry.startedAtUtc?.microsecondsSinceEpoch,
        entry.endedAtUtc?.microsecondsSinceEpoch,
        now.toUtc().microsecondsSinceEpoch,
      ],
    );
    return (await readDurationDay(habitId: habitId, date: today))!;
  });

  Future<BooleanLogState?> readBooleanDay({
    required String habitId,
    required LocalDate date,
  }) => _db.transaction(() async {
    final row = await _db
        .customSelect(
          '''
      SELECT l.state
      FROM habit_typed_occurrences o
      JOIN habit_typed_logs l ON l.occurrence_id = o.id
      WHERE o.habit_id = ? AND o.local_date = ? AND o.tracking_type = 'boolean'
      ''',
          variables: [
            Variable<String>(habitId),
            Variable<String>(_dateKey(date)),
          ],
        )
        .getSingleOrNull();
    if (row == null) return null;
    return BooleanLogState.values.byName(row.read<String>('state'));
  });

  Future<DurationDayProgress?> readDurationDay({
    required String habitId,
    required LocalDate date,
  }) => _db.transaction(() async {
    final occRow = await _db
        .customSelect(
          '''
      SELECT o.id, t.target_seconds
      FROM habit_typed_occurrences o
      JOIN habit_typed_targets t ON t.habit_version_id = o.habit_version_id
      WHERE o.habit_id = ? AND o.local_date = ? AND o.tracking_type = 'duration'
      ''',
          variables: [
            Variable<String>(habitId),
            Variable<String>(_dateKey(date)),
          ],
        )
        .getSingleOrNull();
    if (occRow == null) return null;
    final occId = occRow.read<String>('id');
    final targetSeconds = occRow.read<int>('target_seconds');
    final eventRows = await _db
        .customSelect(
          'SELECT duration_seconds FROM habit_duration_events WHERE occurrence_id = ?',
          variables: [Variable<String>(occId)],
        )
        .get();
    final resRow = await _db
        .customSelect(
          'SELECT state FROM habit_typed_logs WHERE occurrence_id = ?',
          variables: [Variable<String>(occId)],
        )
        .getSingleOrNull();
    final resState = resRow == null
        ? null
        : BooleanLogState.values.byName(resRow.read<String>('state'));
    return DurationDayProgress.evaluate(
      targetSeconds: targetSeconds,
      entrySeconds: [
        for (final row in eventRows) row.read<int>('duration_seconds'),
      ],
      explicitResolution: resState,
    );
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

  Future<String> _getOrCreateTypedOccurrence({
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
    final existing = await _db
        .customSelect(
          'SELECT id, tracking_type FROM habit_typed_occurrences WHERE habit_id = ? AND local_date = ?',
          variables: [Variable<String>(habitId), Variable<String>(todayKey)],
        )
        .getSingleOrNull();
    if (existing != null) {
      if (existing.read<String>('tracking_type') != expectedType) {
        throw StateError('Occurrence tracking type mismatch');
      }
      return existing.read<String>('id');
    }
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
    return candidateOccurrenceId;
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
