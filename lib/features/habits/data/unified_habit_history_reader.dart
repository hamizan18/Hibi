import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/avoidance_habit.dart';
import '../domain/boolean_duration_habit.dart';
import '../domain/checklist_habit.dart';
import '../domain/counter_day_status.dart';
import '../domain/habit_analytics.dart';
import '../domain/habit_metadata.dart';
import '../domain/habit_schedule.dart';
import 'counter_day_reader.dart';
import 'habit_lifecycle.dart';
import 'habit_metadata_store.dart';
import 'unified_habit_registry.dart';

/// Read-only multi-type habit history evaluator.
/// Evaluates all stored habits across all eight tracking types over a single
/// local date or inclusive date range inside one read transaction with zero writes.
class UnifiedHabitHistoryReader {
  const UnifiedHabitHistoryReader(this._db);

  final AppDatabase _db;

  Future<List<UnifiedHabitDayEvaluation>> readDay({
    required LocalDate date,
    HabitAnalyticsFilter filter = const HabitAnalyticsFilter(
      includePrivate: true,
    ),
  }) => _db.transaction(() async {
    final all = await _evaluateDayInternal(date);
    return filter.apply(all);
  });

  Future<Map<LocalDate, List<UnifiedHabitDayEvaluation>>> readRange({
    required LocalDate startInclusive,
    required LocalDate endInclusive,
    HabitAnalyticsFilter filter = const HabitAnalyticsFilter(
      includePrivate: true,
    ),
  }) => _db.transaction(() async {
    if (endInclusive.compareTo(startInclusive) < 0) {
      throw ArgumentError('endInclusive must not precede startInclusive');
    }
    final result = <LocalDate, List<UnifiedHabitDayEvaluation>>{};
    var cursor = startInclusive;
    while (cursor.compareTo(endInclusive) <= 0) {
      final evals = await _evaluateDayInternal(cursor);
      result[cursor] = filter.apply(evals);
      cursor = _nextDay(cursor);
    }
    return Map.unmodifiable(result);
  });

  Future<List<UnifiedHabitDayEvaluation>> readHabitRange({
    required String habitId,
    required LocalDate startInclusive,
    required LocalDate endInclusive,
  }) => _db.transaction(() async {
    if (endInclusive.compareTo(startInclusive) < 0) {
      throw ArgumentError('endInclusive must not precede startInclusive');
    }
    final habitRow = await _db
        .customSelect(
          'SELECT id FROM habits WHERE id = ?',
          variables: [Variable<String>(habitId)],
        )
        .getSingleOrNull();
    if (habitRow == null) {
      throw StateError('Habit does not exist');
    }
    final list = <UnifiedHabitDayEvaluation>[];
    var cursor = startInclusive;
    while (cursor.compareTo(endInclusive) <= 0) {
      list.add(
        await _evaluateSingleHabitOnDate(habitId: habitId, date: cursor),
      );
      cursor = _nextDay(cursor);
    }
    return List.unmodifiable(list);
  });

