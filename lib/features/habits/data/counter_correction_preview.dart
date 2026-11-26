import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../domain/counter_progress.dart';
import '../domain/counter_target.dart';
import '../domain/habit_schedule.dart';

/// Indicates whether a downstream derived-data engine exists for recalculation.
enum CounterDerivedImpactAvailability { notImplemented }

/// Typed proposal to correct a counter version's historical target count.
/// Unit changes across existing history are rejected to prevent reinterpretation.
class CounterTargetCorrectionProposal {
  const CounterTargetCorrectionProposal({
    required this.habitId,
    required this.versionId,
    required this.proposedTargetCount,
    required this.proposedUnit,
    this.reason,
  });

  final String habitId;
  final String versionId;
  final int proposedTargetCount;
  final String proposedUnit;
  final String? reason;
}

/// Before/after interpretation of an existing occurrence under a proposed target.
class CounterCorrectionOccurrenceImpact {
  const CounterCorrectionOccurrenceImpact({
    required this.occurrenceId,
    required this.date,
    required this.originalTarget,
    required this.proposedTarget,
    required this.recordedTotal,
    required this.eventCount,
    required this.originalProgressStatus,
    required this.proposedProgressStatus,
    required this.hasResolution,
    required this.recoveryCount,
  });

  final String occurrenceId;
  final LocalDate date;
  final int originalTarget;
  final int proposedTarget;
  final int recordedTotal;
  final int eventCount;
  final CounterProgressStatus originalProgressStatus;
  final CounterProgressStatus proposedProgressStatus;
  final bool hasResolution;
  final int recoveryCount;
}

/// Read-only preview of a proposed counter target correction bound to an exact
/// read-set snapshot and local calendar date.
class CounterCorrectionPreview {
  const CounterCorrectionPreview({
    required this.proposal,
    required this.previewedOnLocalDate,
    required this.versionName,
    required this.effectiveStart,
    required this.effectiveEnd,
    required this.originalTarget,
    required this.proposedTarget,
    required this.affectedOccurrences,
    required this.totalAffectedEventCount,
    required this.totalAffectedResolutionCount,
    required this.totalAffectedRecoveryCount,
    required this.scoreImpact,
    required this.streakImpact,
    required this.rewardImpact,
    required this.achievementImpact,
    required this.englishConfirmationSummary,
    required this.snapshotSignature,
  });

  final CounterTargetCorrectionProposal proposal;
  final LocalDate previewedOnLocalDate;
  final String versionName;
  final LocalDate effectiveStart;
  final LocalDate? effectiveEnd;
  final CounterTarget originalTarget;
  final CounterTarget proposedTarget;
  final List<CounterCorrectionOccurrenceImpact> affectedOccurrences;
  final int totalAffectedEventCount;
  final int totalAffectedResolutionCount;
  final int totalAffectedRecoveryCount;
  final CounterDerivedImpactAvailability scoreImpact;
  final CounterDerivedImpactAvailability streakImpact;
  final CounterDerivedImpactAvailability rewardImpact;
  final CounterDerivedImpactAvailability achievementImpact;
  final String englishConfirmationSummary;
  final String snapshotSignature;

  bool get isUnboundedEnd => effectiveEnd == null;
}

