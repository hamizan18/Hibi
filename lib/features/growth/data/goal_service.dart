import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../../habits/data/unified_habit_history_reader.dart';
import '../../habits/domain/habit_analytics.dart';
import '../../habits/domain/habit_schedule.dart';
import '../domain/goal_models.dart';

/// Result of attempting to synchronize linked habit progress into a goal.
class LinkedHabitProgressSyncResult {
  const LinkedHabitProgressSyncResult({
    required this.recorded,
    required this.alreadyRecorded,
    required this.reason,
    this.entry,
  });

  final bool recorded;
  final bool alreadyRecorded;
  final String reason;
  final GoalProgressEntry? entry;
}

/// Transactional store for Goals, Milestones, Linked Habits, Status History
/// and deduplicated manual/linked Goal Progress.
class GoalService {
  const GoalService(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<Goal> createGoal({
    required String id,
    required String title,
    String? description,
    GoalStatus status = GoalStatus.planned,
    LocalDate? targetDate,
    int? targetUnits,
    String? unitLabel,
    bool isPrivate = false,
    String? statusReason,
  }) => _db.transaction(() async {
    final nowUtc = _clock.now().toUtc();
    final goal = Goal(
      id: id,
      title: title,
      description: description,
      status: status,
      targetDate: targetDate,
      targetUnits: targetUnits,
      unitLabel: unitLabel,
      isPrivate: isPrivate,
      createdAtUtc: nowUtc,
      updatedAtUtc: nowUtc,
    );
    final nowUs = nowUtc.microsecondsSinceEpoch;
    await _db.customStatement(
      '''
      INSERT INTO goals (
        id, title, description, status, target_date, target_units,
        unit_label, is_private, created_at_utc_us, updated_at_utc_us
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        goal.id,
        goal.title,
        goal.description,
        goal.status.storageKey,
        goal.targetDate == null ? null : _dateKey(goal.targetDate!),
        goal.targetUnits,
        goal.unitLabel,
        goal.isPrivate ? 1 : 0,
        nowUs,
        nowUs,
      ],
    );
    await _db.customStatement(
      '''
      INSERT INTO goal_status_history (
        id, goal_id, previous_status, new_status, reason, occurred_at_utc_us
      )
      VALUES (?, ?, NULL, ?, ?, ?)
      ''',
      [
        'gsh_${goal.id}_init_$nowUs',
        goal.id,
        goal.status.storageKey,
        _cleanOptional(statusReason),
        nowUs,
      ],
    );
    return goal;
  });

  Future<Goal> updateGoalStatus({
    required String goalId,
    required GoalStatus newStatus,
    String? reason,
  }) => _db.transaction(() async {
    final existing = await _readGoalRow(goalId);
    if (existing == null) {
      throw StateError('Goal not found: $goalId');
    }
    final previous = GoalStatus.fromStorageKey(existing.read<String>('status'));
    if (previous == newStatus) {
      return _mapGoal(existing);
    }
    final nowUtc = _clock.now().toUtc();
    final nowUs = nowUtc.microsecondsSinceEpoch;
    await _db.customStatement(
      '''
      UPDATE goals
      SET status = ?, updated_at_utc_us = ?
      WHERE id = ?
      ''',
      [newStatus.storageKey, nowUs, goalId.trim()],
    );
    final countRow = await _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM goal_status_history WHERE goal_id = ?',
          variables: [Variable<String>(goalId.trim())],
        )
        .getSingle();
    final seq = countRow.read<int>('c') + 1;
    await _db.customStatement(
      '''
      INSERT INTO goal_status_history (
        id, goal_id, previous_status, new_status, reason, occurred_at_utc_us
      )
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [
        'gsh_${goalId.trim()}_${seq}_$nowUs',
        goalId.trim(),
        previous.storageKey,
        newStatus.storageKey,
        _cleanOptional(reason),
        nowUs,
      ],
    );
    return _mapGoal((await _readGoalRow(goalId))!);
  });

  Future<GoalMilestone> addMilestone({
    required String id,
    required String goalId,
    required String title,
    int? sortOrder,
  }) => _db.transaction(() async {
    final existingGoal = await _readGoalRow(goalId);
    if (existingGoal == null) {
      throw StateError('Goal not found: $goalId');
    }
    final order =
        sortOrder ??
        (await _db
                .customSelect(
                  'SELECT COALESCE(MAX(sort_order), -1) + 1 AS next_order FROM goal_milestones WHERE goal_id = ?',
                  variables: [Variable<String>(goalId.trim())],
                )
                .getSingle())
            .read<int>('next_order');
    final nowUtc = _clock.now().toUtc();
    final milestone = GoalMilestone(
      id: id,
      goalId: goalId,
      title: title,
      sortOrder: order,
      isCompleted: false,
      createdAtUtc: nowUtc,
    );
    await _db.customStatement(
      '''
      INSERT INTO goal_milestones (
        id, goal_id, title, sort_order, is_completed, completed_at_utc_us, created_at_utc_us
      )
      VALUES (?, ?, ?, ?, 0, NULL, ?)
      ''',
      [
        milestone.id,
        milestone.goalId,
        milestone.title,
        milestone.sortOrder,
        nowUtc.microsecondsSinceEpoch,
      ],
    );
    return milestone;
  });

  Future<GoalMilestone> setMilestoneCompleted({
    required String milestoneId,
    required bool completed,
  }) => _db.transaction(() async {
    final row = await _db
        .customSelect(
          '''
          SELECT id, goal_id, title, sort_order, is_completed, completed_at_utc_us, created_at_utc_us
          FROM goal_milestones
          WHERE id = ?
          ''',
          variables: [Variable<String>(milestoneId.trim())],
        )
        .getSingleOrNull();
    if (row == null) {
      throw StateError('Milestone not found: $milestoneId');
    }
    final nowUtc = _clock.now().toUtc();
    final completedAtUs = completed ? nowUtc.microsecondsSinceEpoch : null;
    await _db.customStatement(
      '''
      UPDATE goal_milestones
      SET is_completed = ?, completed_at_utc_us = ?
      WHERE id = ?
      ''',
      [completed ? 1 : 0, completedAtUs, milestoneId.trim()],
    );
    await _db.customStatement(
      'UPDATE goals SET updated_at_utc_us = ? WHERE id = ?',
      [nowUtc.microsecondsSinceEpoch, row.read<String>('goal_id')],
    );
    return GoalMilestone(
      id: row.read<String>('id'),
      goalId: row.read<String>('goal_id'),
      title: row.read<String>('title'),
      sortOrder: row.read<int>('sort_order'),
      isCompleted: completed,
      completedAtUtc: completed ? nowUtc : null,
      createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        row.read<int>('created_at_utc_us'),
        isUtc: true,
      ),
    );
  });