  Future<LocalDate?> findEarliestVersionStart(String habitId) async {
    final row = await _db
        .customSelect(
          '''
      SELECT effective_start
      FROM habit_versions
      WHERE habit_id = ?
      ORDER BY effective_start ASC
      LIMIT 1
      ''',
          variables: [Variable<String>(habitId)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    return _parseDate(row.read<String>('effective_start'));
  }

  Future<List<UnifiedHabitDayEvaluation>> _evaluateDayInternal(
    LocalDate date,
  ) async {
    final habits = await _db
        .customSelect(
          'SELECT id FROM habits ORDER BY created_at_utc_us ASC, id ASC',
        )
        .get();
    final results = <UnifiedHabitDayEvaluation>[];
    for (final row in habits) {
      results.add(
        await _evaluateSingleHabitOnDate(
          habitId: row.read<String>('id'),
          date: date,
        ),
      );
    }
    return List.unmodifiable(results);
  }

  Future<UnifiedHabitDayEvaluation> _evaluateSingleHabitOnDate({
    required String habitId,
    required LocalDate date,
  }) async {
    final dateKey = _dateKey(date);
    final applicability = await HabitApplicabilityReader(_db)
        .describe(habitId, date);

    final versionRow =
        applicability.reason == HabitApplicabilityReason.beforeStart
        ? await _db
              .customSelect(
                'SELECT id, name FROM habit_versions WHERE habit_id = ? ORDER BY effective_start ASC LIMIT 1',
                variables: [Variable<String>(habitId)],
              )
              .getSingleOrNull()
        : await _db
              .customSelect(
                '''
          SELECT id, name
          FROM habit_versions
          WHERE habit_id = ? AND effective_start <= ?
            AND (effective_end IS NULL OR ? < effective_end)
          ''',
                variables: [
                  Variable<String>(habitId),
                  Variable<String>(dateKey),
                  Variable<String>(dateKey),
                ],
              )
              .getSingleOrNull();

    final versionId = versionRow?.read<String>('id');
    final name = versionRow?.read<String>('name') ?? 'Unconfigured habit';
    final metadata = versionId == null
        ? null
        : await HabitMetadataStore(_db).findForVersion(versionId);
    final hasMetadata = metadata != null;
    final priority = metadata?.priority ?? HabitPriority.normal;
    final category = metadata?.category ?? 'Unclassified';
    final symbol = metadata?.symbol;
    final isPrivate = metadata?.isPrivate ?? false;
    final includeInScore = metadata?.includeInScore ?? true;
    final includeInStreak = metadata?.includeInStreak ?? true;

    final trackingType = versionId == null
        ? HabitTrackingType.unconfigured
        : await _detectTrackingType(versionId);

    switch (trackingType) {
      case HabitTrackingType.counter:
        return _evalCounter(
          habitId: habitId,
          versionId: versionId,
          name: name,
          date: date,
          applicability: applicability,
          priority: priority,
          category: category,
          symbol: symbol,
          isPrivate: isPrivate,
          includeInScore: includeInScore,
          includeInStreak: includeInStreak,
          hasMetadata: hasMetadata,
        );
      case HabitTrackingType.checklist:
        return _evalChecklist(
          habitId: habitId,
          versionId: versionId!,
          name: name,
          date: date,
          dateKey: dateKey,
          applicability: applicability,
          priority: priority,
          category: category,
          symbol: symbol,
          isPrivate: isPrivate,
          includeInScore: includeInScore,
          includeInStreak: includeInStreak,
          hasMetadata: hasMetadata,
        );
      case HabitTrackingType.avoidance:
        return _evalAvoidance(
          habitId: habitId,
          versionId: versionId!,
          name: name,
          date: date,
          dateKey: dateKey,
          applicability: applicability,
          priority: priority,
          category: category,
          symbol: symbol,
          isPrivate: isPrivate,
          includeInScore: includeInScore,
          includeInStreak: includeInStreak,
          hasMetadata: hasMetadata,
        );
      case HabitTrackingType.boolean ||
          HabitTrackingType.duration ||
          HabitTrackingType.measurement ||
          HabitTrackingType.timeOfDay ||
          HabitTrackingType.range:
        return _evalTyped(
          habitId: habitId,
          versionId: versionId!,
          name: name,
          date: date,
          dateKey: dateKey,
          trackingType: trackingType,
          applicability: applicability,
          priority: priority,
          category: category,
          symbol: symbol,
          isPrivate: isPrivate,
          includeInScore: includeInScore,
          includeInStreak: includeInStreak,
          hasMetadata: hasMetadata,
        );
      case HabitTrackingType.unconfigured:
        final baseStatus = switch (applicability.applicability) {
          HabitApplicability.notApplicable =>
            HabitAnalyticsStatus.notApplicable,
          HabitApplicability.applicable ||
          HabitApplicability.unknown => HabitAnalyticsStatus.unknown,
        };
        return UnifiedHabitDayEvaluation(
          habitId: habitId,
          versionId: versionId,
          name: name,
          date: date,
          trackingType: HabitTrackingType.unconfigured,
          status: baseStatus,
          applicabilityReason: applicability.reason,
          priority: priority,
          category: category,
          symbol: symbol,
          isPrivate: isPrivate,
          includeInScore: includeInScore,
          includeInStreak: includeInStreak,
          hasMetadata: hasMetadata,
          partialRatio: 0.0,
          summaryText: baseStatus.name,
          hasOccurrence: false,
        );
    }
  }

  Future<UnifiedHabitDayEvaluation> _evalCounter({
    required String habitId,
    required String? versionId,
    required String name,
    required LocalDate date,
    required HabitApplicabilityDetail applicability,
    required HabitPriority priority,
    required String category,
    required String? symbol,
    required bool isPrivate,
    required bool includeInScore,
    required bool includeInStreak,
    required bool hasMetadata,
  }) async {
    final counterEval = await CounterDayReader(_db)
        .evaluate(habitId: habitId, date: date);
    final status = switch (counterEval.effectiveStatus) {
      CounterDayEffectiveStatus.notApplicable =>
        HabitAnalyticsStatus.notApplicable,
      CounterDayEffectiveStatus.unknown => HabitAnalyticsStatus.unknown,
      CounterDayEffectiveStatus.pending => HabitAnalyticsStatus.pending,
      CounterDayEffectiveStatus.partial => HabitAnalyticsStatus.partial,
      CounterDayEffectiveStatus.completed => HabitAnalyticsStatus.completed,
      CounterDayEffectiveStatus.failed => HabitAnalyticsStatus.failed,
      CounterDayEffectiveStatus.recovered => HabitAnalyticsStatus.recovered,
      CounterDayEffectiveStatus.excused => HabitAnalyticsStatus.excused,
      CounterDayEffectiveStatus.conflict => HabitAnalyticsStatus.conflict,
    };

    var partialRatio = 0.0;
    String summary;
    final rec = counterEval.day.recorded;
    if (rec != null) {
      partialRatio = (rec.progress.total / rec.progress.target).clamp(0.0, 1.0);
      final recov = counterEval.recovery;
      summary = recov != null && recov.recoveredTotal > 0
          ? '${rec.progress.total}/${rec.progress.target} ${rec.unit} (+${recov.recoveredTotal} recovered)'
          : '${rec.progress.total}/${rec.progress.target} ${rec.unit}';
    } else if (counterEval.configuredTarget != null) {
      summary =
          '0/${counterEval.configuredTarget!.count} ${counterEval.configuredTarget!.unit}';
    } else {
      summary = status.name;
    }

    return UnifiedHabitDayEvaluation(
      habitId: habitId,
      versionId: versionId,
      name: name,
      date: date,
      trackingType: HabitTrackingType.counter,
      status: status,
      applicabilityReason: applicability.reason,
      priority: priority,
      category: category,
      symbol: symbol,
      isPrivate: isPrivate,
      includeInScore: includeInScore,
      includeInStreak: includeInStreak,
      hasMetadata: hasMetadata,
      partialRatio: partialRatio,
      summaryText: summary,
      hasOccurrence: counterEval.hasOccurrence,
    );
  }

  Future<UnifiedHabitDayEvaluation> _evalChecklist({
    required String habitId,
    required String versionId,
    required String name,
    required LocalDate date,
    required String dateKey,
    required HabitApplicabilityDetail applicability,
    required HabitPriority priority,
    required String category,
    required String? symbol,
    required bool isPrivate,
    required bool includeInScore,
    required bool includeInStreak,
    required bool hasMetadata,
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
    final definitions = [
      for (final row in itemRows)
        ChecklistItemDefinition(
          id: row.read<String>('id'),
          label: row.read<String>('label'),
          displayOrder: row.read<int>('display_order'),
          recoveryEnabled: row.read<int>('recovery_enabled') == 1,
        ),
    ];

    final occRow = await _db
        .customSelect(
          'SELECT id FROM habit_checklist_occurrences WHERE habit_id = ? AND local_date = ?',
          variables: [Variable<String>(habitId), Variable<String>(dateKey)],
        )
        .getSingleOrNull();

    if (applicability.applicability == HabitApplicability.notApplicable) {
      return UnifiedHabitDayEvaluation(
        habitId: habitId,
        versionId: versionId,
        name: name,
        date: date,
        trackingType: HabitTrackingType.checklist,
        status: occRow != null
            ? HabitAnalyticsStatus.conflict
            : HabitAnalyticsStatus.notApplicable,
        applicabilityReason: applicability.reason,
        priority: priority,
        category: category,
        symbol: symbol,
        isPrivate: isPrivate,
        includeInScore: includeInScore,
        includeInStreak: includeInStreak,
        hasMetadata: hasMetadata,
        partialRatio: 0.0,
        summaryText: occRow != null ? 'conflict' : 'notApplicable',
        hasOccurrence: occRow != null,
      );
    }

    if (applicability.applicability == HabitApplicability.unknown ||
        definitions.isEmpty) {
      return UnifiedHabitDayEvaluation(
        habitId: habitId,
        versionId: versionId,
        name: name,
        date: date,
        trackingType: HabitTrackingType.checklist,
        status: occRow != null
            ? HabitAnalyticsStatus.conflict
            : HabitAnalyticsStatus.unknown,
        applicabilityReason: applicability.reason,
        priority: priority,
        category: category,
        symbol: symbol,
        isPrivate: isPrivate,
        includeInScore: includeInScore,
        includeInStreak: includeInStreak,
        hasMetadata: hasMetadata,
        partialRatio: 0.0,
        summaryText: 'unknown',
        hasOccurrence: occRow != null,
      );
    }

    if (occRow == null) {
      return UnifiedHabitDayEvaluation(
        habitId: habitId,
        versionId: versionId,
        name: name,
        date: date,
        trackingType: HabitTrackingType.checklist,
        status: HabitAnalyticsStatus.pending,
        applicabilityReason: applicability.reason,
        priority: priority,
        category: category,
        symbol: symbol,
        isPrivate: isPrivate,
        includeInScore: includeInScore,
        includeInStreak: includeInStreak,
        hasMetadata: hasMetadata,
        partialRatio: 0.0,
        summaryText: '0/${definitions.length} items',
        hasOccurrence: false,
        checklistCounts: ChecklistCoverageCounts(
          totalItems: definitions.length,
          recordedItems: 0,
          completedItems: 0,
          recoveredItems: 0,
          failedItems: 0,
          excusedItems: 0,
          pendingItems: definitions.length,
        ),
      );
    }

    final occId = occRow.read<String>('id');
    final logRows = await _db
        .customSelect(
          'SELECT item_id, state FROM habit_checklist_item_logs WHERE occurrence_id = ?',
          variables: [Variable<String>(occId)],
        )
        .get();
    final loggedStates = <String, ChecklistItemLogState>{
      for (final row in logRows)
        row.read<String>('item_id'): ChecklistItemLogState.values.byName(
          row.read<String>('state'),
        ),
    };
    final recRows = await _db
        .customSelect(
          'SELECT item_id FROM habit_checklist_item_recoveries WHERE occurrence_id = ?',
          variables: [Variable<String>(occId)],
        )
        .get();
    final recoveredIds = <String>{
      for (final row in recRows) row.read<String>('item_id'),
    };
    final progress = ChecklistDayProgress.evaluate(
      definitions: definitions,
      loggedStates: loggedStates,
      recoveredItemIds: recoveredIds,
    );

    final status = switch (progress.status) {
      ChecklistOccurrenceStatus.pending => HabitAnalyticsStatus.pending,
      ChecklistOccurrenceStatus.partial => HabitAnalyticsStatus.partial,
      ChecklistOccurrenceStatus.completed => HabitAnalyticsStatus.completed,
      ChecklistOccurrenceStatus.failed => HabitAnalyticsStatus.failed,
      ChecklistOccurrenceStatus.recovered => HabitAnalyticsStatus.recovered,
      ChecklistOccurrenceStatus.excused => HabitAnalyticsStatus.excused,
    };
    final total = definitions.length;
    final activeDenominator = total - progress.excusedCount;
    final partialRatio = activeDenominator > 0
        ? ((progress.completedCount + 0.75 * progress.recoveredCount) /
                  activeDenominator)
              .clamp(0.0, 1.0)
        : 0.0;
    final recordedItems = total - progress.pendingCount;

    return UnifiedHabitDayEvaluation(
      habitId: habitId,
      versionId: versionId,
      name: name,
      date: date,
      trackingType: HabitTrackingType.checklist,
      status: status,
      applicabilityReason: applicability.reason,
      priority: priority,
      category: category,
      symbol: symbol,
      isPrivate: isPrivate,
      includeInScore: includeInScore,
      includeInStreak: includeInStreak,
      hasMetadata: hasMetadata,
      partialRatio: partialRatio,
      summaryText:
          '${progress.completedCount + progress.recoveredCount}/$total items',
      hasOccurrence: true,
      checklistCounts: ChecklistCoverageCounts(
        totalItems: total,
        recordedItems: recordedItems,
        completedItems: progress.completedCount,
        recoveredItems: progress.recoveredCount,
        failedItems: progress.failedCount,
        excusedItems: progress.excusedCount,
        pendingItems: progress.pendingCount,
      ),
    );
  }

  Future<UnifiedHabitDayEvaluation> _evalAvoidance({
    required String habitId,
    required String versionId,
    required String name,
    required LocalDate date,
    required String dateKey,
    required HabitApplicabilityDetail applicability,
    required HabitPriority priority,
    required String category,
    required String? symbol,
    required bool isPrivate,
    required bool includeInScore,
    required bool includeInStreak,
    required bool hasMetadata,
  }) async {
    final targetRow = await _db
        .customSelect(
          'SELECT max_incidents FROM habit_avoidance_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    final occRow = await _db
        .customSelect(
          'SELECT id, max_incidents FROM habit_avoidance_occurrences WHERE habit_id = ? AND local_date = ?',
          variables: [Variable<String>(habitId), Variable<String>(dateKey)],
        )
        .getSingleOrNull();

    if (applicability.applicability == HabitApplicability.notApplicable) {
      return UnifiedHabitDayEvaluation(
        habitId: habitId,
        versionId: versionId,
        name: name,
        date: date,
        trackingType: HabitTrackingType.avoidance,
        status: occRow != null
            ? HabitAnalyticsStatus.conflict
            : HabitAnalyticsStatus.notApplicable,
        applicabilityReason: applicability.reason,
        priority: priority,
        category: category,
        symbol: symbol,
        isPrivate: isPrivate,
        includeInScore: includeInScore,
        includeInStreak: includeInStreak,
        hasMetadata: hasMetadata,
        partialRatio: 0.0,
        summaryText: 'notApplicable',
        hasOccurrence: occRow != null,
      );
    }

    if (applicability.applicability == HabitApplicability.unknown ||
        targetRow == null) {
      return UnifiedHabitDayEvaluation(
        habitId: habitId,
        versionId: versionId,
        name: name,
        date: date,
        trackingType: HabitTrackingType.avoidance,
        status: occRow != null
            ? HabitAnalyticsStatus.conflict
            : HabitAnalyticsStatus.unknown,
        applicabilityReason: applicability.reason,
        priority: priority,
        category: category,
        symbol: symbol,
        isPrivate: isPrivate,
        includeInScore: includeInScore,
        includeInStreak: includeInStreak,
        hasMetadata: hasMetadata,
        partialRatio: 0.0,
        summaryText: 'unknown',
        hasOccurrence: occRow != null,
      );
    }

    if (occRow == null) {
      final maxInc = targetRow.read<int>('max_incidents');
      return UnifiedHabitDayEvaluation(
        habitId: habitId,
        versionId: versionId,
        name: name,
        date: date,
        trackingType: HabitTrackingType.avoidance,
        status: HabitAnalyticsStatus.pending,
        applicabilityReason: applicability.reason,
        priority: priority,
        category: category,
        symbol: symbol,
        isPrivate: isPrivate,
        includeInScore: includeInScore,
        includeInStreak: includeInStreak,
        hasMetadata: hasMetadata,
        partialRatio: 0.0,
        summaryText: '0/$maxInc incidents (unconfirmed)',
        hasOccurrence: false,
      );
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
      _ => null,
    };
    final progress = AvoidanceDayProgress.evaluate(
      maxIncidents: maxIncidents,
      incidentCount: incidentCount,
      resolution: resolution,
    );
    final status = switch (progress.status) {
      AvoidanceEffectiveStatus.pending => HabitAnalyticsStatus.pending,
      AvoidanceEffectiveStatus.completed => HabitAnalyticsStatus.completed,
      AvoidanceEffectiveStatus.failed => HabitAnalyticsStatus.failed,
      AvoidanceEffectiveStatus.excused => HabitAnalyticsStatus.excused,
    };

    return UnifiedHabitDayEvaluation(
      habitId: habitId,
      versionId: versionId,
      name: name,
      date: date,
      trackingType: HabitTrackingType.avoidance,
      status: status,
      applicabilityReason: applicability.reason,
      priority: priority,
      category: category,
      symbol: symbol,
      isPrivate: isPrivate,
      includeInScore: includeInScore,
      includeInStreak: includeInStreak,
      hasMetadata: hasMetadata,
      partialRatio: 0.0,
      summaryText: '$incidentCount/$maxIncidents incidents',
      hasOccurrence: true,
    );
  }

  Future<UnifiedHabitDayEvaluation> _evalTyped({
    required String habitId,
    required String versionId,
    required String name,
    required LocalDate date,
    required String dateKey,
    required HabitTrackingType trackingType,
    required HabitApplicabilityDetail applicability,
    required HabitPriority priority,
    required String category,
    required String? symbol,
    required bool isPrivate,
    required bool includeInScore,
    required bool includeInStreak,
    required bool hasMetadata,
  }) async {
    final targetRow = await _db
        .customSelect(
          'SELECT * FROM habit_typed_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    final occRow = await _db
        .customSelect(
          'SELECT id, tracking_type FROM habit_typed_occurrences WHERE habit_id = ? AND local_date = ?',
          variables: [Variable<String>(habitId), Variable<String>(dateKey)],
        )
        .getSingleOrNull();

    if (applicability.applicability == HabitApplicability.notApplicable) {
      return UnifiedHabitDayEvaluation(
        habitId: habitId,
        versionId: versionId,
        name: name,
        date: date,
        trackingType: trackingType,
        status: occRow != null
            ? HabitAnalyticsStatus.conflict
            : HabitAnalyticsStatus.notApplicable,
        applicabilityReason: applicability.reason,
        priority: priority,
        category: category,
        symbol: symbol,
        isPrivate: isPrivate,
        includeInScore: includeInScore,
        includeInStreak: includeInStreak,
        hasMetadata: hasMetadata,
        partialRatio: 0.0,
        summaryText: 'notApplicable',
        hasOccurrence: occRow != null,
      );
    }

    if (applicability.applicability == HabitApplicability.unknown ||
        targetRow == null) {
      return UnifiedHabitDayEvaluation(
        habitId: habitId,
        versionId: versionId,
        name: name,
        date: date,
        trackingType: trackingType,
        status: occRow != null
            ? HabitAnalyticsStatus.conflict
            : HabitAnalyticsStatus.unknown,
        applicabilityReason: applicability.reason,
        priority: priority,
        category: category,
        symbol: symbol,
        isPrivate: isPrivate,
        includeInScore: includeInScore,
        includeInStreak: includeInStreak,
        hasMetadata: hasMetadata,
        partialRatio: 0.0,
        summaryText: 'unknown',
        hasOccurrence: occRow != null,
      );
    }

    if (occRow == null) {
      return UnifiedHabitDayEvaluation(
        habitId: habitId,
        versionId: versionId,
        name: name,
        date: date,
        trackingType: trackingType,
        status: HabitAnalyticsStatus.pending,
        applicabilityReason: applicability.reason,
        priority: priority,
        category: category,
        symbol: symbol,
        isPrivate: isPrivate,
        includeInScore: includeInScore,
        includeInStreak: includeInStreak,
        hasMetadata: hasMetadata,
        partialRatio: 0.0,
        summaryText: 'pending',
        hasOccurrence: false,
      );
    }

    final occId = occRow.read<String>('id');
    if (trackingType == HabitTrackingType.duration) {
      final targetSeconds = targetRow.read<int>('target_seconds');
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
      final progress = DurationDayProgress.evaluate(
        targetSeconds: targetSeconds,
        entrySeconds: [
          for (final r in eventRows) r.read<int>('duration_seconds'),
        ],
        explicitResolution: resState,
      );
      final status = switch (progress.status) {
        DurationEffectiveStatus.pending => HabitAnalyticsStatus.pending,
        DurationEffectiveStatus.partial => HabitAnalyticsStatus.partial,
        DurationEffectiveStatus.completed => HabitAnalyticsStatus.completed,
        DurationEffectiveStatus.failed => HabitAnalyticsStatus.failed,
        DurationEffectiveStatus.excused => HabitAnalyticsStatus.excused,
      };
      final ratio = (progress.totalSeconds / targetSeconds).clamp(0.0, 1.0);
      return UnifiedHabitDayEvaluation(
        habitId: habitId,
        versionId: versionId,
        name: name,
        date: date,
        trackingType: trackingType,
        status: status,
        applicabilityReason: applicability.reason,
        priority: priority,
        category: category,
        symbol: symbol,
        isPrivate: isPrivate,
        includeInScore: includeInScore,
        includeInStreak: includeInStreak,
        hasMetadata: hasMetadata,
        partialRatio: ratio,
        summaryText: '${progress.totalSeconds}/${progress.targetSeconds}s',
        hasOccurrence: true,
      );
    }

    final logRow = await _db
        .customSelect(
          'SELECT state FROM habit_typed_logs WHERE occurrence_id = ?',
          variables: [Variable<String>(occId)],
        )
        .getSingleOrNull();
    if (logRow == null) {
      return UnifiedHabitDayEvaluation(
        habitId: habitId,
        versionId: versionId,
        name: name,
        date: date,
        trackingType: trackingType,
        status: HabitAnalyticsStatus.pending,
        applicabilityReason: applicability.reason,
        priority: priority,
        category: category,
        symbol: symbol,
        isPrivate: isPrivate,
        includeInScore: includeInScore,
        includeInStreak: includeInStreak,
        hasMetadata: hasMetadata,
        partialRatio: 0.0,
        summaryText: 'pending',
        hasOccurrence: true,
      );
    }
    final stateStr = logRow.read<String>('state');
    final status = switch (stateStr) {
      'completed' => HabitAnalyticsStatus.completed,
      'partial' => HabitAnalyticsStatus.partial,
      'failed' => HabitAnalyticsStatus.failed,
      'excused' => HabitAnalyticsStatus.excused,
      _ => HabitAnalyticsStatus.unknown,
    };
    return UnifiedHabitDayEvaluation(
      habitId: habitId,
      versionId: versionId,
      name: name,
      date: date,
      trackingType: trackingType,
      status: status,
      applicabilityReason: applicability.reason,
      priority: priority,
      category: category,
      symbol: symbol,
      isPrivate: isPrivate,
      includeInScore: includeInScore,
      includeInStreak: includeInStreak,
      hasMetadata: hasMetadata,
      partialRatio: status == HabitAnalyticsStatus.partial ? 0.5 : 0.0,
      summaryText: status.name,
      hasOccurrence: true,
    );
  }

  Future<HabitTrackingType> _detectTrackingType(String versionId) async {
    final counter = await _db
        .customSelect(
          'SELECT 1 FROM habit_counter_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (counter != null) return HabitTrackingType.counter;

    final checklist = await _db
        .customSelect(
          'SELECT 1 FROM habit_checklist_items WHERE habit_version_id = ? LIMIT 1',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (checklist != null) return HabitTrackingType.checklist;

    final avoidance = await _db
        .customSelect(
          'SELECT 1 FROM habit_avoidance_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (avoidance != null) return HabitTrackingType.avoidance;

    final typed = await _db
        .customSelect(
          'SELECT tracking_type FROM habit_typed_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    return switch (typed?.read<String>('tracking_type')) {
      'boolean' => HabitTrackingType.boolean,
      'duration' => HabitTrackingType.duration,
      'measurement' => HabitTrackingType.measurement,
      'time_of_day' => HabitTrackingType.timeOfDay,
      'range' => HabitTrackingType.range,
      _ => HabitTrackingType.unconfigured,
    };
  }
}

LocalDate _nextDay(LocalDate d) {
  final next = DateTime.utc(d.year, d.month, d.day + 1);
  return LocalDate(next.year, next.month, next.day);
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

LocalDate _parseDate(String value) => LocalDate(
  int.parse(value.substring(0, 4)),
  int.parse(value.substring(5, 7)),
  int.parse(value.substring(8, 10)),
);
