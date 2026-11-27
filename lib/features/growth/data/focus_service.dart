import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../../habits/data/habit_lifecycle.dart';
import '../../habits/domain/habit_schedule.dart';
import '../domain/focus_models.dart';
import '../domain/goal_models.dart';

/// Outcome of reconciling persisted active focus sessions after app restart/resume.
class FocusReconcileResult {
  const FocusReconcileResult({this.activeSession, this.autoCompletedSession});

  final FocusSession? activeSession;
  final FocusSession? autoCompletedSession;
}

/// Restart-safe transactional Focus / Pomodoro session store.
///
/// Persists deadline and accumulated elapsed seconds in SQLite so app restart
/// or backgrounding preserves timer state, distinguishes interrupted sessions
/// from completed ones, and applies linked duration-habit and goal progress
/// at most once per completed focus session.
class FocusService {
  const FocusService(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  Future<FocusPreset> createPreset({
    required String id,
    required String name,
    int focusMinutes = FocusPreset.defaultFocusMinutes,
    int shortBreakMinutes = FocusPreset.defaultShortBreakMinutes,
    int longBreakMinutes = FocusPreset.defaultLongBreakMinutes,
    int sessionsBeforeLongBreak = FocusPreset.defaultSessionsBeforeLongBreak,
  }) => _db.transaction(() async {
    final nowUtc = _clock.now().toUtc();
    final preset = FocusPreset(
      id: id,
      name: name,
      focusMinutes: focusMinutes,
      shortBreakMinutes: shortBreakMinutes,
      longBreakMinutes: longBreakMinutes,
      sessionsBeforeLongBreak: sessionsBeforeLongBreak,
      createdAtUtc: nowUtc,
    );
    await _db.customStatement(
      '''
      INSERT INTO focus_presets (
        id, name, focus_minutes, short_break_minutes, long_break_minutes,
        sessions_before_long_break, created_at_utc_us
      )
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        preset.id,
        preset.name,
        preset.focusMinutes,
        preset.shortBreakMinutes,
        preset.longBreakMinutes,
        preset.sessionsBeforeLongBreak,
        nowUtc.microsecondsSinceEpoch,
      ],
    );
    return preset;
  });

  Future<List<FocusPreset>> readPresets() => _db.transaction(() async {
    final rows = await _db.customSelect('''
          SELECT id, name, focus_minutes, short_break_minutes, long_break_minutes,
                 sessions_before_long_break, created_at_utc_us
          FROM focus_presets
          ORDER BY created_at_utc_us ASC, id ASC
          ''').get();
    return [for (final row in rows) _mapPreset(row)];
  });

  Future<FocusSession> startSession({
    required String id,
    String? presetId,
    required FocusSessionKind kind,
    required int plannedDurationSeconds,
    int? cycleIndex,
    String? linkedHabitId,
    String? linkedGoalId,
    String? note,
  }) => _db.transaction(() async {
    final active = await _readActiveRow();
    if (active != null) {
      throw StateError(
        'Another focus session (${active.read<String>('id')}) is already active',
      );
    }
    if (plannedDurationSeconds <= 0) {
      throw ArgumentError.value(
        plannedDurationSeconds,
        'plannedDurationSeconds',
        'Planned duration must be positive',
      );
    }
    final cleanPresetId = _cleanOptional(presetId);
    if (cleanPresetId != null) {
      final presetRow = await _db
          .customSelect(
            'SELECT id FROM focus_presets WHERE id = ?',
            variables: [Variable<String>(cleanPresetId)],
          )
          .getSingleOrNull();
      if (presetRow == null) {
        throw StateError('Focus preset not found: $cleanPresetId');
      }
    }
    final cleanHabitId = _cleanOptional(linkedHabitId);
    if (cleanHabitId != null) {
      final habitRow = await _db
          .customSelect(
            'SELECT id FROM habits WHERE id = ?',
            variables: [Variable<String>(cleanHabitId)],
          )
          .getSingleOrNull();
      if (habitRow == null) {
        throw StateError('Linked habit not found: $cleanHabitId');
      }
    }
    final cleanGoalId = _cleanOptional(linkedGoalId);
    if (cleanGoalId != null) {
      final goalRow = await _db
          .customSelect(
            'SELECT id FROM goals WHERE id = ?',
            variables: [Variable<String>(cleanGoalId)],
          )
          .getSingleOrNull();
      if (goalRow == null) {
        throw StateError('Linked goal not found: $cleanGoalId');
      }
    }

    final nowLocal = _clock.now().toLocal();
    final nowUtc = nowLocal.toUtc();
    final localDate = LocalDate(nowLocal.year, nowLocal.month, nowLocal.day);
    final deadlineUtc = nowUtc.add(Duration(seconds: plannedDurationSeconds));

    int resolvedCycleIndex;
    if (cycleIndex != null) {
      resolvedCycleIndex = cycleIndex;
    } else {
      final history = await _readAllChronological();
      resolvedCycleIndex = FocusCyclePlanner.recommendNext(
        chronologicalSessions: history,
      ).nextCycleIndex;
    }

    final session = FocusSession(
      id: id,
      presetId: cleanPresetId,
      kind: kind,
      localDate: localDate,
      plannedDurationSeconds: plannedDurationSeconds,
      state: FocusSessionState.running,
      cycleIndex: resolvedCycleIndex,
      startedAtUtc: nowUtc,
      lastResumedAtUtc: nowUtc,
      deadlineUtc: deadlineUtc,
      accumulatedElapsedSeconds: 0,
      linkedHabitId: cleanHabitId,
      linkedGoalId: cleanGoalId,
      note: note,
    );

    await _db.customStatement(
      '''
      INSERT INTO focus_sessions (
        id, preset_id, kind, local_date, planned_duration_seconds, state,
        cycle_index, started_at_utc_us, last_resumed_at_utc_us, deadline_utc_us,
        accumulated_elapsed_seconds, ended_at_utc_us, interruption_reason,
        linked_habit_id, linked_goal_id, linked_habit_event_id,
        linked_goal_progress_id, note
      )
      VALUES (?, ?, ?, ?, ?, 'running', ?, ?, ?, ?, 0, NULL, NULL, ?, ?, NULL, NULL, ?)
      ''',
      [
        session.id,
        session.presetId,
        session.kind.storageKey,
        _dateKey(session.localDate),
        session.plannedDurationSeconds,
        session.cycleIndex,
        session.startedAtUtc.microsecondsSinceEpoch,
        session.lastResumedAtUtc!.microsecondsSinceEpoch,
        session.deadlineUtc!.microsecondsSinceEpoch,
        session.linkedHabitId,
        session.linkedGoalId,
        session.note,
      ],
    );
    return session;
  });

  Future<FocusSession> pauseSession(
    String sessionId,
  ) => _db.transaction(() async {
    final row = await _readSessionRow(sessionId);
    if (row == null) {
      throw StateError('Focus session not found: $sessionId');
    }
    final current = _mapSession(row);
    if (current.state != FocusSessionState.running) {
      throw StateError(
        'Only a running focus session can be paused (current: ${current.state.name})',
      );
    }
    final nowUtc = _clock.now().toUtc();
    final elapsed = current.elapsedSecondsAt(nowUtc);
    await _db.customStatement(
      '''
          UPDATE focus_sessions
          SET state = 'paused',
              last_resumed_at_utc_us = NULL,
              deadline_utc_us = NULL,
              accumulated_elapsed_seconds = ?
          WHERE id = ?
          ''',
      [elapsed, current.id],
    );
    return _mapSession((await _readSessionRow(current.id))!);
  });

  Future<FocusSession> resumeSession(
    String sessionId,
  ) => _db.transaction(() async {
    final row = await _readSessionRow(sessionId);
    if (row == null) {
      throw StateError('Focus session not found: $sessionId');
    }
    final current = _mapSession(row);
    if (current.state != FocusSessionState.paused) {
      throw StateError(
        'Only a paused focus session can be resumed (current: ${current.state.name})',
      );
    }
    final nowUtc = _clock.now().toUtc();
    final remaining =
        current.plannedDurationSeconds - current.accumulatedElapsedSeconds;
    final deadlineUtc = nowUtc.add(
      Duration(seconds: remaining < 0 ? 0 : remaining),
    );
    await _db.customStatement(
      '''
          UPDATE focus_sessions
          SET state = 'running',
              last_resumed_at_utc_us = ?,
              deadline_utc_us = ?
          WHERE id = ?
          ''',
      [
        nowUtc.microsecondsSinceEpoch,
        deadlineUtc.microsecondsSinceEpoch,
        current.id,
      ],
    );
    return _mapSession((await _readSessionRow(current.id))!);
  });

  /// Completes a focus or break session idempotently.
  ///
  /// Repeated calls on an already-completed session return the stored session
  /// without duplicating linked duration-habit or linked goal progress.
  Future<FocusSession> completeSession(String sessionId) =>
      _db.transaction(() => _completeSessionInTx(sessionId));

  Future<FocusSession> _completeSessionInTx(String sessionId) async {
    final row = await _readSessionRow(sessionId);
    if (row == null) {
      throw StateError('Focus session not found: $sessionId');
    }
    final current = _mapSession(row);
    if (current.state == FocusSessionState.completed) {
      return current;
    }
    if (current.state == FocusSessionState.interrupted ||
        current.state == FocusSessionState.cancelled) {
      throw StateError(
        'Cannot complete an ${current.state.name} focus session',
      );
    }

    final nowUtc = _clock.now().toUtc();
    final endedAtUtc =
        current.deadlineUtc != null && !nowUtc.isBefore(current.deadlineUtc!)
        ? current.deadlineUtc!
        : nowUtc;

    String? habitEventId = current.linkedHabitEventId;
    String? goalProgressId = current.linkedGoalProgressId;

    if (current.kind == FocusSessionKind.focus) {
      if (current.linkedGoalId != null && goalProgressId == null) {
        goalProgressId = await _recordLinkedGoalProgressInTx(
          session: current,
          endedAtUtc: endedAtUtc,
        );
      }
      if (current.linkedHabitId != null && habitEventId == null) {
        habitEventId = await _recordLinkedDurationHabitInTx(
          session: current,
          endedAtUtc: endedAtUtc,
        );
      }
    }

    await _db.customStatement(
      '''
      UPDATE focus_sessions
      SET state = 'completed',
          last_resumed_at_utc_us = NULL,
          deadline_utc_us = NULL,
          accumulated_elapsed_seconds = planned_duration_seconds,
          ended_at_utc_us = ?,
          linked_habit_event_id = ?,
          linked_goal_progress_id = ?
      WHERE id = ?
      ''',
      [
        endedAtUtc.microsecondsSinceEpoch,
        habitEventId,
        goalProgressId,
        current.id,
      ],
    );
    return _mapSession((await _readSessionRow(current.id))!);
  }

  /// Marks an active session as explicitly interrupted (distinct from completed)
  /// while preserving exact elapsed seconds and never writing completion progress.
  Future<FocusSession> interruptSession({
    required String sessionId,
    String? reason,
  }) => _db.transaction(() async {
    final row = await _readSessionRow(sessionId);
    if (row == null) {
      throw StateError('Focus session not found: $sessionId');
    }
    final current = _mapSession(row);
    if (current.state.isTerminal) {
      throw StateError(
        'Focus session is already terminal (${current.state.name})',
      );
    }
    final nowUtc = _clock.now().toUtc();
    final elapsed = current.elapsedSecondsAt(nowUtc);
    final cleanReason = _cleanOptional(reason) ?? 'Interrupted';
    await _db.customStatement(
      '''
      UPDATE focus_sessions
      SET state = 'interrupted',
          last_resumed_at_utc_us = NULL,
          deadline_utc_us = NULL,
          accumulated_elapsed_seconds = ?,
          ended_at_utc_us = ?,
          interruption_reason = ?
      WHERE id = ?
      ''',
      [elapsed, nowUtc.microsecondsSinceEpoch, cleanReason, current.id],
    );
    return _mapSession((await _readSessionRow(current.id))!);
  });

  Future<FocusSession> cancelSession(String sessionId) =>
      _db.transaction(() async {
        final row = await _readSessionRow(sessionId);
        if (row == null) {
          throw StateError('Focus session not found: $sessionId');
        }
        final current = _mapSession(row);
        if (current.state.isTerminal) {
          throw StateError(
            'Focus session is already terminal (${current.state.name})',
          );
        }
        final nowUtc = _clock.now().toUtc();
        final elapsed = current.elapsedSecondsAt(nowUtc);
        await _db.customStatement(
          '''
          UPDATE focus_sessions
          SET state = 'cancelled',
              last_resumed_at_utc_us = NULL,
              deadline_utc_us = NULL,
              accumulated_elapsed_seconds = ?,
              ended_at_utc_us = ?
          WHERE id = ?
          ''',
          [elapsed, nowUtc.microsecondsSinceEpoch, current.id],
        );
        return _mapSession((await _readSessionRow(current.id))!);
      });

  /// Reconciles any active persisted focus session after app restart or resume.
  /// If a running session's persisted deadline has passed, completes it
  /// transactionally and idempotently.
  Future<FocusReconcileResult> reconcileActiveSession() =>
      _db.transaction(() async {
        final activeRow = await _readActiveRow();
        if (activeRow == null) {
          return const FocusReconcileResult();
        }
        final active = _mapSession(activeRow);
        final nowUtc = _clock.now().toUtc();
        if (active.isDeadlineReachedAt(nowUtc)) {
          final completed = await _completeSessionInTx(active.id);
          return FocusReconcileResult(autoCompletedSession: completed);
        }
        return FocusReconcileResult(activeSession: active);
      });

  Future<FocusSession?> readActiveSession() => _db.transaction(() async {
    final row = await _readActiveRow();
    return row == null ? null : _mapSession(row);
  });

  Future<List<FocusSession>> readHistory({int limit = 50}) =>
      _db.transaction(() async {
        final rows = await _db
            .customSelect(
              '''
              SELECT id, preset_id, kind, local_date, planned_duration_seconds, state,
                     cycle_index, started_at_utc_us, last_resumed_at_utc_us,
                     deadline_utc_us, accumulated_elapsed_seconds, ended_at_utc_us,
                     interruption_reason, linked_habit_id, linked_goal_id,
                     linked_habit_event_id, linked_goal_progress_id, note
              FROM focus_sessions
              ORDER BY started_at_utc_us DESC, id DESC
              LIMIT ?
              ''',
              variables: [Variable<int>(limit)],
            )
            .get();
        return [for (final row in rows) _mapSession(row)];
      });

  Future<FocusCycleRecommendation> readNextCycleRecommendation({
    int sessionsBeforeLongBreak = FocusPreset.defaultSessionsBeforeLongBreak,
  }) => _db.transaction(() async {
    final all = await _readAllChronological();
    return FocusCyclePlanner.recommendNext(
      chronologicalSessions: all,
      sessionsBeforeLongBreak: sessionsBeforeLongBreak,
    );
  });

  Future<String?> _recordLinkedGoalProgressInTx({
    required FocusSession session,
    required DateTime endedAtUtc,
  }) async {
    final goalId = session.linkedGoalId!;
    final refKey = buildLinkedFocusProgressRef(session.id);
    final existing = await _db
        .customSelect(
          '''
          SELECT id FROM goal_progress_entries
          WHERE goal_id = ? AND source_ref_id = ?
          ''',
          variables: [Variable<String>(goalId), Variable<String>(refKey)],
        )
        .getSingleOrNull();
    if (existing != null) {
      return existing.read<String>('id');
    }
    final progressId = 'gpf_${session.id}';
    final minutes = session.plannedDurationSeconds ~/ 60;
    final units = minutes > 0 ? minutes : 1;
    await _db.customStatement(
      '''
      INSERT INTO goal_progress_entries (
        id, goal_id, local_date, units, source, source_ref_id, note, occurred_at_utc_us
      )
      VALUES (?, ?, ?, ?, 'linked_focus', ?, ?, ?)
      ''',
      [
        progressId,
        goalId,
        _dateKey(session.localDate),
        units,
        refKey,
        'Completed focus session (${session.plannedDurationSeconds ~/ 60} min)',
        endedAtUtc.microsecondsSinceEpoch,
      ],
    );
    await _db.customStatement(
      'UPDATE goals SET updated_at_utc_us = ? WHERE id = ?',
      [endedAtUtc.microsecondsSinceEpoch, goalId],
    );
    return progressId;
  }

  Future<String?> _recordLinkedDurationHabitInTx({
    required FocusSession session,
    required DateTime endedAtUtc,
  }) async {
    final habitId = session.linkedHabitId!;
    final eventId = 'fde_focus_${session.id}';
    final existingEvent = await _db
        .customSelect(
          'SELECT id FROM habit_duration_events WHERE id = ?',
          variables: [Variable<String>(eventId)],
        )
        .getSingleOrNull();
    if (existingEvent != null) {
      return eventId;
    }

    final detail = await HabitApplicabilityReader(_db)
        .describe(habitId, session.localDate);
    if (detail.applicability != HabitApplicability.applicable ||
        detail.versionId == null) {
      return null;
    }
    final targetRow = await _db
        .customSelect(
          'SELECT tracking_type FROM habit_typed_targets WHERE habit_version_id = ?',
          variables: [Variable<String>(detail.versionId!)],
        )
        .getSingleOrNull();
    if (targetRow == null ||
        targetRow.read<String>('tracking_type') != 'duration') {
      return null;
    }

    final dateKey = _dateKey(session.localDate);
    final existingOcc = await _db
        .customSelect(
          '''
          SELECT id, tracking_type FROM habit_typed_occurrences
          WHERE habit_id = ? AND local_date = ?
          ''',
          variables: [Variable<String>(habitId), Variable<String>(dateKey)],
        )
        .getSingleOrNull();
    late final String occurrenceId;
    if (existingOcc != null) {
      if (existingOcc.read<String>('tracking_type') != 'duration') {
        return null;
      }
      occurrenceId = existingOcc.read<String>('id');
    } else {
      occurrenceId = 'hto_focus_${habitId}_$dateKey';
      await _db.customStatement(
        '''
        INSERT INTO habit_typed_occurrences (
          id, habit_id, habit_version_id, tracking_type, local_date
        )
        VALUES (?, ?, ?, 'duration', ?)
        ''',
        [occurrenceId, habitId, detail.versionId!, dateKey],
      );
    }

    final resolved = await _db
        .customSelect(
          'SELECT id FROM habit_typed_logs WHERE occurrence_id = ?',
          variables: [Variable<String>(occurrenceId)],
        )
        .getSingleOrNull();
    if (resolved != null) {
      return null;
    }

    final endedUs = endedAtUtc.microsecondsSinceEpoch;
    final startedUs = session.startedAtUtc.microsecondsSinceEpoch < endedUs
        ? session.startedAtUtc.microsecondsSinceEpoch
        : endedUs - session.plannedDurationSeconds * 1000000;

    await _db.customStatement(
      '''
      INSERT INTO habit_duration_events (
        id, occurrence_id, duration_seconds, source, started_at_utc_us,
        ended_at_utc_us, occurred_at_utc_us
      )
      VALUES (?, ?, ?, 'timer', ?, ?, ?)
      ''',
      [
        eventId,
        occurrenceId,
        session.plannedDurationSeconds,
        startedUs,
        endedUs,
        endedUs,
      ],
    );
    return eventId;
  }

  Future<QueryRow?> _readActiveRow() => _db.customSelect('''
        SELECT id, preset_id, kind, local_date, planned_duration_seconds, state,
               cycle_index, started_at_utc_us, last_resumed_at_utc_us,
               deadline_utc_us, accumulated_elapsed_seconds, ended_at_utc_us,
               interruption_reason, linked_habit_id, linked_goal_id,
               linked_habit_event_id, linked_goal_progress_id, note
        FROM focus_sessions
        WHERE state IN ('running', 'paused')
        ORDER BY started_at_utc_us DESC
        LIMIT 1
        ''').getSingleOrNull();

  Future<QueryRow?> _readSessionRow(String sessionId) => _db
      .customSelect(
        '''
        SELECT id, preset_id, kind, local_date, planned_duration_seconds, state,
               cycle_index, started_at_utc_us, last_resumed_at_utc_us,
               deadline_utc_us, accumulated_elapsed_seconds, ended_at_utc_us,
               interruption_reason, linked_habit_id, linked_goal_id,
               linked_habit_event_id, linked_goal_progress_id, note
        FROM focus_sessions
        WHERE id = ?
        ''',
        variables: [Variable<String>(sessionId.trim())],
      )
      .getSingleOrNull();

  Future<List<FocusSession>> _readAllChronological() async {
    final rows = await _db.customSelect('''
          SELECT id, preset_id, kind, local_date, planned_duration_seconds, state,
                 cycle_index, started_at_utc_us, last_resumed_at_utc_us,
                 deadline_utc_us, accumulated_elapsed_seconds, ended_at_utc_us,
                 interruption_reason, linked_habit_id, linked_goal_id,
                 linked_habit_event_id, linked_goal_progress_id, note
          FROM focus_sessions
          ORDER BY started_at_utc_us ASC, id ASC
          ''').get();
    return [for (final row in rows) _mapSession(row)];
  }

  FocusPreset _mapPreset(QueryRow row) => FocusPreset(
    id: row.read<String>('id'),
    name: row.read<String>('name'),
    focusMinutes: row.read<int>('focus_minutes'),
    shortBreakMinutes: row.read<int>('short_break_minutes'),
    longBreakMinutes: row.read<int>('long_break_minutes'),
    sessionsBeforeLongBreak: row.read<int>('sessions_before_long_break'),
    createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
      row.read<int>('created_at_utc_us'),
      isUtc: true,
    ),
  );

  FocusSession _mapSession(QueryRow row) {
    DateTime? optUtc(String col) {
      final raw = row.readNullable<int>(col);
      return raw == null
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(raw, isUtc: true);
    }

    return FocusSession(
      id: row.read<String>('id'),
      presetId: row.readNullable<String>('preset_id'),
      kind: FocusSessionKind.fromStorageKey(row.read<String>('kind')),
      localDate: _parseDateKey(row.read<String>('local_date')),
      plannedDurationSeconds: row.read<int>('planned_duration_seconds'),
      state: FocusSessionState.fromStorageKey(row.read<String>('state')),
      cycleIndex: row.read<int>('cycle_index'),
      startedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        row.read<int>('started_at_utc_us'),
        isUtc: true,
      ),
      lastResumedAtUtc: optUtc('last_resumed_at_utc_us'),
      deadlineUtc: optUtc('deadline_utc_us'),
      accumulatedElapsedSeconds: row.read<int>('accumulated_elapsed_seconds'),
      endedAtUtc: optUtc('ended_at_utc_us'),
      interruptionReason: row.readNullable<String>('interruption_reason'),
      linkedHabitId: row.readNullable<String>('linked_habit_id'),
      linkedGoalId: row.readNullable<String>('linked_goal_id'),
      linkedHabitEventId: row.readNullable<String>('linked_habit_event_id'),
      linkedGoalProgressId: row.readNullable<String>('linked_goal_progress_id'),
      note: row.readNullable<String>('note'),
    );
  }
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
