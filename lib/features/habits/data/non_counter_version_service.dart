import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/avoidance_habit.dart';
import '../domain/boolean_duration_habit.dart';
import '../domain/checklist_habit.dart';
import '../domain/habit_metadata.dart';
import '../domain/habit_schedule.dart';
import '../domain/measurement_time_range_habit.dart';
import 'counter_audit_reader.dart';
import 'habit_lifecycle.dart';
import 'habit_metadata_store.dart';
import 'habit_schedule_store.dart';
import 'unified_habit_registry.dart';

/// Immutable snapshot of one dated non-counter habit version and its typed
/// configuration, recurrence schedule and optional version metadata.
class NonCounterVersionSnapshot {
  const NonCounterVersionSnapshot({
    required this.id,
    required this.habitId,
    required this.name,
    required this.effectiveStart,
    required this.effectiveEnd,
    required this.createdAtUtc,
    required this.revision,
    required this.trackingType,
    required this.schedule,
    required this.metadata,
    this.checklistItems,
    this.avoidanceTarget,
    this.durationTarget,
    this.measurementTarget,
    this.timeOfDayTarget,
    this.rangeTarget,
  });

  final String id;
  final String habitId;
  final String name;
  final LocalDate effectiveStart;
  final LocalDate? effectiveEnd;
  final DateTime createdAtUtc;
  final int revision;
  final HabitTrackingType trackingType;
  final HabitSchedule? schedule;
  final HabitMetadata? metadata;
  final List<ChecklistItemDefinition>? checklistItems;
  final AvoidanceTarget? avoidanceTarget;
  final DurationTarget? durationTarget;
  final MeasurementTarget? measurementTarget;
  final TimeOfDayTarget? timeOfDayTarget;
  final RangeTarget? rangeTarget;

  bool isEffectiveOn(LocalDate date) {
    if (date.compareTo(effectiveStart) < 0) return false;
    final end = effectiveEnd;
    return end == null || date.compareTo(end) < 0;
  }

  String get targetSummary {
    switch (trackingType) {
      case HabitTrackingType.checklist:
        final items = checklistItems ?? const [];
        return '${items.length} items (${items.map((e) => e.label).join(', ')})';
      case HabitTrackingType.avoidance:
        return 'max ${avoidanceTarget?.maxIncidents ?? 0} incidents';
      case HabitTrackingType.boolean:
        return 'boolean completion';
      case HabitTrackingType.duration:
        final secs = durationTarget?.targetSeconds ?? 0;
        return secs % 60 == 0 ? '${secs ~/ 60} min' : '$secs sec';
      case HabitTrackingType.measurement:
        final t = measurementTarget!;
        return '${t.rule.name} ${_formatScaled(t.scaledTarget, t.decimalPlaces)} ${t.unit}';
      case HabitTrackingType.timeOfDay:
        final t = timeOfDayTarget!;
        return '${t.rule.name} ${_formatMinutes(t.targetMinutesSinceMidnight)}';
      case HabitTrackingType.range:
        final t = rangeTarget!;
        return '${_formatScaled(t.minScaled, t.decimalPlaces)}..${_formatScaled(t.maxScaled, t.decimalPlaces)} ${t.unit}';
      case HabitTrackingType.counter || HabitTrackingType.unconfigured:
        return 'unconfigured';
    }
  }
}

/// Complete read-only configuration timeline and audit trail for a non-counter habit.
class NonCounterConfigurationAndAudit {
  NonCounterConfigurationAndAudit({
    required this.habitId,
    required this.asOfDate,
    required this.applicability,
    required this.effectiveLifecycle,
    required List<HabitLifecycleEvent> lifecycleHistory,
    required List<NonCounterVersionSnapshot> priorVersions,
    required this.effectiveVersion,
    required List<NonCounterVersionSnapshot> futureVersions,
    required List<CounterVersionAuditRecord> versionAudits,
  }) : lifecycleHistory = List.unmodifiable(lifecycleHistory),
       priorVersions = List.unmodifiable(priorVersions),
       futureVersions = List.unmodifiable(futureVersions),
       versionAudits = List.unmodifiable(versionAudits);

