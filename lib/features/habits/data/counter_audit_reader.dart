import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/habit_schedule.dart';
import 'counter_recovery_store.dart';
import 'counter_resolution.dart';
import 'habit_lifecycle.dart';

/// Parsed audit record from `habit_version_audit`.
class CounterVersionAuditRecord {
  const CounterVersionAuditRecord({
    required this.id,
    required this.habitId,
    required this.operation,
    required this.previousValues,
    required this.updatedValues,
    required this.occurredAtUtc,
  });

  final String id;
  final String habitId;
  final String operation;
  final Map<String, Object?>? previousValues;
  final Map<String, Object?> updatedValues;
  final DateTime occurredAtUtc;
}

/// Creation audit snapshot from `habit_counter_event_audit`.
class CounterEventAuditRecord {
  const CounterEventAuditRecord({
    required this.eventId,
    required this.occurrenceId,
    required this.occurrenceDate,
    required this.quantity,
    required this.occurredAtUtc,
  });

  final String eventId;
  final String occurrenceId;
  final LocalDate occurrenceDate;
  final int quantity;
  final DateTime occurredAtUtc;
}

/// Resolution audit snapshot paired with its occurrence local date.
class CounterResolutionAuditRecord {
  const CounterResolutionAuditRecord({
    required this.occurrenceId,
    required this.occurrenceDate,
    required this.resolution,
  });

  final String occurrenceId;
  final LocalDate occurrenceDate;
  final CounterResolution resolution;
}

/// Recovery audit snapshot paired with its original occurrence local date.
class CounterRecoveryAuditRecord {
  const CounterRecoveryAuditRecord({
    required this.occurrenceDate,
    required this.recovery,
  });

  final LocalDate occurrenceDate;
  final CounterRecoveryRecord recovery;
}

/// Complete read-only local audit trail for a counter habit across versions,
/// lifecycle transitions, progress events, explicit resolutions and recoveries.
class CounterAuditTrail {
  const CounterAuditTrail({
    required this.habitId,
    required this.versionAudits,
    required this.lifecycleEvents,
    required this.eventAudits,
    required this.resolutionAudits,
    required this.recoveryAudits,
  });

  final String habitId;
  final List<CounterVersionAuditRecord> versionAudits;
  final List<HabitLifecycleEvent> lifecycleEvents;
  final List<CounterEventAuditRecord> eventAudits;
  final List<CounterResolutionAuditRecord> resolutionAudits;
  final List<CounterRecoveryAuditRecord> recoveryAudits;
}

/// Reads all persisted audit streams for a counter habit in one read
/// transaction without inventing missing legacy audit records.
class CounterAuditReader {
  const CounterAuditReader(this._db);

  final AppDatabase _db;