/// Generates a side-effect-free historical correction preview and checks
/// whether a previously generated preview has become stale.
class CounterCorrectionPreviewer {
  const CounterCorrectionPreviewer(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<CounterCorrectionPreview> preview(
    CounterTargetCorrectionProposal proposal,
  ) => _db.transaction(() => _buildPreview(proposal));

  Future<bool> isStale(CounterCorrectionPreview existingPreview) =>
      _db.transaction(() async {
        final today = _currentLocalDate(_clock.now());
        if (today.compareTo(existingPreview.previewedOnLocalDate) != 0) {
          return true;
        }
        try {
          final current = await _buildPreview(existingPreview.proposal);
          return current.snapshotSignature != existingPreview.snapshotSignature;
        } on Object {
          return true;
        }
      });

  Future<CounterCorrectionPreview> _buildPreview(
    CounterTargetCorrectionProposal proposal,
  ) async {
    final proposedTarget = CounterTarget(
      count: proposal.proposedTargetCount,
      unit: proposal.proposedUnit,
    );
    final today = _currentLocalDate(_clock.now());

    final versionRow = await _db
        .customSelect(
          '''
      SELECT v.id, v.habit_id, v.name, v.effective_start, v.effective_end,
             v.revision, v.created_at_utc_us, t.target_count, t.unit
      FROM habit_versions v
      LEFT JOIN habit_counter_targets t ON t.habit_version_id = v.id
      WHERE v.id = ? AND v.habit_id = ?
      ''',
          variables: [
            Variable<String>(proposal.versionId),
            Variable<String>(proposal.habitId),
          ],
        )
        .getSingleOrNull();
    if (versionRow == null) {
      throw StateError('Habit version does not exist for the specified habit');
    }
    final existingCount = versionRow.readNullable<int>('target_count');
    final existingUnit = versionRow.readNullable<String>('unit');
    if (existingCount == null || existingUnit == null) {
      throw StateError('Habit version has no configured counter target');
    }
    final originalTarget = CounterTarget(
      count: existingCount,
      unit: existingUnit,
    );
    if (proposedTarget.unit != originalTarget.unit) {
      throw ArgumentError(
        'Incompatible unit change (${originalTarget.unit} to ${proposedTarget.unit}) cannot reinterpret historical records',
      );
    }
    if (proposedTarget.count == originalTarget.count) {
      throw ArgumentError('Proposed target count matches the current target');
    }

    final startStr = versionRow.read<String>('effective_start');
    final endStr = versionRow.readNullable<String>('effective_end');
    final effectiveStart = _parseDate(startStr);
    final effectiveEnd = endStr == null ? null : _parseDate(endStr);
    final versionName = versionRow.read<String>('name');

    final scheduleRow = await _db
        .customSelect(
          '''
      SELECT recurrence, start_date, end_exclusive, weekday_mask
      FROM habit_schedules WHERE habit_version_id = ?
      ''',
          variables: [Variable<String>(proposal.versionId)],
        )
        .getSingleOrNull();

    final lifecycleRows = await _db
        .customSelect(
          '''
      SELECT id, effective_date, previous_state, state, reason, created_at_utc_us
      FROM habit_lifecycle_events
      WHERE habit_id = ?
      ORDER BY effective_date ASC, id ASC
      ''',
          variables: [Variable<String>(proposal.habitId)],
        )
        .get();

    final occurrenceRows = await _db
        .customSelect(
          '''
      SELECT id, local_date, target_count, unit
      FROM habit_occurrences
      WHERE habit_version_id = ?
      ORDER BY local_date ASC, id ASC
      ''',
          variables: [Variable<String>(proposal.versionId)],
        )
        .get();

    final impacts = <CounterCorrectionOccurrenceImpact>[];
    final occurrenceSnapshotList = <Map<String, Object?>>[];
    var totalEvents = 0;
    var totalResolutions = 0;
    var totalRecoveries = 0;

    for (final occ in occurrenceRows) {
      final occId = occ.read<String>('id');
      final occDateStr = occ.read<String>('local_date');
      final occTarget = occ.read<int>('target_count');
      final occUnit = occ.read<String>('unit');

      final eventRows = await _db
          .customSelect(
            '''
        SELECT id, quantity, occurred_at_utc_us
        FROM habit_counter_events
        WHERE occurrence_id = ?
        ORDER BY occurred_at_utc_us ASC, id ASC
        ''',
            variables: [Variable<String>(occId)],
          )
          .get();
      final quantities = [
        for (final row in eventRows) row.read<int>('quantity'),
      ];
      final originalProgress = CounterProgress.fromEvents(
        target: occTarget,
        quantities: quantities,
      );
      final proposedProgress = CounterProgress.fromEvents(
        target: proposedTarget.count,
        quantities: quantities,
      );

      final resRow = await _db
          .customSelect(
            '''
        SELECT id, state, reason, target_count, progress_total, occurred_at_utc_us
        FROM habit_counter_resolutions
        WHERE occurrence_id = ?
        ''',
            variables: [Variable<String>(occId)],
          )
          .getSingleOrNull();

      final recRows = await _db
          .customSelect(
            '''
        SELECT id, recovery_local_date, quantity, original_target_count,
               original_progress_total, remaining_deficit, note, occurred_at_utc_us
        FROM habit_counter_recoveries
        WHERE occurrence_id = ?
        ORDER BY occurred_at_utc_us ASC, id ASC
        ''',
            variables: [Variable<String>(occId)],
          )
          .get();

      if (resRow != null) {
        if (proposedProgress.status == CounterProgressStatus.completed) {
          throw StateError(
            'Proposed target ${proposedTarget.count} would make resolved occurrence $occId on $occDateStr completed',
          );
        }
        final recoveredSum = recRows.fold<int>(
          0,
          (sum, r) => sum + r.read<int>('quantity'),
        );
        final proposedDeficit = proposedTarget.count - originalProgress.total;
        if (recoveredSum > proposedDeficit) {
          throw StateError(
            'Proposed target ${proposedTarget.count} would reduce deficit on $occDateStr below already recovered quantity $recoveredSum',
          );
        }
      }

      totalEvents += eventRows.length;
      if (resRow != null) totalResolutions += 1;
      totalRecoveries += recRows.length;

      impacts.add(
        CounterCorrectionOccurrenceImpact(
          occurrenceId: occId,
          date: _parseDate(occDateStr),
          originalTarget: occTarget,
          proposedTarget: proposedTarget.count,
          recordedTotal: originalProgress.total,
          eventCount: eventRows.length,
          originalProgressStatus: originalProgress.status,
          proposedProgressStatus: proposedProgress.status,
          hasResolution: resRow != null,
          recoveryCount: recRows.length,
        ),
      );

      occurrenceSnapshotList.add({
        'id': occId,
        'local_date': occDateStr,
        'target_count': occTarget,
        'unit': occUnit,
        'events': [
          for (final e in eventRows)
            {
              'id': e.read<String>('id'),
              'quantity': e.read<int>('quantity'),
              'occurred_at_utc_us': e.read<int>('occurred_at_utc_us'),
            },
        ],
        'resolution': resRow == null
            ? null
            : {
                'id': resRow.read<String>('id'),
                'state': resRow.read<String>('state'),
                'reason': resRow.readNullable<String>('reason'),
                'target_count': resRow.read<int>('target_count'),
                'progress_total': resRow.read<int>('progress_total'),
                'occurred_at_utc_us': resRow.read<int>('occurred_at_utc_us'),
              },
        'recoveries': [
          for (final r in recRows)
            {
              'id': r.read<String>('id'),
              'recovery_local_date': r.read<String>('recovery_local_date'),
              'quantity': r.read<int>('quantity'),
              'original_target_count': r.read<int>('original_target_count'),
              'original_progress_total': r.read<int>('original_progress_total'),
              'remaining_deficit': r.read<int>('remaining_deficit'),
              'note': r.readNullable<String>('note'),
              'occurred_at_utc_us': r.read<int>('occurred_at_utc_us'),
            },
        ],
      });
    }

    final snapshotSignature = jsonEncode({
      'preview_date': _dateKey(today),
      'habit_id': proposal.habitId,
      'version': {
        'id': versionRow.read<String>('id'),
        'name': versionName,
        'effective_start': startStr,
        'effective_end': endStr,
        'revision': versionRow.read<int>('revision'),
        'target_count': existingCount,
        'unit': existingUnit,
      },
      'schedule': scheduleRow == null
          ? null
          : {
              'recurrence': scheduleRow.read<String>('recurrence'),
              'start_date': scheduleRow.read<String>('start_date'),
              'end_exclusive': scheduleRow.readNullable<String>(
                'end_exclusive',
              ),
              'weekday_mask': scheduleRow.readNullable<int>('weekday_mask'),
            },
      'lifecycle': [
        for (final l in lifecycleRows)
          {
            'id': l.read<String>('id'),
            'effective_date': l.read<String>('effective_date'),
            'previous_state': l.readNullable<String>('previous_state'),
            'state': l.read<String>('state'),
            'reason': l.readNullable<String>('reason'),
            'created_at_utc_us': l.read<int>('created_at_utc_us'),
          },
      ],
      'occurrences': occurrenceSnapshotList,
      'proposed_target_count': proposedTarget.count,
      'proposed_unit': proposedTarget.unit,
    });

    final rangeLabel = endStr == null
        ? '[$startStr, unbounded)'
        : '[$startStr, $endStr)';
    final summary =
        'Confirm historical counter target correction for "$versionName" '
        'over $rangeLabel: ${originalTarget.count} ${originalTarget.unit} -> '
        '${proposedTarget.count} ${proposedTarget.unit}. '
        'Affected records: ${impacts.length} occurrences, $totalEvents events, '
        '$totalResolutions resolutions, $totalRecoveries recoveries. '
        'Derived score, streak, reward and achievement recalculation engines are not yet implemented.';

    return CounterCorrectionPreview(
      proposal: proposal,
      previewedOnLocalDate: today,
      versionName: versionName,
      effectiveStart: effectiveStart,
      effectiveEnd: effectiveEnd,
      originalTarget: originalTarget,
      proposedTarget: proposedTarget,
      affectedOccurrences: List.unmodifiable(impacts),
      totalAffectedEventCount: totalEvents,
      totalAffectedResolutionCount: totalResolutions,
      totalAffectedRecoveryCount: totalRecoveries,
      scoreImpact: CounterDerivedImpactAvailability.notImplemented,
      streakImpact: CounterDerivedImpactAvailability.notImplemented,
      rewardImpact: CounterDerivedImpactAvailability.notImplemented,
      achievementImpact: CounterDerivedImpactAvailability.notImplemented,
      englishConfirmationSummary: summary,
      snapshotSignature: snapshotSignature,
    );
  }
}

LocalDate _currentLocalDate(DateTime instant) {
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
