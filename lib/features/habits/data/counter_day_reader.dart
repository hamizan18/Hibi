import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/counter_day_status.dart';
import '../domain/counter_progress.dart';
import '../domain/counter_target.dart';
import '../domain/habit_schedule.dart';
import 'counter_progress_reader.dart';
import 'counter_recovery_store.dart';
import 'counter_resolution.dart';
import 'habit_lifecycle.dart';

/// Legacy audits lack predecessors; multiple roots cannot be safely ordered.
class CounterCorrectionHistoryException extends StateError {
  CounterCorrectionHistoryException()
    : super('Ambiguous correction audit history');
}

/// Orders immutable audit records by explicit predecessor, never by clock,
/// identifier or SQLite rowid. A single legacy audit can be the chain root.
Future<List<QueryRow>> orderedCounterCorrectionAudits(
  AppDatabase db,
  String versionId,
) async {
  final rows = await db
      .customSelect(
        '''
    SELECT id, previous_target_count, updated_target_count, before_snapshot_json
    FROM habit_counter_correction_audit WHERE habit_version_id = ?
    ''',
        variables: [Variable<String>(versionId)],
      )
      .get();
  final children = <String?, QueryRow>{};
  for (final row in rows) {
    final before = jsonDecode(
      row.read<String>('before_snapshot_json'),
    ) as Map<String, dynamic>;
    final predecessor = before['previous_correction_audit_id'] as String?;
    if (children.containsKey(predecessor)) {
      throw CounterCorrectionHistoryException();
    }
    children[predecessor] = row;
  }
  final ordered = <QueryRow>[];
  String? predecessor;
  while (children.containsKey(predecessor)) {
    final row = children.remove(predecessor)!;
    ordered.add(row);
    predecessor = row.read<String>('id');
  }
  if (children.isNotEmpty) throw CounterCorrectionHistoryException();
  return ordered;
}

/// Scheduling applicability and recorded progress are independent facts.
typedef CounterDay = ({
  HabitApplicability applicability,
  String? occurrenceId,
  ({CounterProgress progress, String unit})? recorded,
  CounterResolution? resolution,
  List<CounterRecoveryRecord> recoveries,
});

/// Reads an existing day consistently without creating or changing records.
class CounterDayReader {
  const CounterDayReader(this._db);

  final AppDatabase _db;

  Future<CounterDay> read({required String habitId, required LocalDate date}) =>
      _db.transaction(() => _readDay(habitId, date));

  Future<CounterDayEvaluation> evaluate({
    required String habitId,
    required LocalDate date,
  }) => _db.transaction(() async {
    final day = await _readDay(habitId, date);
    final configuredTarget = await _findConfiguredTarget(habitId, date);
    late final List<CounterCorrectionStage> corrections;
    try {
      corrections = day.occurrenceId == null
          ? const <CounterCorrectionStage>[]
          : await _correctionsForOccurrence(day.occurrenceId!);
    } on CounterCorrectionHistoryException {
      return CounterDayEvaluation(
        effectiveStatus: CounterDayEffectiveStatus.conflict,
        day: day,
        configuredTarget: configuredTarget,
      );
    }
    // Recovery snapshots have strictly decreasing remaining deficits within
    // each target epoch. Audit checkpoints anchor the earlier epochs, even
    // when timestamps tie or SQLite renumbers rowids.
    final orderedRecoveries = [...day.recoveries];
    final checkpoint = corrections
        .where((stage) => stage.recoveryIds != null)
        .map((stage) => stage.recoveryIds!)
        .lastOrNull;
    final checkpointIndex = <String, int>{
      if (checkpoint != null)
        for (var i = 0; i < checkpoint.length; i++) checkpoint[i]: i,
    };
    final targets = <int>[
      if (corrections.isNotEmpty) corrections.first.previous,
      for (final stage in corrections) stage.updated,
    ];
    orderedRecoveries.sort((a, b) {
      final ai = checkpointIndex[a.id];
      final bi = checkpointIndex[b.id];
      if (ai != null && bi != null) return ai.compareTo(bi);
      if (ai != null) return -1;
      if (bi != null) return 1;
      final targetOrder = targets
          .indexOf(a.originalTarget)
          .compareTo(targets.indexOf(b.originalTarget));
      if (targetOrder != 0) return targetOrder;
      return b.remainingDeficit.compareTo(a.remainingDeficit);
    });
    final interpretedDay = (
      applicability: day.applicability,
      occurrenceId: day.occurrenceId,
      recorded: day.recorded,
      resolution: day.resolution,
      recoveries: orderedRecoveries,
    );
    return interpretCounterDay(
      day: interpretedDay,
      configuredTarget: configuredTarget,
      date: date,
      corrections: corrections,
    );
  });