  final String habitId;
  final LocalDate asOfDate;
  final HabitApplicabilityDetail applicability;
  final HabitLifecycleEvent? effectiveLifecycle;
  final List<HabitLifecycleEvent> lifecycleHistory;
  final List<NonCounterVersionSnapshot> priorVersions;
  final NonCounterVersionSnapshot? effectiveVersion;
  final List<NonCounterVersionSnapshot> futureVersions;
  final List<CounterVersionAuditRecord> versionAudits;

  List<NonCounterVersionSnapshot> get allVersions => List.unmodifiable([
    ...priorVersions,
    ?effectiveVersion,
    ...futureVersions,
  ]);
}

/// Transactional future-version scheduling and read-only configuration/audit
/// inspection for all seven non-counter tracking types.
class NonCounterVersionService {
  const NonCounterVersionService(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<NonCounterConfigurationAndAudit> readConfigurationAndAudit({
    required String habitId,
    required LocalDate asOfDate,
  }) => _db.transaction(() async {
    _requireId(habitId, 'habitId');
    final habitRow = await _db
        .customSelect(
          'SELECT id FROM habits WHERE id = ?',
          variables: [Variable<String>(habitId)],
        )
        .getSingleOrNull();
    if (habitRow == null) {
      throw StateError('Habit does not exist');
    }

    final versionRows = await _db
        .customSelect(
          '''
      SELECT id, name, effective_start, effective_end, created_at_utc_us, revision
      FROM habit_versions
      WHERE habit_id = ?
      ORDER BY revision ASC
      ''',
          variables: [Variable<String>(habitId)],
        )
        .get();

    final scheduleStore = HabitScheduleStore(_db);
    final metadataStore = HabitMetadataStore(_db);
    final prior = <NonCounterVersionSnapshot>[];
    final future = <NonCounterVersionSnapshot>[];
    NonCounterVersionSnapshot? effective;

    for (final row in versionRows) {
      final versionId = row.read<String>('id');
      final start = _parseDate(row.read<String>('effective_start'));
      final endRaw = row.read<String?>('effective_end');
      final end = endRaw == null ? null : _parseDate(endRaw);
      final schedule = await scheduleStore.findForVersion(versionId);
      final metadata = await metadataStore.findForVersion(versionId);
      final snapshot = await _loadTypedSnapshot(
        versionId: versionId,
        habitId: habitId,
        name: row.read<String>('name'),
        effectiveStart: start,
        effectiveEnd: end,
        createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
          row.read<int>('created_at_utc_us'),
          isUtc: true,
        ),
        revision: row.read<int>('revision'),
        schedule: schedule,
        metadata: metadata,
      );

      if (snapshot.isEffectiveOn(asOfDate)) {
        effective = snapshot;
      } else if (asOfDate.compareTo(start) < 0) {
        future.add(snapshot);
      } else {
        prior.add(snapshot);
      }
    }

    final applicabilityReader = HabitApplicabilityReader(_db);
    final lifecycleReader = HabitLifecycleReader(_db);
    final applicability = await applicabilityReader.describe(habitId, asOfDate);
    final effectiveLifecycle = await lifecycleReader.findEffectiveOn(
      habitId,
      asOfDate,
    );
    final lifecycleHistory = await lifecycleReader.readHistory(habitId);

    final auditRows = await _db
        .customSelect(
          '''
      SELECT id, habit_id, operation, previous_values, updated_values, occurred_at_utc_us
      FROM habit_version_audit
      WHERE habit_id = ?
      ORDER BY occurred_at_utc_us ASC, id ASC
      ''',
          variables: [Variable<String>(habitId)],
        )
        .get();
    final versionAudits = [
      for (final row in auditRows)
        CounterVersionAuditRecord(
          id: row.read<String>('id'),
          habitId: row.read<String>('habit_id'),
          operation: row.read<String>('operation'),
          previousValues: _decodeJson(row.read<String?>('previous_values')),
          updatedValues: _decodeJson(row.read<String>('updated_values'))!,
          occurredAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            row.read<int>('occurred_at_utc_us'),
            isUtc: true,
          ),
        ),
    ];

    return NonCounterConfigurationAndAudit(
      habitId: habitId,
      asOfDate: asOfDate,
      applicability: applicability,
      effectiveLifecycle: effectiveLifecycle,
      lifecycleHistory: lifecycleHistory,
      priorVersions: prior,
      effectiveVersion: effective,
      futureVersions: future,
      versionAudits: versionAudits,
    );
  });

  Future<void> scheduleChecklistVersion({
    required String habitId,
    required String versionId,
    required String auditId,
    required String name,
    required DateTime effectiveDate,
    required List<ChecklistItemDefinition> items,
    required HabitSchedule schedule,
    HabitMetadata? metadata,
  }) => _db.transaction(() async {
    if (items.isEmpty) {
      throw ArgumentError('Checklist version requires at least one item');
    }
    await _scheduleNonCounterVersion(
      habitId: habitId,
      versionId: versionId,
      auditId: auditId,
      name: name,
      effectiveDate: effectiveDate,
      expectedTrackingType: 'checklist',
      schedule: schedule,
      metadata: metadata,
      writeTypedConfig: () async {
        for (final item in items) {
          await _db.customStatement(
            '''
            INSERT INTO habit_checklist_items
              (id, habit_version_id, label, display_order, recovery_enabled)
            VALUES (?, ?, ?, ?, ?)
            ''',
            [
              item.id,
              versionId,
              item.label,
              item.displayOrder,
              item.recoveryEnabled ? 1 : 0,
            ],
          );
        }
      },
    );
  });

  Future<void> scheduleAvoidanceVersion({
    required String habitId,
    required String versionId,
    required String auditId,
    required String name,
    required DateTime effectiveDate,
    required AvoidanceTarget target,
    required HabitSchedule schedule,
    HabitMetadata? metadata,
  }) => _db.transaction(() async {
    if (metadata != null && metadata.recoveryEnabled) {
      throw ArgumentError('Avoidance habits cannot enable recovery');
    }
    await _scheduleNonCounterVersion(
      habitId: habitId,
      versionId: versionId,
      auditId: auditId,
      name: name,
      effectiveDate: effectiveDate,
      expectedTrackingType: 'avoidance',
      schedule: schedule,
      metadata: metadata,
      writeTypedConfig: () async {
        await _db.customStatement(
          '''
          INSERT INTO habit_avoidance_targets (habit_version_id, max_incidents)
          VALUES (?, ?)
          ''',
          [versionId, target.maxIncidents],
        );
      },
    );
  });

  Future<void> scheduleBooleanVersion({
    required String habitId,
    required String versionId,
    required String auditId,
    required String name,
    required DateTime effectiveDate,
    required HabitSchedule schedule,
    HabitMetadata? metadata,
  }) => _db.transaction(() async {
    await _scheduleNonCounterVersion(
      habitId: habitId,
      versionId: versionId,
      auditId: auditId,
      name: name,
      effectiveDate: effectiveDate,
      expectedTrackingType: 'boolean',
      schedule: schedule,
      metadata: metadata,
      writeTypedConfig: () async {
        await _db.customStatement(
          '''
          INSERT INTO habit_typed_targets (habit_version_id, tracking_type)
          VALUES (?, 'boolean')
          ''',
          [versionId],
        );
      },
    );
  });

  Future<void> scheduleDurationVersion({
    required String habitId,
    required String versionId,
    required String auditId,
    required String name,
    required DateTime effectiveDate,
    required DurationTarget target,
    required HabitSchedule schedule,
    HabitMetadata? metadata,
  }) => _db.transaction(() async {
    await _scheduleNonCounterVersion(
      habitId: habitId,
      versionId: versionId,
      auditId: auditId,
      name: name,
      effectiveDate: effectiveDate,
      expectedTrackingType: 'duration',
      schedule: schedule,
      metadata: metadata,
      writeTypedConfig: () async {
        await _db.customStatement(
          '''
          INSERT INTO habit_typed_targets
            (habit_version_id, tracking_type, target_seconds)
          VALUES (?, 'duration', ?)
          ''',
          [versionId, target.targetSeconds],
        );
      },
    );
  });

  Future<void> scheduleMeasurementVersion({
    required String habitId,
    required String versionId,
    required String auditId,
    required String name,
    required DateTime effectiveDate,
    required MeasurementTarget target,
    required HabitSchedule schedule,
    HabitMetadata? metadata,
  }) => _db.transaction(() async {
    final ruleStr = switch (target.rule) {
      MeasurementComparisonRule.atLeast => 'at_least',
      MeasurementComparisonRule.atMost => 'at_most',
      MeasurementComparisonRule.exact => 'exact',
    };
    await _scheduleNonCounterVersion(
      habitId: habitId,
      versionId: versionId,
      auditId: auditId,
      name: name,
      effectiveDate: effectiveDate,
      expectedTrackingType: 'measurement',
      schedule: schedule,
      metadata: metadata,
      writeTypedConfig: () async {
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
      },
    );
  });

  Future<void> scheduleTimeOfDayVersion({
    required String habitId,
    required String versionId,
    required String auditId,
    required String name,
    required DateTime effectiveDate,
    required TimeOfDayTarget target,
    required HabitSchedule schedule,
    HabitMetadata? metadata,
  }) => _db.transaction(() async {
    final ruleStr = switch (target.rule) {
      TimeComparisonRule.atOrBefore => 'at_or_before',
      TimeComparisonRule.atOrAfter => 'at_or_after',
    };
    await _scheduleNonCounterVersion(
      habitId: habitId,
      versionId: versionId,
      auditId: auditId,
      name: name,
      effectiveDate: effectiveDate,
      expectedTrackingType: 'time_of_day',
      schedule: schedule,
      metadata: metadata,
      writeTypedConfig: () async {
        await _db.customStatement(
          '''
          INSERT INTO habit_typed_targets
            (habit_version_id, tracking_type, target_minutes_since_midnight, comparison_rule)
          VALUES (?, 'time_of_day', ?, ?)
          ''',
          [versionId, target.targetMinutesSinceMidnight, ruleStr],
        );
      },
    );
  });

  Future<void> scheduleRangeVersion({
    required String habitId,
    required String versionId,
    required String auditId,
    required String name,
    required DateTime effectiveDate,
    required RangeTarget target,
    required HabitSchedule schedule,
    HabitMetadata? metadata,
  }) => _db.transaction(() async {
    await _scheduleNonCounterVersion(
      habitId: habitId,
      versionId: versionId,
      auditId: auditId,
      name: name,
      effectiveDate: effectiveDate,
      expectedTrackingType: 'range',
      schedule: schedule,
      metadata: metadata,
      writeTypedConfig: () async {
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
      },
    );
  });

  Future<void> _scheduleNonCounterVersion({
    required String habitId,
    required String versionId,
    required String auditId,
    required String name,
    required DateTime effectiveDate,
    required String expectedTrackingType,
    required HabitSchedule schedule,
    required HabitMetadata? metadata,
    required Future<void> Function() writeTypedConfig,
  }) async {
    _requireId(habitId, 'habitId');
    _requireId(versionId, 'versionId');
    _requireId(auditId, 'auditId');
    final trimmedName = _requireName(name);
    final newStartDate = LocalDate(
      effectiveDate.year,
      effectiveDate.month,
      effectiveDate.day,
    );
    _validateScheduleForVersion(schedule, newStartDate);
    final newStart = _dateKey(newStartDate);
    final now = _clock.now();
    final today = _dateKey(_localDate(now));
    if (newStart.compareTo(today) <= 0) {
      throw StateError(
        'Same-day and backdated version changes require correction',
      );
    }

    final current = await _db
        .customSelect(
          '''
      SELECT id, name, effective_start, effective_end, revision
      FROM habit_versions
      WHERE habit_id = ?
      ORDER BY revision DESC
      LIMIT 1
      ''',
          variables: [Variable<String>(habitId)],
        )
        .getSingleOrNull();
    if (current == null) {
      throw StateError('Habit does not exist');
    }
    if (current.read<String?>('effective_end') != null) {
      throw StateError('Latest habit version is already closed');
    }
    final previousVersionId = current.read<String>('id');
    final previousStart = current.read<String>('effective_start');
    if (newStart.compareTo(previousStart) <= 0) {
      throw StateError(
        'New version must start after the current version start',
      );
    }

    final actualPrevType = await _readTrackingTypeString(previousVersionId);
    if (actualPrevType != expectedTrackingType) {
      throw StateError(
        'Latest version is not configured as a $expectedTrackingType habit',
      );
    }

    await _ensureNoOccurrencesOnOrAfter(habitId: habitId, dateKey: newStart);

    final prevSnapshot = await _readRawVersionAuditMap(
      habitId: habitId,
      versionId: previousVersionId,
      trackingType: expectedTrackingType,
    );

    final nextRevision = current.read<int>('revision') + 1;
    final timestamp = now.toUtc().microsecondsSinceEpoch;

    await _db.customStatement(
      'UPDATE habit_versions SET effective_end = ? WHERE id = ?',
      [newStart, previousVersionId],
    );
    await _db.customStatement(
      '''
      INSERT INTO habit_versions
        (id, habit_id, name, effective_start, effective_end, created_at_utc_us, revision)
      VALUES (?, ?, ?, ?, NULL, ?, ?)
      ''',
      [versionId, habitId, trimmedName, newStart, timestamp, nextRevision],
    );

    await writeTypedConfig();
    await HabitScheduleStore(_db).insert(versionId, schedule);
    if (metadata != null) {
      await HabitMetadataStore(_db).insert(versionId, metadata);
    }

    final closedPrevSnapshot = await _readRawVersionAuditMap(
      habitId: habitId,
      versionId: previousVersionId,
      trackingType: expectedTrackingType,
    );
    final newVersionSnapshot = await _readRawVersionAuditMap(
      habitId: habitId,
      versionId: versionId,
      trackingType: expectedTrackingType,
    );

    await _db.customStatement(
      '''
      INSERT INTO habit_version_audit
        (id, habit_id, operation, previous_values, updated_values, occurred_at_utc_us)
      VALUES (?, ?, 'schedule_version', ?, ?, ?)
      ''',
      [
        auditId,
        habitId,
        jsonEncode({'previous_version': prevSnapshot}),
        jsonEncode({
          'closed_previous_version': closedPrevSnapshot,
          'new_version': newVersionSnapshot,
        }),
        timestamp,
      ],
    );
  }

  Future<void> _ensureNoOccurrencesOnOrAfter({
    required String habitId,
    required String dateKey,
  }) async {
    for (final table in const [
      'habit_occurrences',
      'habit_checklist_occurrences',
      'habit_avoidance_occurrences',
      'habit_typed_occurrences',
    ]) {
      final row = await _db
          .customSelect(
            'SELECT 1 FROM $table WHERE habit_id = ? AND local_date >= ? LIMIT 1',
            variables: [Variable<String>(habitId), Variable<String>(dateKey)],
          )
          .getSingleOrNull();
      if (row != null) {
        throw StateError(
          'Version change would alter existing occurrences on or after $dateKey',
        );
      }
    }
  }

  Future<String?> _readTrackingTypeString(String versionId) async {
    final checklist = await _db
        .customSelect(
          'SELECT 1 FROM habit_checklist_items WHERE habit_version_id = ? LIMIT 1',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (checklist != null) return 'checklist';

    final avoidance = await _db
        .customSelect(
          'SELECT 1 FROM habit_avoidance_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (avoidance != null) return 'avoidance';

    final typed = await _db
        .customSelect(
          'SELECT tracking_type FROM habit_typed_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    return typed?.read<String>('tracking_type');
  }

  Future<Map<String, Object?>> _readRawVersionAuditMap({
    required String habitId,
    required String versionId,
    required String trackingType,
  }) async {
    final version = await _db
        .customSelect(
          'SELECT * FROM habit_versions WHERE id = ? AND habit_id = ?',
          variables: [Variable<String>(versionId), Variable<String>(habitId)],
        )
        .getSingle();
    final schedule = await _db
        .customSelect(
          'SELECT * FROM habit_schedules WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    final metadata = await _db
        .customSelect(
          'SELECT * FROM habit_version_metadata WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    final targetSql = switch (trackingType) {
      'checklist' => null,
      'avoidance' =>
        'SELECT * FROM habit_avoidance_targets WHERE habit_version_id = ?',
      'boolean' || 'duration' || 'measurement' || 'time_of_day' || 'range' => 'SELECT * FROM habit_typed_targets WHERE habit_version_id = ? AND tracking_type = ?',
      _ => throw ArgumentError.value(trackingType, 'trackingType'),
    };
    final target = targetSql == null
        ? null
        : await _db
              .customSelect(
                targetSql,
                variables: [
                  Variable<String>(versionId),
                  if (trackingType != 'avoidance')
                    Variable<String>(trackingType),
                ],
              )
              .getSingleOrNull();
    final items = trackingType == 'checklist'
        ? await _db
              .customSelect(
                'SELECT * FROM habit_checklist_items WHERE habit_version_id = ? ORDER BY display_order, id',
                variables: [Variable<String>(versionId)],
              )
              .get()
        : <QueryRow>[];
    return {
      'version': version.data,
      'schedule': schedule?.data,
      'metadata': metadata?.data,
      'tracking_type': trackingType,
      'target': target?.data,
      'items': [for (final item in items) item.data],
    };
  }

  Future<NonCounterVersionSnapshot> _loadTypedSnapshot({
    required String versionId,
    required String habitId,
    required String name,
    required LocalDate effectiveStart,
    required LocalDate? effectiveEnd,
    required DateTime createdAtUtc,
    required int revision,
    required HabitSchedule? schedule,
    required HabitMetadata? metadata,
  }) async {
    final itemRows = await _db
        .customSelect(
          '''
      SELECT id, label, display_order, recovery_enabled
      FROM habit_checklist_items
      WHERE habit_version_id = ?
      ORDER BY display_order ASC, id ASC
      ''',
          variables: [Variable<String>(versionId)],
        )
        .get();
    if (itemRows.isNotEmpty) {
      return NonCounterVersionSnapshot(
        id: versionId,
        habitId: habitId,
        name: name,
        effectiveStart: effectiveStart,
        effectiveEnd: effectiveEnd,
        createdAtUtc: createdAtUtc,
        revision: revision,
        trackingType: HabitTrackingType.checklist,
        schedule: schedule,
        metadata: metadata,
        checklistItems: List.unmodifiable([
          for (final row in itemRows)
            ChecklistItemDefinition(
              id: row.read<String>('id'),
              label: row.read<String>('label'),
              displayOrder: row.read<int>('display_order'),
              recoveryEnabled: row.read<int>('recovery_enabled') == 1,
            ),
        ]),
      );
    }

    final avoidanceRow = await _db
        .customSelect(
          'SELECT max_incidents FROM habit_avoidance_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (avoidanceRow != null) {
      return NonCounterVersionSnapshot(
        id: versionId,
        habitId: habitId,
        name: name,
        effectiveStart: effectiveStart,
        effectiveEnd: effectiveEnd,
        createdAtUtc: createdAtUtc,
        revision: revision,
        trackingType: HabitTrackingType.avoidance,
        schedule: schedule,
        metadata: metadata,
        avoidanceTarget: AvoidanceTarget(
          maxIncidents: avoidanceRow.read<int>('max_incidents'),
        ),
      );
    }

    final typedRow = await _db
        .customSelect(
          'SELECT * FROM habit_typed_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (typedRow != null) {
      final typeStr = typedRow.read<String>('tracking_type');
      switch (typeStr) {
        case 'boolean':
          return NonCounterVersionSnapshot(
            id: versionId,
            habitId: habitId,
            name: name,
            effectiveStart: effectiveStart,
            effectiveEnd: effectiveEnd,
            createdAtUtc: createdAtUtc,
            revision: revision,
            trackingType: HabitTrackingType.boolean,
            schedule: schedule,
            metadata: metadata,
          );
        case 'duration':
          return NonCounterVersionSnapshot(
            id: versionId,
            habitId: habitId,
            name: name,
            effectiveStart: effectiveStart,
            effectiveEnd: effectiveEnd,
            createdAtUtc: createdAtUtc,
            revision: revision,
            trackingType: HabitTrackingType.duration,
            schedule: schedule,
            metadata: metadata,
            durationTarget: DurationTarget(
              targetSeconds: typedRow.read<int>('target_seconds'),
            ),
          );
        case 'measurement':
          return NonCounterVersionSnapshot(
            id: versionId,
            habitId: habitId,
            name: name,
            effectiveStart: effectiveStart,
            effectiveEnd: effectiveEnd,
            createdAtUtc: createdAtUtc,
            revision: revision,
            trackingType: HabitTrackingType.measurement,
            schedule: schedule,
            metadata: metadata,
            measurementTarget: MeasurementTarget(
              scaledTarget: typedRow.read<int>('scaled_target'),
              decimalPlaces: typedRow.read<int>('decimal_places'),
              unit: typedRow.read<String>('unit'),
              rule: switch (typedRow.read<String>('comparison_rule')) {
                'at_least' => MeasurementComparisonRule.atLeast,
                'at_most' => MeasurementComparisonRule.atMost,
                _ => MeasurementComparisonRule.exact,
              },
            ),
          );
        case 'time_of_day':
          return NonCounterVersionSnapshot(
            id: versionId,
            habitId: habitId,
            name: name,
            effectiveStart: effectiveStart,
            effectiveEnd: effectiveEnd,
            createdAtUtc: createdAtUtc,
            revision: revision,
            trackingType: HabitTrackingType.timeOfDay,
            schedule: schedule,
            metadata: metadata,
            timeOfDayTarget: TimeOfDayTarget(
              targetMinutesSinceMidnight: typedRow.read<int>(
                'target_minutes_since_midnight',
              ),
              rule: typedRow.read<String>('comparison_rule') == 'at_or_before'
                  ? TimeComparisonRule.atOrBefore
                  : TimeComparisonRule.atOrAfter,
            ),
          );
        case 'range':
          return NonCounterVersionSnapshot(
            id: versionId,
            habitId: habitId,
            name: name,
            effectiveStart: effectiveStart,
            effectiveEnd: effectiveEnd,
            createdAtUtc: createdAtUtc,
            revision: revision,
            trackingType: HabitTrackingType.range,
            schedule: schedule,
            metadata: metadata,
            rangeTarget: RangeTarget(
              minScaled: typedRow.read<int>('min_scaled'),
              maxScaled: typedRow.read<int>('max_scaled'),
              decimalPlaces: typedRow.read<int>('decimal_places'),
              unit: typedRow.read<String>('unit'),
            ),
          );
      }
    }

    return NonCounterVersionSnapshot(
      id: versionId,
      habitId: habitId,
      name: name,
      effectiveStart: effectiveStart,
      effectiveEnd: effectiveEnd,
      createdAtUtc: createdAtUtc,
      revision: revision,
      trackingType: HabitTrackingType.unconfigured,
      schedule: schedule,
      metadata: metadata,
    );
  }
}

void _requireId(String value, String field) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, field, 'ID must not be blank');
  }
}

