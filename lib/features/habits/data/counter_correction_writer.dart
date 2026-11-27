import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/habit_schedule.dart';
import 'counter_correction_preview.dart';

/// Immutable historical correction audit record and before/after preimages.
class CounterCorrectionAuditRecord {
  const CounterCorrectionAuditRecord({
    required this.id,
    required this.habitId,
    required this.versionId,
    required this.effectiveStart,
    required this.effectiveEnd,
    required this.previousTargetCount,
    required this.updatedTargetCount,
    required this.unit,
    required this.reason,
    required this.beforeSnapshot,
    required this.afterSnapshot,
    required this.occurredAtUtc,
  });

  final String id;
  final String habitId;
  final String versionId;
  final LocalDate effectiveStart;
  final LocalDate? effectiveEnd;
  final int previousTargetCount;
  final int updatedTargetCount;
  final String unit;
  final String? reason;
  final Map<String, Object?> beforeSnapshot;
  final Map<String, Object?> afterSnapshot;
  final DateTime occurredAtUtc;
}

/// Commits an explicitly confirmed historical counter target correction in one
/// SQLite write transaction, rejecting stale previews and preserving preimages.
class CounterCorrectionWriter {
  const CounterCorrectionWriter(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<void> commit({
    required String correctionAuditId,
    required CounterCorrectionPreview confirmedPreview,
  }) => _db.transaction(() async {
    final previewer = CounterCorrectionPreviewer(_db, _clock);
    if (await previewer.isStale(confirmedPreview)) {
      throw StateError(
        'Correction preview is stale; generate and confirm a fresh preview',
      );
    }

    final proposal = confirmedPreview.proposal;
    final startStr = _dateKey(confirmedPreview.effectiveStart);
    final endStr = confirmedPreview.effectiveEnd == null
        ? null
        : _dateKey(confirmedPreview.effectiveEnd!);
    final now = _clock.now();
    final localNow = now.toLocal();
    if (LocalDate(
          localNow.year,
          localNow.month,
          localNow.day,
        ).compareTo(confirmedPreview.previewedOnLocalDate) !=
        0) {
      throw StateError(
        'Correction preview is stale; generate and confirm a fresh preview',
      );
    }
    final nowUtcUs = now.toUtc().microsecondsSinceEpoch;
    final readSet =
        jsonDecode(confirmedPreview.snapshotSignature) as Map<String, dynamic>;
    final priorAudits = readSet['correction_audits'] as List<dynamic>;

    final beforeSnapshot = <String, Object?>{
      'version_id': proposal.versionId,
      'name': confirmedPreview.versionName,
      'effective_start': startStr,
      'effective_end': endStr,
      'target_count': confirmedPreview.originalTarget.count,
      'unit': confirmedPreview.originalTarget.unit,
      'previous_correction_audit_id': priorAudits.isEmpty
          ? null
          : (priorAudits.last as Map<String, dynamic>)['id'],
      'affected_occurrences': [
        for (final occ in confirmedPreview.affectedOccurrences)
          {
            'occurrence_id': occ.occurrenceId,
            'local_date': _dateKey(occ.date),
            'original_target_count': occ.originalTarget,
            'recorded_total': occ.recordedTotal,
            'original_status': occ.originalProgressStatus.name,
          },
      ],
      // These are the exact immutable source preimages bound by the preview.
      // They also establish which recoveries existed at each correction.
      'source_occurrences': readSet['occurrences'],
    };

    final afterSnapshot = <String, Object?>{
      'version_id': proposal.versionId,
      'name': confirmedPreview.versionName,
      'effective_start': startStr,
      'effective_end': endStr,
      'target_count': confirmedPreview.proposedTarget.count,
      'unit': confirmedPreview.proposedTarget.unit,
      'affected_occurrences': [
        for (final occ in confirmedPreview.affectedOccurrences)
          {
            'occurrence_id': occ.occurrenceId,
            'local_date': _dateKey(occ.date),
            'updated_target_count': occ.proposedTarget,
            'recorded_total': occ.recordedTotal,
            'updated_status': occ.proposedProgressStatus.name,
          },
      ],
    };

    await _db.customStatement(
      'DROP TRIGGER habit_counter_targets_protect_update',
    );
    await _db.customStatement(
      'DROP TRIGGER habit_occurrences_protect_interpretation',
    );

    await _db.customStatement(
      '''
      UPDATE habit_counter_targets
      SET target_count = ?
      WHERE habit_version_id = ?
      ''',
      [confirmedPreview.proposedTarget.count, proposal.versionId],
    );

    await _db.customStatement(
      '''
      UPDATE habit_occurrences
      SET target_count = ?
      WHERE habit_version_id = ?
      ''',
      [confirmedPreview.proposedTarget.count, proposal.versionId],
    );

    await _db.createCounterTargetAndOccurrenceProtectionTriggers();

    await _db.customStatement(
      '''
      INSERT INTO habit_counter_correction_audit
        (id, habit_id, habit_version_id, effective_start, effective_end,
         previous_target_count, updated_target_count, unit, reason,
         before_snapshot_json, after_snapshot_json, occurred_at_utc_us)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        correctionAuditId,
        proposal.habitId,
        proposal.versionId,
        startStr,
        endStr,
        confirmedPreview.originalTarget.count,
        confirmedPreview.proposedTarget.count,
        confirmedPreview.proposedTarget.unit,
        proposal.reason,
        jsonEncode(beforeSnapshot),
        jsonEncode(afterSnapshot),
        nowUtcUs,
      ],
    );
  });

  Future<List<CounterCorrectionAuditRecord>> readAuditsForHabit(
    String habitId,
  ) async {
    final rows = await _db
        .customSelect(
          '''
      SELECT id, habit_id, habit_version_id, effective_start, effective_end,
             previous_target_count, updated_target_count, unit, reason,
             before_snapshot_json, after_snapshot_json, occurred_at_utc_us
      FROM habit_counter_correction_audit
      WHERE habit_id = ?
      ORDER BY occurred_at_utc_us ASC, id ASC
      ''',
          variables: [Variable<String>(habitId)],
        )
        .get();
    return List.unmodifiable([
      for (final row in rows)
        CounterCorrectionAuditRecord(
          id: row.read<String>('id'),
          habitId: row.read<String>('habit_id'),
          versionId: row.read<String>('habit_version_id'),
          effectiveStart: _parseDate(row.read<String>('effective_start')),
          effectiveEnd: row.readNullable<String>('effective_end') == null
              ? null
              : _parseDate(row.read<String>('effective_end')),
          previousTargetCount: row.read<int>('previous_target_count'),
          updatedTargetCount: row.read<int>('updated_target_count'),
          unit: row.read<String>('unit'),
          reason: row.readNullable<String>('reason'),
          beforeSnapshot: Map<String, Object?>.unmodifiable(
            jsonDecode(row.read<String>('before_snapshot_json'))
                as Map<String, dynamic>,
          ),
          afterSnapshot: Map<String, Object?>.unmodifiable(
            jsonDecode(row.read<String>('after_snapshot_json'))
                as Map<String, dynamic>,
          ),
          occurredAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            row.read<int>('occurred_at_utc_us'),
            isUtc: true,
          ),
        ),
    ]);
  }
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

LocalDate _parseDate(String value) => LocalDate(
  int.parse(value.substring(0, 4)),
  int.parse(value.substring(5, 7)),
  int.parse(value.substring(8, 10)),
);