  Future<CounterDay> _readDay(String habitId, LocalDate date) async {
    final applicability = await HabitApplicabilityReader(_db)
        .evaluate(habitId, date);
    final key = _dateKey(date);
    final occurrence = await _db
        .customSelect(
          'SELECT id FROM habit_occurrences WHERE habit_id = ? AND local_date = ?',
          variables: [Variable<String>(habitId), Variable<String>(key)],
        )
        .getSingleOrNull();
    final id = occurrence?.read<String>('id');
    final recorded = id == null
        ? null
        : await CounterProgressReader(_db).find(id);
    final resolution = id == null
        ? null
        : await CounterResolutionReader(_db).find(id);
    final recoveries = id == null
        ? const <CounterRecoveryRecord>[]
        : await CounterRecoveryReader(_db).findForOccurrence(id);
    return (
      applicability: applicability,
      occurrenceId: id,
      recorded: recorded,
      resolution: resolution,
      recoveries: recoveries,
    );
  }

  Future<List<CounterCorrectionStage>> _correctionsForOccurrence(
    String occurrenceId,
  ) async {
    final occurrence = await _db
        .customSelect(
          'SELECT habit_version_id FROM habit_occurrences WHERE id = ?',
          variables: [Variable<String>(occurrenceId)],
        )
        .getSingle();
    final rows = await orderedCounterCorrectionAudits(
      _db,
      occurrence.read<String>('habit_version_id'),
    );
    final result = <CounterCorrectionStage>[];
    for (final row in rows) {
      final before = jsonDecode(
        row.read<String>('before_snapshot_json'),
      ) as Map<String, dynamic>;
      final affected = before['affected_occurrences'] as List<dynamic>;
      if (!affected.any(
        (item) =>
            (item as Map<String, dynamic>)['occurrence_id'] == occurrenceId,
      )) {
        continue;
      }
      final sources = before['source_occurrences'] as List<dynamic>?;
      Map<String, dynamic>? source;
      if (sources != null) {
        source = sources.cast<Map<String, dynamic>>().firstWhere(
          (item) => item['id'] == occurrenceId,
        );
      }
      final resolution = source?['resolution'] as Map<String, dynamic>?;
      result.add((
        previous: row.read<int>('previous_target_count'),
        updated: row.read<int>('updated_target_count'),
        recoveryIds: source == null
            ? null
            : (source['recoveries'] as List<dynamic>)
                  .map((item) => (item as Map<String, dynamic>)['id'] as String)
                  .toList(growable: false),
        resolutionId: resolution?['id'] as String?,
      ));
    }
    return result;
  }

  Future<CounterTarget?> _findConfiguredTarget(
    String habitId,
    LocalDate date,
  ) async {
    final key = _dateKey(date);
    final row = await _db
        .customSelect(
          '''
      SELECT t.target_count, t.unit
      FROM habit_versions v
      JOIN habit_counter_targets t ON t.habit_version_id = v.id
      WHERE v.habit_id = ? AND v.effective_start <= ?
        AND (v.effective_end IS NULL OR ? < v.effective_end)
      ''',
          variables: [
            Variable<String>(habitId),
            Variable<String>(key),
            Variable<String>(key),
          ],
        )
        .getSingleOrNull();
    if (row == null) return null;
    return CounterTarget(
      count: row.read<int>('target_count'),
      unit: row.read<String>('unit'),
    );
  }
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