  Future<void> linkHabit({required String goalId, required String habitId}) =>
      _db.transaction(() async {
        final goal = await _readGoalRow(goalId);
        if (goal == null) {
          throw StateError('Goal not found: $goalId');
        }
        final habit = await _db
            .customSelect(
              'SELECT id FROM habits WHERE id = ?',
              variables: [Variable<String>(habitId.trim())],
            )
            .getSingleOrNull();
        if (habit == null) {
          throw StateError('Habit not found: $habitId');
        }
        final nowUs = _clock.now().toUtc().microsecondsSinceEpoch;
        await _db.customStatement(
          '''
          INSERT OR IGNORE INTO goal_habit_links (goal_id, habit_id, created_at_utc_us)
          VALUES (?, ?, ?)
          ''',
          [goalId.trim(), habitId.trim(), nowUs],
        );
      });

  Future<void> unlinkHabit({required String goalId, required String habitId}) =>
      _db.transaction(() async {
        await _db.customStatement(
          'DELETE FROM goal_habit_links WHERE goal_id = ? AND habit_id = ?',
          [goalId.trim(), habitId.trim()],
        );
      });

  /// Records manual goal progress.
  ///
  /// When [sourceRefId] is supplied (for example when logging manual credit for
  /// a specific habit date), this checks both manual and linked entries to
  /// prevent duplicating progress already counted for the same source.
  Future<GoalProgressEntry> recordManualProgress({
    required String id,
    required String goalId,
    required LocalDate localDate,
    required int units,
    String? sourceRefId,
    String? note,
  }) => _db.transaction(() async {
    final goal = await _readGoalRow(goalId);
    if (goal == null) {
      throw StateError('Goal not found: $goalId');
    }
    final cleanRef = _cleanOptional(sourceRefId);
    if (cleanRef != null) {
      final duplicate = await _db
          .customSelect(
            '''
            SELECT id, source FROM goal_progress_entries
            WHERE goal_id = ? AND source_ref_id = ?
            ''',
            variables: [
              Variable<String>(goalId.trim()),
              Variable<String>(cleanRef),
            ],
          )
          .getSingleOrNull();
      if (duplicate != null) {
        throw StateError(
          'Progress for source reference "$cleanRef" is already recorded (${duplicate.read<String>('source')})',
        );
      }
    }
    final nowUtc = _clock.now().toUtc();
    final entry = GoalProgressEntry(
      id: id,
      goalId: goalId,
      localDate: localDate,
      units: units,
      source: GoalProgressSource.manual,
      sourceRefId: cleanRef,
      note: note,
      occurredAtUtc: nowUtc,
    );
    await _db.customStatement(
      '''
      INSERT INTO goal_progress_entries (
        id, goal_id, local_date, units, source, source_ref_id, note, occurred_at_utc_us
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        entry.id,
        entry.goalId,
        _dateKey(entry.localDate),
        entry.units,
        entry.source.storageKey,
        entry.sourceRefId,
        entry.note,
        nowUtc.microsecondsSinceEpoch,
      ],
    );
    await _db.customStatement(
      'UPDATE goals SET updated_at_utc_us = ? WHERE id = ?',
      [nowUtc.microsecondsSinceEpoch, entry.goalId],
    );
    return entry;
  });

  /// Idempotently synchronizes progress from a linked habit on [date].
  ///
  /// Only completed or recovered habit occurrences contribute linked progress,
  /// and repeated calls (or conflicting manual entries carrying the same
  /// canonical reference key) never duplicate progress.
  Future<LinkedHabitProgressSyncResult> syncLinkedHabitProgress({
    required String entryId,
    required String goalId,
    required String habitId,
    required LocalDate date,
    int units = 1,
    String? note,
  }) => _db.transaction(() async {
    if (units <= 0) {
      throw ArgumentError.value(
        units,
        'units',
        'Progress units must be positive',
      );
    }
    final link = await _db
        .customSelect(
          'SELECT 1 FROM goal_habit_links WHERE goal_id = ? AND habit_id = ?',
          variables: [
            Variable<String>(goalId.trim()),
            Variable<String>(habitId.trim()),
          ],
        )
        .getSingleOrNull();
    if (link == null) {
      throw StateError('Habit $habitId is not linked to goal $goalId');
    }

    final refKey = buildLinkedHabitProgressRef(habitId, date);
    final existing = await _db
        .customSelect(
          '''
          SELECT id, goal_id, local_date, units, source, source_ref_id, note, occurred_at_utc_us
          FROM goal_progress_entries
          WHERE goal_id = ? AND source_ref_id = ?
          ''',
          variables: [
            Variable<String>(goalId.trim()),
            Variable<String>(refKey),
          ],
        )
        .getSingleOrNull();
    if (existing != null) {
      return LinkedHabitProgressSyncResult(
        recorded: false,
        alreadyRecorded: true,
        reason: 'Progress already recorded for $refKey',
        entry: _mapProgress(existing),
      );
    }

    final evaluations = await UnifiedHabitHistoryReader(_db).readHabitRange(
      habitId: habitId.trim(),
      startInclusive: date,
      endInclusive: date,
    );
    final evaluation = evaluations.isEmpty ? null : evaluations.single;
    if (evaluation == null ||
        (evaluation.status != HabitAnalyticsStatus.completed &&
            evaluation.status != HabitAnalyticsStatus.recovered)) {
      return LinkedHabitProgressSyncResult(
        recorded: false,
        alreadyRecorded: false,
        reason:
            'Linked habit is ${evaluation?.status.name ?? 'unavailable'} on ${_dateKey(date)}',
      );
    }

    final nowUtc = _clock.now().toUtc();
    final entry = GoalProgressEntry(
      id: entryId,
      goalId: goalId,
      localDate: date,
      units: units,
      source: GoalProgressSource.linkedHabit,
      sourceRefId: refKey,
      note: note ?? 'Linked habit: ${evaluation.name}',
      occurredAtUtc: nowUtc,
    );
    await _db.customStatement(
      '''
      INSERT INTO goal_progress_entries (
        id, goal_id, local_date, units, source, source_ref_id, note, occurred_at_utc_us
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        entry.id,
        entry.goalId,
        _dateKey(entry.localDate),
        entry.units,
        entry.source.storageKey,
        entry.sourceRefId,
        entry.note,
        nowUtc.microsecondsSinceEpoch,
      ],
    );
    await _db.customStatement(
      'UPDATE goals SET updated_at_utc_us = ? WHERE id = ?',
      [nowUtc.microsecondsSinceEpoch, entry.goalId],
    );
    return LinkedHabitProgressSyncResult(
      recorded: true,
      alreadyRecorded: false,
      reason: 'Recorded linked habit progress',
      entry: entry,
    );
  });