  Future<CounterAuditTrail> readForHabit(String habitId) => _db.transaction(
    () async {
      final habit = await _db
          .customSelect(
            'SELECT id FROM habits WHERE id = ?',
            variables: [Variable<String>(habitId)],
          )
          .getSingleOrNull();
      if (habit == null) throw StateError('Habit does not exist');

      final versionAuditRows = await _db
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
      final versionAudits = List<CounterVersionAuditRecord>.unmodifiable([
        for (final row in versionAuditRows)
          CounterVersionAuditRecord(
            id: row.read<String>('id'),
            habitId: row.read<String>('habit_id'),
            operation: row.read<String>('operation'),
            previousValues: _decodeJson(
              row.readNullable<String>('previous_values'),
            ),
            updatedValues: _decodeJson(row.read<String>('updated_values'))!,
            occurredAtUtc: DateTime.fromMicrosecondsSinceEpoch(
              row.read<int>('occurred_at_utc_us'),
              isUtc: true,
            ),
          ),
      ]);

      final lifecycleEvents = await HabitLifecycleReader(_db)
          .readHistory(habitId);

      final eventAuditRows = await _db
          .customSelect(
            '''
          SELECT a.event_id, a.occurrence_id, o.local_date, a.quantity, a.occurred_at_utc_us
          FROM habit_counter_event_audit a
          JOIN habit_occurrences o ON o.id = a.occurrence_id
          WHERE o.habit_id = ?
          ORDER BY a.occurred_at_utc_us ASC, a.event_id ASC
          ''',
            variables: [Variable<String>(habitId)],
          )
          .get();
      final eventAudits = List<CounterEventAuditRecord>.unmodifiable([
        for (final row in eventAuditRows)
          CounterEventAuditRecord(
            eventId: row.read<String>('event_id'),
            occurrenceId: row.read<String>('occurrence_id'),
            occurrenceDate: _parseDate(row.read<String>('local_date')),
            quantity: row.read<int>('quantity'),
            occurredAtUtc: DateTime.fromMicrosecondsSinceEpoch(
              row.read<int>('occurred_at_utc_us'),
              isUtc: true,
            ),
          ),
      ]);

      final resolutionRows = await _db
          .customSelect(
            '''
          SELECT r.id, r.occurrence_id, o.local_date, r.state, r.reason,
                 r.target_count, r.progress_total, r.occurred_at_utc_us
          FROM habit_counter_resolutions r
          JOIN habit_occurrences o ON o.id = r.occurrence_id
          WHERE o.habit_id = ?
          ORDER BY r.occurred_at_utc_us ASC, r.id ASC
          ''',
            variables: [Variable<String>(habitId)],
          )
          .get();
      final resolutionAudits = List<CounterResolutionAuditRecord>.unmodifiable([
        for (final row in resolutionRows)
          CounterResolutionAuditRecord(
            occurrenceId: row.read<String>('occurrence_id'),
            occurrenceDate: _parseDate(row.read<String>('local_date')),
            resolution: CounterResolution(
              id: row.read<String>('id'),
              state: CounterResolutionState.values.byName(
                row.read<String>('state'),
              ),
              reason: row.readNullable<String>('reason'),
              target: row.read<int>('target_count'),
              progress: row.read<int>('progress_total'),
              occurredAtUtc: DateTime.fromMicrosecondsSinceEpoch(
                row.read<int>('occurred_at_utc_us'),
                isUtc: true,
              ),
            ),
          ),
      ]);

      final recoveryRows = await _db
          .customSelect(
            '''
          SELECT rec.id, rec.occurrence_id, o.local_date AS occurrence_date,
                 rec.recovery_local_date, rec.quantity, rec.original_target_count,
                 rec.original_progress_total, rec.remaining_deficit, rec.note,
                 rec.occurred_at_utc_us
          FROM habit_counter_recoveries rec
          JOIN habit_occurrences o ON o.id = rec.occurrence_id
          WHERE o.habit_id = ?
          ORDER BY rec.occurred_at_utc_us ASC, rec.id ASC
          ''',
            variables: [Variable<String>(habitId)],
          )
          .get();
      final recoveryAudits = List<CounterRecoveryAuditRecord>.unmodifiable([
        for (final row in recoveryRows)
          CounterRecoveryAuditRecord(
            occurrenceDate: _parseDate(row.read<String>('occurrence_date')),
            recovery: CounterRecoveryRecord(
              id: row.read<String>('id'),
              occurrenceId: row.read<String>('occurrence_id'),
              recoveryDate: _parseDate(row.read<String>('recovery_local_date')),
              quantity: row.read<int>('quantity'),
              originalTarget: row.read<int>('original_target_count'),
              originalProgress: row.read<int>('original_progress_total'),
              remainingDeficit: row.read<int>('remaining_deficit'),
              note: row.readNullable<String>('note'),
              occurredAtUtc: DateTime.fromMicrosecondsSinceEpoch(
                row.read<int>('occurred_at_utc_us'),
                isUtc: true,
              ),
            ),
          ),
      ]);

      return CounterAuditTrail(
        habitId: habitId,
        versionAudits: versionAudits,
        lifecycleEvents: lifecycleEvents,
        eventAudits: eventAudits,
        resolutionAudits: resolutionAudits,
        recoveryAudits: recoveryAudits,
      );
    },
  );
}

Map<String, Object?>? _decodeJson(String? raw) {
  if (raw == null) return null;
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  return Map<String, Object?>.unmodifiable(decoded);
}

LocalDate _parseDate(String value) => LocalDate(
  int.parse(value.substring(0, 4)),
  int.parse(value.substring(5, 7)),
  int.parse(value.substring(8, 10)),
);
