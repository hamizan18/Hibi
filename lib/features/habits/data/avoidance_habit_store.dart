import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/avoidance_habit.dart';
import '../domain/habit_metadata.dart';
import '../domain/habit_schedule.dart';
import 'habit_creation_audit.dart';
import 'habit_lifecycle.dart';
import 'habit_metadata_store.dart';
import 'habit_schedule_store.dart';

typedef AvoidanceDayView = ({
  HabitApplicability applicability,
  String? occurrenceId,
  AvoidanceDayProgress? progress,
});

/// Transactional creation, repeated incident logging, daily confirmation and
/// read-only day evaluation for avoidance habits.
class AvoidanceHabitService {
  const AvoidanceHabitService(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<void> create({
    required String habitId,
    required String versionId,
    required String lifecycleEventId,
    required String name,
    required DateTime effectiveDate,
    required AvoidanceTarget target,
    required HabitSchedule schedule,
    HabitMetadata? metadata,
  }) => _db.transaction(() async {
    if (target.maxIncidents < 0) {
      throw RangeError.value(target.maxIncidents, 'maxIncidents');
    }
    if (metadata != null && metadata.recoveryEnabled) {
      throw ArgumentError('Avoidance habits cannot enable recovery');
    }
    final now = _clock.now();
    final startDate = LocalDate(
      effectiveDate.year,
      effectiveDate.month,
      effectiveDate.day,
    );
    final startKey = _dateKey(startDate);
    if (startKey.compareTo(_dateKey(_localDate(now))) < 0) {
      throw StateError('Backdated avoidance creation requires correction');
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
    await _db.customStatement(
      '''
      INSERT INTO habit_avoidance_targets (habit_version_id, max_incidents)
      VALUES (?, ?)
      ''',
      [versionId, target.maxIncidents],
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
    await writeNonCounterCreationAudit(
      _db,
      habitId: habitId,
      versionId: versionId,
      lifecycleEventId: lifecycleEventId,
      trackingType: 'avoidance',
    );
  });

  Future<void> createFromStarterTemplate({
    required AvoidanceStarterTemplate template,
    required String habitId,
    required String versionId,
    required String lifecycleEventId,
    required DateTime effectiveDate,
    HabitSchedule? schedule,
    HabitMetadata? metadata,
  }) {
    final startDate = LocalDate(
      effectiveDate.year,
      effectiveDate.month,
      effectiveDate.day,
    );
    return create(
      habitId: habitId,
      versionId: versionId,
      lifecycleEventId: lifecycleEventId,
      name: template.name,
      effectiveDate: effectiveDate,
      target: template.target,
      schedule: schedule ?? template.defaultSchedule(startDate: startDate),
      metadata: metadata ?? template.defaultMetadata(),
    );
  }

  Future<AvoidanceDayView> recordIncidentToday({
    required String habitId,
    required String occurrenceId,
    required String incidentId,
    String? note,
  }) => _db.transaction(() async {
    final now = _clock.now();
    final today = _localDate(now);
    final todayKey = _dateKey(today);
    final actualOccId = await _getOrCreateTodayOccurrence(
      habitId: habitId,
      today: today,
      todayKey: todayKey,
      candidateOccurrenceId: occurrenceId,
    );
    await _db.customStatement(
      '''
      INSERT INTO habit_avoidance_incidents
        (id, occurrence_id, note, occurred_at_utc_us)
      VALUES (?, ?, ?, ?)
      ''',
      [incidentId, actualOccId, note, now.toUtc().microsecondsSinceEpoch],
    );
    return readDay(habitId: habitId, date: today);
  });

  Future<AvoidanceDayView> resolveToday({
    required String habitId,
    required String occurrenceId,
    required String resolutionId,
    required AvoidanceResolutionState state,
    String? reason,
  }) => _db.transaction(() async {
    final now = _clock.now();
    final today = _localDate(now);
    final todayKey = _dateKey(today);
    final actualOccId = await _getOrCreateTodayOccurrence(
      habitId: habitId,
      today: today,
      todayKey: todayKey,
      candidateOccurrenceId: occurrenceId,
    );
    final occRow = await _db
        .customSelect(
          'SELECT max_incidents FROM habit_avoidance_occurrences WHERE id = ?',
          variables: [Variable<String>(actualOccId)],
        )
        .getSingle();
    final maxIncidents = occRow.read<int>('max_incidents');
    final incidentCount =
        (await _db
                .customSelect(
                  'SELECT COUNT(*) AS n FROM habit_avoidance_incidents WHERE occurrence_id = ?',
                  variables: [Variable<String>(actualOccId)],
                )
                .getSingle())
            .read<int>('n');
    if (state == AvoidanceResolutionState.confirmedCompleted &&
        incidentCount > maxIncidents) {
      throw StateError(
        'Cannot confirm avoidance completion when incidents ($incidentCount) exceed maximum ($maxIncidents)',
      );
    }
    final dbState = switch (state) {
      AvoidanceResolutionState.confirmedCompleted => 'confirmed_completed',
      AvoidanceResolutionState.failed => 'failed',
      AvoidanceResolutionState.excused => 'excused',
    };
    await _db.customStatement(
      '''
      INSERT INTO habit_avoidance_resolutions
        (id, occurrence_id, state, incident_count_snapshot, reason, occurred_at_utc_us)
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [
        resolutionId,
        actualOccId,
        dbState,
        incidentCount,
        reason,
        now.toUtc().microsecondsSinceEpoch,
      ],
    );
    return readDay(habitId: habitId, date: today);
  });

  Future<AvoidanceDayView> readDay({
    required String habitId,
    required LocalDate date,
  }) => _db.transaction(() async {
    final applicability = await HabitApplicabilityReader(_db)
        .evaluate(habitId, date);
    final key = _dateKey(date);
    final occRow = await _db
        .customSelect(
          'SELECT id, max_incidents FROM habit_avoidance_occurrences WHERE habit_id = ? AND local_date = ?',
          variables: [Variable<String>(habitId), Variable<String>(key)],
        )
        .getSingleOrNull();
    if (occRow == null) {
      return (applicability: applicability, occurrenceId: null, progress: null);
    }
    final occId = occRow.read<String>('id');
    final maxIncidents = occRow.read<int>('max_incidents');
    final incidentCount =
        (await _db
                .customSelect(
                  'SELECT COUNT(*) AS n FROM habit_avoidance_incidents WHERE occurrence_id = ?',
                  variables: [Variable<String>(occId)],
                )
                .getSingle())
            .read<int>('n');
    final resRow = await _db
        .customSelect(
          'SELECT state FROM habit_avoidance_resolutions WHERE occurrence_id = ?',
          variables: [Variable<String>(occId)],
        )
        .getSingleOrNull();
    final resolution = switch (resRow?.read<String>('state')) {
      null => null,
      'confirmed_completed' => AvoidanceResolutionState.confirmedCompleted,
      'failed' => AvoidanceResolutionState.failed,
      'excused' => AvoidanceResolutionState.excused,
      final other => throw FormatException('Unknown avoidance state: $other'),
    };
    return (
      applicability: applicability,
      occurrenceId: occId,
      progress: AvoidanceDayProgress.evaluate(
        maxIncidents: maxIncidents,
        incidentCount: incidentCount,
        resolution: resolution,
      ),
    );
  });

  Future<String> _getOrCreateTodayOccurrence({
    required String habitId,
    required LocalDate today,
    required String todayKey,
    required String candidateOccurrenceId,
  }) async {
    final detail = await HabitApplicabilityReader(_db).describe(habitId, today);
    if (detail.applicability != HabitApplicability.applicable ||
        detail.versionId == null) {
      throw StateError('Avoidance habit is not applicable today');
    }
    final existing = await _db
        .customSelect(
          'SELECT id FROM habit_avoidance_occurrences WHERE habit_id = ? AND local_date = ?',
          variables: [Variable<String>(habitId), Variable<String>(todayKey)],
        )
        .getSingleOrNull();
    if (existing != null) return existing.read<String>('id');

    final targetRow = await _db
        .customSelect(
          'SELECT max_incidents FROM habit_avoidance_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(detail.versionId!)],
        )
        .getSingleOrNull();
    if (targetRow == null) {
      throw StateError('Habit version is not configured as an avoidance habit');
    }
    await _db.customStatement(
      '''
      INSERT INTO habit_avoidance_occurrences
        (id, habit_id, habit_version_id, local_date, max_incidents)
      VALUES (?, ?, ?, ?, ?)
      ''',
      [
        candidateOccurrenceId,
        habitId,
        detail.versionId!,
        todayKey,
        targetRow.read<int>('max_incidents'),
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