String _requireName(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(value, 'name', 'Habit name must not be blank');
  }
  return trimmed;
}

void _validateScheduleForVersion(HabitSchedule schedule, LocalDate startDate) {
  if (schedule.start.compareTo(startDate) != 0) {
    throw ArgumentError('Schedule start must match version effective start');
  }
  final endExclusive = schedule.endExclusive;
  if (endExclusive != null && endExclusive.compareTo(startDate) <= 0) {
    throw ArgumentError('Schedule must not end on or before version start');
  }
}

LocalDate _localDate(DateTime instant) {
  final local = instant.toLocal();
  return LocalDate(local.year, local.month, local.day);
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

LocalDate _parseDate(String value) => LocalDate(
  int.parse(value.substring(0, 4)),
  int.parse(value.substring(5, 7)),
  int.parse(value.substring(8, 10)),
);

String _formatScaled(int scaled, int decimalPlaces) {
  if (decimalPlaces <= 0) return '$scaled';
  final negative = scaled < 0;
  final absVal = scaled.abs().toString().padLeft(decimalPlaces + 1, '0');
  final split = absVal.length - decimalPlaces;
  final whole = absVal.substring(0, split);
  final frac = absVal.substring(split);
  return '${negative ? '-' : ''}$whole.$frac';
}

String _formatMinutes(int minutes) {
  final h = (minutes ~/ 60).toString().padLeft(2, '0');
  final m = (minutes % 60).toString().padLeft(2, '0');
  return '$h:$m';
}

Map<String, Object?>? _decodeJson(String? raw) {
  if (raw == null) return null;
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  return Map<String, Object?>.unmodifiable(decoded);
}