  Future<GoalProgressSummary?> readGoalSummary(String goalId) =>
      _db.transaction(() async {
        final row = await _readGoalRow(goalId);
        if (row == null) return null;
        return _buildSummary(_mapGoal(row));
      });

  Future<List<GoalProgressSummary>> readAllGoalSummaries({
    bool includePrivate = false,
  }) => _db.transaction(() async {
    final rows = await _db
        .customSelect(
          includePrivate
              ? '''
                SELECT id, title, description, status, target_date, target_units,
                       unit_label, is_private, created_at_utc_us, updated_at_utc_us
                FROM goals
                ORDER BY updated_at_utc_us DESC, id ASC
                '''
              : '''
                SELECT id, title, description, status, target_date, target_units,
                       unit_label, is_private, created_at_utc_us, updated_at_utc_us
                FROM goals
                WHERE is_private = 0
                ORDER BY updated_at_utc_us DESC, id ASC
                ''',
        )
        .get();
    final summaries = <GoalProgressSummary>[];
    for (final row in rows) {
      summaries.add(await _buildSummary(_mapGoal(row)));
    }
    return summaries;
  });

  Future<GoalProgressSummary> _buildSummary(Goal goal) async {
    final milestoneRows = await _db
        .customSelect(
          '''
          SELECT id, goal_id, title, sort_order, is_completed, completed_at_utc_us, created_at_utc_us
          FROM goal_milestones
          WHERE goal_id = ?
          ORDER BY sort_order ASC, id ASC
          ''',
          variables: [Variable<String>(goal.id)],
        )
        .get();
    final linkRows = await _db
        .customSelect(
          '''
          SELECT habit_id FROM goal_habit_links
          WHERE goal_id = ?
          ORDER BY created_at_utc_us ASC, habit_id ASC
          ''',
          variables: [Variable<String>(goal.id)],
        )
        .get();
    final progressRows = await _db
        .customSelect(
          '''
          SELECT id, goal_id, local_date, units, source, source_ref_id, note, occurred_at_utc_us
          FROM goal_progress_entries
          WHERE goal_id = ?
          ORDER BY local_date DESC, occurred_at_utc_us DESC, id DESC
          ''',
          variables: [Variable<String>(goal.id)],
        )
        .get();
    final statusRows = await _db
        .customSelect(
          '''
          SELECT id, goal_id, previous_status, new_status, reason, occurred_at_utc_us
          FROM goal_status_history
          WHERE goal_id = ?
          ORDER BY occurred_at_utc_us ASC, id ASC
          ''',
          variables: [Variable<String>(goal.id)],
        )
        .get();

    return GoalProgressCalculator.summarize(
      goal: goal,
      milestones: [
        for (final row in milestoneRows)
          GoalMilestone(
            id: row.read<String>('id'),
            goalId: row.read<String>('goal_id'),
            title: row.read<String>('title'),
            sortOrder: row.read<int>('sort_order'),
            isCompleted: row.read<int>('is_completed') == 1,
            completedAtUtc: row.readNullable<int>('completed_at_utc_us') == null
                ? null
                : DateTime.fromMicrosecondsSinceEpoch(
                    row.read<int>('completed_at_utc_us'),
                    isUtc: true,
                  ),
            createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
              row.read<int>('created_at_utc_us'),
              isUtc: true,
            ),
          ),
      ],
      linkedHabitIds: [
        for (final row in linkRows) row.read<String>('habit_id'),
      ],
      progressEntries: [for (final row in progressRows) _mapProgress(row)],
      statusHistory: [
        for (final row in statusRows)
          GoalStatusEvent(
            id: row.read<String>('id'),
            goalId: row.read<String>('goal_id'),
            previousStatus: row.readNullable<String>('previous_status') == null
                ? null
                : GoalStatus.fromStorageKey(
                    row.read<String>('previous_status'),
                  ),
            newStatus: GoalStatus.fromStorageKey(
              row.read<String>('new_status'),
            ),
            reason: row.readNullable<String>('reason'),
            occurredAtUtc: DateTime.fromMicrosecondsSinceEpoch(
              row.read<int>('occurred_at_utc_us'),
              isUtc: true,
            ),
          ),
      ],
    );
  }

  Future<QueryRow?> _readGoalRow(String goalId) => _db
      .customSelect(
        '''
        SELECT id, title, description, status, target_date, target_units,
               unit_label, is_private, created_at_utc_us, updated_at_utc_us
        FROM goals
        WHERE id = ?
        ''',
        variables: [Variable<String>(goalId.trim())],
      )
      .getSingleOrNull();

  Goal _mapGoal(QueryRow row) {
    final targetDateRaw = row.readNullable<String>('target_date');
    return Goal(
      id: row.read<String>('id'),
      title: row.read<String>('title'),
      description: row.readNullable<String>('description'),
      status: GoalStatus.fromStorageKey(row.read<String>('status')),
      targetDate: targetDateRaw == null ? null : _parseDateKey(targetDateRaw),
      targetUnits: row.readNullable<int>('target_units'),
      unitLabel: row.readNullable<String>('unit_label'),
      isPrivate: row.read<int>('is_private') == 1,
      createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        row.read<int>('created_at_utc_us'),
        isUtc: true,
      ),
      updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        row.read<int>('updated_at_utc_us'),
        isUtc: true,
      ),
    );
  }

  GoalProgressEntry _mapProgress(QueryRow row) => GoalProgressEntry(
    id: row.read<String>('id'),
    goalId: row.read<String>('goal_id'),
    localDate: _parseDateKey(row.read<String>('local_date')),
    units: row.read<int>('units'),
    source: GoalProgressSource.fromStorageKey(row.read<String>('source')),
    sourceRefId: row.readNullable<String>('source_ref_id'),
    note: row.readNullable<String>('note'),
    occurredAtUtc: DateTime.fromMicrosecondsSinceEpoch(
      row.read<int>('occurred_at_utc_us'),
      isUtc: true,
    ),
  );
}

String? _cleanOptional(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

LocalDate _parseDateKey(String raw) {
  final parts = raw.split('-');
  return LocalDate(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}
