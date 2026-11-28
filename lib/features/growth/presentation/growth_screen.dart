import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/app_clock.dart';
import '../../gamification/presentation/gamification_section.dart';
import '../../habits/application/counter_habit_providers.dart';
import '../../habits/data/unified_habit_registry.dart';
import '../../habits/domain/habit_schedule.dart';
import '../application/growth_providers.dart';
import '../domain/focus_models.dart';
import '../domain/goal_models.dart';
import '../domain/journal_models.dart';

enum _GrowthSection { journal, goals, focus, rewards }

class _GrowthSnapshot {
  const _GrowthSnapshot({
    required this.journalEntries,
    required this.journalSummary,
    required this.goalSummaries,
    required this.activeFocusSession,
    required this.autoCompletedSession,
    required this.focusHistory,
    required this.focusSummary,
    required this.nextCycle,
    required this.presets,
    required this.habits,
  });

  final List<JournalEntry> journalEntries;
  final JournalSummary journalSummary;
  final List<GoalProgressSummary> goalSummaries;
  final FocusSession? activeFocusSession;
  final FocusSession? autoCompletedSession;
  final List<FocusSession> focusHistory;
  final FocusHistorySummary focusSummary;
  final FocusCycleRecommendation nextCycle;
  final List<FocusPreset> presets;
  final List<UnifiedHabitSummary> habits;
}

/// Offline Growth workspace uniting optional Journal & Mood, Goals & Milestones,
/// and restart-safe Focus / Pomodoro sessions.
class GrowthView extends ConsumerStatefulWidget {
  const GrowthView({super.key, required this.asOfDate});

  final LocalDate asOfDate;

  @override
  ConsumerState<GrowthView> createState() => _GrowthViewState();
}

class _GrowthViewState extends ConsumerState<GrowthView> {
  _GrowthSection _section = _GrowthSection.journal;
  bool _includePrivate = false;
  String? _selectedJournalTag;
  FocusSessionKind _selectedFocusKind = FocusSessionKind.focus;
  String? _selectedFocusGoalId;
  String? _selectedFocusHabitId;

  bool _loading = true;
  Object? _error;
  _GrowthSnapshot? _snapshot;
  Timer? _focusTickTimer;
  int _idSeq = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _focusTickTimer?.cancel();
    super.dispose();
  }

  String _nextId(String prefix) {
    _idSeq++;
    final us = ref.read(appClockProvider).now().toUtc().microsecondsSinceEpoch;
    return '${prefix}_${us}_$_idSeq';
  }

  void _syncFocusTicker(FocusSession? active) {
    _focusTickTimer?.cancel();
    _focusTickTimer = null;
    if (active == null || active.state != FocusSessionState.running) {
      return;
    }
    _focusTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final nowUtc = ref.read(appClockProvider).now().toUtc();
      if (active.isDeadlineReachedAt(nowUtc)) {
        _focusTickTimer?.cancel();
        _focusTickTimer = null;
        _reload();
      } else {
        setState(() {});
      }
    });
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final journalService = ref.read(journalServiceProvider);
      final goalService = ref.read(goalServiceProvider);
      final focusService = ref.read(focusServiceProvider);
      final registryReader = ref.read(unifiedHabitRegistryReaderProvider);

      final reconciled = await focusService.reconcileActiveSession();
      final entries = await journalService.readEntries(
        tagFilter: _selectedJournalTag,
        includePrivate: _includePrivate,
      );
      final goals = await goalService.readAllGoalSummaries(
        includePrivate: _includePrivate,
      );
      final history = await focusService.readHistory(limit: 30);
      final nextCycle = await focusService.readNextCycleRecommendation();
      final presets = await focusService.readPresets();
      final habits = await registryReader.readAll(asOfDate: widget.asOfDate);

      final snapshot = _GrowthSnapshot(
        journalEntries: entries,
        journalSummary: JournalSummary.summarize(entries),
        goalSummaries: goals,
        activeFocusSession: reconciled.activeSession,
        autoCompletedSession: reconciled.autoCompletedSession,
        focusHistory: history,
        focusSummary: FocusHistorySummary.summarize(history),
        nextCycle: nextCycle,
        presets: presets,
        habits: habits,
      );

      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        if (reconciled.activeSession == null) {
          _selectedFocusKind = nextCycle.nextKind;
        }
        if (_selectedFocusGoalId != null &&
            !goals.any((g) => g.goal.id == _selectedFocusGoalId)) {
          _selectedFocusGoalId = null;
        }
        if (_selectedFocusHabitId != null &&
            !habits.any((h) => h.habitId == _selectedFocusHabitId)) {
          _selectedFocusHabitId = null;
        }
      });
      _syncFocusTicker(reconciled.activeSession);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openCreateJournalDialog() async {
    final result = await showDialog<_JournalDraft>(
      context: context,
      builder: (_) => const _JournalEntryDialog(),
    );
    if (result == null) return;
    try {
      await ref
          .read(journalServiceProvider)
          .createEntry(
            id: _nextId('jrn'),
            localDate: widget.asOfDate,
            title: result.title,
            reflectionText: result.reflection,
            gratitudeText: result.gratitude,
            mood: result.mood,
            tags: result.tags,
            isPrivate: result.isPrivate,
          );
      await _reload();
    } catch (error) {
      _showMessage('Unable to save journal entry: $error');
    }
  }

  Future<void> _openCreateGoalDialog() async {
    final result = await showDialog<_GoalDraft>(
      context: context,
      builder: (_) => const _CreateGoalDialog(),
    );
    if (result == null) return;
    try {
      await ref
          .read(goalServiceProvider)
          .createGoal(
            id: _nextId('goal'),
            title: result.title,
            description: result.description,
            status: result.status,
            targetUnits: result.targetUnits,
            unitLabel: result.unitLabel,
            isPrivate: result.isPrivate,
          );
      await _reload();
    } catch (error) {
      _showMessage('Unable to create goal: $error');
    }
  }

  Future<void> _openAddMilestoneDialog(String goalId) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => const _SingleTextDialog(
        title: 'Add milestone',
        label: 'Milestone title',
        confirmLabel: 'Add',
      ),
    );
    if (title == null || title.trim().isEmpty) return;
    try {
      await ref
          .read(goalServiceProvider)
          .addMilestone(id: _nextId('ms'), goalId: goalId, title: title);
      await _reload();
    } catch (error) {
      _showMessage('Unable to add milestone: $error');
    }
  }

  Future<void> _openManualGoalProgressDialog(Goal goal) async {
    final draft = await showDialog<_ManualProgressDraft>(
      context: context,
      builder: (_) => _ManualGoalProgressDialog(unitLabel: goal.unitLabel),
    );
    if (draft == null) return;
    try {
      await ref
          .read(goalServiceProvider)
          .recordManualProgress(
            id: _nextId('gp'),
            goalId: goal.id,
            localDate: widget.asOfDate,
            units: draft.units,
            note: draft.note,
          );
      await _reload();
    } catch (error) {
      _showMessage('Unable to log progress: $error');
    }
  }

  Future<void> _openLinkHabitDialog(
    GoalProgressSummary summary,
    List<UnifiedHabitSummary> habits,
  ) async {
    final available = habits
        .where((h) => !summary.linkedHabitIds.contains(h.habitId))
        .toList();
    if (available.isEmpty) {
      _showMessage('No unlinked habits available to link.');
      return;
    }
    final habitId = await showDialog<String>(
      context: context,
      builder: (_) => _PickHabitDialog(habits: available),
    );
    if (habitId == null) return;
    try {
      await ref
          .read(goalServiceProvider)
          .linkHabit(goalId: summary.goal.id, habitId: habitId);
      await _reload();
    } catch (error) {
      _showMessage('Unable to link habit: $error');
    }
  }

  Future<void> _syncLinkedHabitsForGoal(GoalProgressSummary summary) async {
    var recorded = 0;
    var already = 0;
    final goalService = ref.read(goalServiceProvider);
    for (final habitId in summary.linkedHabitIds) {
      final result = await goalService.syncLinkedHabitProgress(
        entryId: _nextId('gph'),
        goalId: summary.goal.id,
        habitId: habitId,
        date: widget.asOfDate,
      );
      if (result.recorded) {
        recorded++;
      } else if (result.alreadyRecorded) {
        already++;
      }
    }
    await _reload();
    if (recorded > 0) {
      _showMessage('Synced $recorded linked habit progress item(s).');
    } else if (already > 0) {
      _showMessage('Linked habit progress for today is already recorded.');
    } else {
      _showMessage('No completed linked habits found for today.');
    }
  }

  Future<void> _startFocusSession(_GrowthSnapshot snapshot) async {
    final preset = snapshot.presets.isNotEmpty
        ? snapshot.presets.first
        : FocusPreset.defaultPomodoro(ref.read(appClockProvider).now().toUtc());
    final plannedSeconds = preset.plannedSecondsFor(_selectedFocusKind);
    try {
      await ref
          .read(focusServiceProvider)
          .startSession(
            id: _nextId('foc'),
            presetId: snapshot.presets.isNotEmpty ? preset.id : null,
            kind: _selectedFocusKind,
            plannedDurationSeconds: plannedSeconds,
            linkedGoalId: _selectedFocusKind == FocusSessionKind.focus
                ? _selectedFocusGoalId
                : null,
            linkedHabitId: _selectedFocusKind == FocusSessionKind.focus
                ? _selectedFocusHabitId
                : null,
          );
      await _reload();
    } catch (error) {
      _showMessage('Unable to start focus session: $error');
    }
  }

  Future<void> _interruptFocusSession(FocusSession session) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _SingleTextDialog(
        title: 'Interrupt focus session',
        label: 'Interruption reason (optional)',
        confirmLabel: 'Mark interrupted',
        allowEmpty: true,
      ),
    );
    if (reason == null) return;
    try {
      await ref
          .read(focusServiceProvider)
          .interruptSession(sessionId: session.id, reason: reason);
      await _reload();
    } catch (error) {
      _showMessage('Unable to interrupt session: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _snapshot == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('Loading growth…'),
      );
    }
    if (_error != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Unable to load Growth data',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text('$_error'),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _reload, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final snapshot = _snapshot!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Journal'),
                      selected: _section == _GrowthSection.journal,
                      onSelected: (_) =>
                          setState(() => _section = _GrowthSection.journal),
                    ),
                    ChoiceChip(
                      label: const Text('Goals'),
                      selected: _section == _GrowthSection.goals,
                      onSelected: (_) =>
                          setState(() => _section = _GrowthSection.goals),
                    ),
                    ChoiceChip(
                      label: const Text('Focus'),
                      selected: _section == _GrowthSection.focus,
                      onSelected: (_) =>
                          setState(() => _section = _GrowthSection.focus),
                    ),
                    ChoiceChip(
                      label: const Text('Rewards'),
                      selected: _section == _GrowthSection.rewards,
                      onSelected: (_) =>
                          setState(() => _section = _GrowthSection.rewards),
                    ),
                  ],
                ),
                if (_section == _GrowthSection.journal ||
                    _section == _GrowthSection.goals) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show private entries'),
                    subtitle: const Text(
                      'Private journals and goals stay hidden until enabled.',
                    ),
                    value: _includePrivate,
                    onChanged: (value) {
                      setState(() => _includePrivate = value);
                      _reload();
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_section == _GrowthSection.journal) _buildJournalSection(snapshot),
        if (_section == _GrowthSection.goals) _buildGoalsSection(snapshot),
        if (_section == _GrowthSection.focus) _buildFocusSection(snapshot),
        if (_section == _GrowthSection.rewards)
          GamificationSection(habits: snapshot.habits),
      ],
    );
  }

  Widget _buildJournalSection(_GrowthSnapshot snapshot) {
    final allTags = snapshot.journalSummary.tagCounts.keys.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Journal & Mood',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Optional personal reflection — missing days are never penalized and mood is not diagnostic.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Recorded entries: ${snapshot.journalSummary.entryCount} across '
                  '${snapshot.journalSummary.distinctDaysCount} day(s)',
                ),
                if (allTags.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      FilterChip(
                        label: const Text('All tags'),
                        selected: _selectedJournalTag == null,
                        onSelected: (_) {
                          setState(() => _selectedJournalTag = null);
                          _reload();
                        },
                      ),
                      for (final tag in allTags)
                        FilterChip(
                          label: Text('#$tag'),
                          selected: _selectedJournalTag == tag,
                          onSelected: (_) {
                            setState(
                              () => _selectedJournalTag =
                                  _selectedJournalTag == tag ? null : tag,
                            );
                            _reload();
                          },
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _openCreateJournalDialog,
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Add journal entry'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (snapshot.journalEntries.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No journal entries recorded yet.'),
            ),
          )
        else
          for (final entry in snapshot.journalEntries) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.title ?? _formatDate(entry.localDate),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Delete entry',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await ref
                                .read(journalServiceProvider)
                                .softDeleteEntry(entry.id);
                            await _reload();
                          },
                        ),
                      ],
                    ),
                    Text(
                      '${_formatDate(entry.localDate)}'
                      '${entry.mood != null ? ' • Mood: ${entry.mood!.label}' : ''}'
                      '${entry.isPrivate ? ' • Private' : ''}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (entry.reflectionText != null) ...[
                      const SizedBox(height: 8),
                      Text(entry.reflectionText!),
                    ],
                    if (entry.gratitudeText != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Gratitude: ${entry.gratitudeText!}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                    if (entry.tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final tag in entry.tags)
                            Chip(
                              label: Text('#$tag'),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }

  Widget _buildGoalsSection(_GrowthSnapshot snapshot) {
    final habitNames = {
      for (final h in snapshot.habits) h.habitId: h.name ?? h.habitId,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Goals & Milestones',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Track milestones and linked habits without duplicating progress.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _openCreateGoalDialog,
                  icon: const Icon(Icons.flag_outlined),
                  label: const Text('Add goal'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (snapshot.goalSummaries.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No goals recorded yet.'),
            ),
          )
        else
          for (final summary in snapshot.goalSummaries) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary.goal.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (summary.goal.description != null) ...[
                      const SizedBox(height: 4),
                      Text(summary.goal.description!),
                    ],
                    const SizedBox(height: 8),
                    DropdownButtonFormField<GoalStatus>(
                      isExpanded: true,
                      initialValue: summary.goal.status,
                      decoration: const InputDecoration(
                        labelText: 'Status',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final status in GoalStatus.values)
                          DropdownMenuItem(
                            value: status,
                            child: Text(
                              status.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (next) async {
                        if (next == null || next == summary.goal.status) return;
                        await ref
                            .read(goalServiceProvider)
                            .updateGoalStatus(
                              goalId: summary.goal.id,
                              newStatus: next,
                            );
                        await _reload();
                      },
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Progress: ${summary.totalUnits}'
                      '${summary.goal.targetUnits != null ? ' / ${summary.goal.targetUnits}' : ''}'
                      '${summary.goal.unitLabel != null ? ' ${summary.goal.unitLabel}' : ' units'}'
                      ' (manual ${summary.manualUnits}, habit ${summary.linkedHabitUnits}, focus ${summary.linkedFocusUnits})',
                    ),
                    if (summary.totalMilestones > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Milestones: ${summary.completedMilestones} / ${summary.totalMilestones}',
                      ),
                      for (final milestone in summary.milestones)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(milestone.title),
                          value: milestone.isCompleted,
                          onChanged: (checked) async {
                            if (checked == null) return;
                            await ref
                                .read(goalServiceProvider)
                                .setMilestoneCompleted(
                                  milestoneId: milestone.id,
                                  completed: checked,
                                );
                            await _reload();
                          },
                        ),
                    ],
                    if (summary.linkedHabitIds.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final habitId in summary.linkedHabitIds)
                            Chip(
                              label: Text(
                                'Habit: ${habitNames[habitId] ?? habitId}',
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: () =>
                              _openAddMilestoneDialog(summary.goal.id),
                          child: const Text('Add milestone'),
                        ),
                        OutlinedButton(
                          onPressed: () =>
                              _openManualGoalProgressDialog(summary.goal),
                          child: const Text('Log progress'),
                        ),
                        OutlinedButton(
                          onPressed: () =>
                              _openLinkHabitDialog(summary, snapshot.habits),
                          child: const Text('Link habit'),
                        ),
                        if (summary.linkedHabitIds.isNotEmpty)
                          FilledButton.tonal(
                            onPressed: () => _syncLinkedHabitsForGoal(summary),
                            child: const Text('Sync linked habits'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Status history: ${summary.statusHistory.map((e) => e.newStatus.label).join(' → ')}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }

  Widget _buildFocusSection(_GrowthSnapshot snapshot) {
    final nowUtc = ref.read(appClockProvider).now().toUtc();
    final active = snapshot.activeFocusSession;
    final durationHabits = snapshot.habits
        .where((h) => h.trackingType == HabitTrackingType.duration)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (snapshot.autoCompletedSession != null) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Recovered completed session after restart: '
                '${snapshot.autoCompletedSession!.kind.label} '
                '(${snapshot.autoCompletedSession!.plannedDurationSeconds ~/ 60} min).',
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Focus / Pomodoro (25 / 5 / 15)',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Next recommended: ${snapshot.nextCycle.nextKind.label} '
                  '(completed in cycle: ${snapshot.nextCycle.completedFocusInCurrentCycle}/${snapshot.nextCycle.sessionsBeforeLongBreak})',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (active != null) ...[
                  Text(
                    '${active.kind.label} — ${active.state.label}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    formatFocusClock(active.remainingSecondsAt(nowUtc)),
                    key: const Key('focus-remaining-clock'),
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Elapsed: ${formatFocusClock(active.elapsedSecondsAt(nowUtc))} / '
                    '${formatFocusClock(active.plannedDurationSeconds)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (active.state == FocusSessionState.running)
                        FilledButton(
                          onPressed: () async {
                            await ref
                                .read(focusServiceProvider)
                                .pauseSession(active.id);
                            await _reload();
                          },
                          child: const Text('Pause'),
                        )
                      else
                        FilledButton(
                          onPressed: () async {
                            await ref
                                .read(focusServiceProvider)
                                .resumeSession(active.id);
                            await _reload();
                          },
                          child: const Text('Resume'),
                        ),
                      FilledButton.tonal(
                        onPressed: () async {
                          await ref
                              .read(focusServiceProvider)
                              .completeSession(active.id);
                          await _reload();
                        },
                        child: const Text('Complete'),
                      ),
                      OutlinedButton(
                        onPressed: () => _interruptFocusSession(active),
                        child: const Text('Interrupt'),
                      ),
                      OutlinedButton(
                        onPressed: () async {
                          await ref
                              .read(focusServiceProvider)
                              .cancelSession(active.id);
                          await _reload();
                        },
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                ] else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final kind in FocusSessionKind.values)
                        ChoiceChip(
                          label: Text(kind.label),
                          selected: _selectedFocusKind == kind,
                          onSelected: (_) =>
                              setState(() => _selectedFocusKind = kind),
                        ),
                    ],
                  ),
                  if (_selectedFocusKind == FocusSessionKind.focus &&
                      snapshot.goalSummaries.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      isExpanded: true,
                      initialValue: _selectedFocusGoalId,
                      decoration: const InputDecoration(
                        labelText: 'Link to goal (optional)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('None', overflow: TextOverflow.ellipsis),
                        ),
                        for (final g in snapshot.goalSummaries)
                          DropdownMenuItem<String?>(
                            value: g.goal.id,
                            child: Text(
                              g.goal.title,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) =>
                          setState(() => _selectedFocusGoalId = v),
                    ),
                  ],
                  if (_selectedFocusKind == FocusSessionKind.focus &&
                      durationHabits.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      isExpanded: true,
                      initialValue: _selectedFocusHabitId,
                      decoration: const InputDecoration(
                        labelText: 'Link to duration habit (optional)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('None', overflow: TextOverflow.ellipsis),
                        ),
                        for (final h in durationHabits)
                          DropdownMenuItem<String?>(
                            value: h.habitId,
                            child: Text(
                              h.name ?? h.habitId,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) =>
                          setState(() => _selectedFocusHabitId = v),
                    ),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => _startFocusSession(snapshot),
                    icon: const Icon(Icons.play_arrow),
                    label: Text('Start ${_selectedFocusKind.label}'),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Focus History',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Completed focus: ${snapshot.focusSummary.completedFocusCount} • '
                  'Interrupted: ${snapshot.focusSummary.interruptedFocusCount} • '
                  'Cancelled: ${snapshot.focusSummary.cancelledFocusCount}',
                ),
                const SizedBox(height: 8),
                if (snapshot.focusHistory.isEmpty)
                  const Text('No focus sessions recorded yet.')
                else
                  for (final session in snapshot.focusHistory.take(10))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        '${session.kind.label} — ${session.state.label}',
                      ),
                      subtitle: Text(
                        '${_formatDate(session.localDate)} • '
                        'Elapsed ${formatFocusClock(session.accumulatedElapsedSeconds)} / '
                        '${formatFocusClock(session.plannedDurationSeconds)}'
                        '${session.interruptionReason != null ? ' • ${session.interruptionReason}' : ''}',
                      ),
                    ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _JournalDraft {
  const _JournalDraft({
    this.title,
    this.reflection,
    this.gratitude,
    this.mood,
    required this.tags,
    required this.isPrivate,
  });

  final String? title;
  final String? reflection;
  final String? gratitude;
  final JournalMood? mood;
  final List<String> tags;
  final bool isPrivate;
}

class _JournalEntryDialog extends StatefulWidget {
  const _JournalEntryDialog();

  @override
  State<_JournalEntryDialog> createState() => _JournalEntryDialogState();
}

class _JournalEntryDialogState extends State<_JournalEntryDialog> {
  final _titleController = TextEditingController();
  final _reflectionController = TextEditingController();
  final _gratitudeController = TextEditingController();
  final _tagsController = TextEditingController();
  JournalMood? _mood;
  bool _isPrivate = false;
  String? _validationError;

  @override
  void dispose() {
    _titleController.dispose();
    _reflectionController.dispose();
    _gratitudeController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _titleController.text.trim();
    final reflection = _reflectionController.text.trim();
    final gratitude = _gratitudeController.text.trim();
    if (title.isEmpty &&
        reflection.isEmpty &&
        gratitude.isEmpty &&
        _mood == null) {
      setState(() {
        _validationError =
            'Enter a title, reflection, gratitude note, or select a mood.';
      });
      return;
    }
    final tags = _tagsController.text
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    Navigator.of(context).pop(
      _JournalDraft(
        title: title.isEmpty ? null : title,
        reflection: reflection.isEmpty ? null : reflection,
        gratitude: gratitude.isEmpty ? null : gratitude,
        mood: _mood,
        tags: tags,
        isPrivate: _isPrivate,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New journal entry'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(labelText: 'Title (optional)'),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<JournalMood?>(
              isExpanded: true,
              initialValue: _mood,
              decoration: const InputDecoration(labelText: 'Mood (optional)'),
              items: [
                const DropdownMenuItem<JournalMood?>(
                  value: null,
                  child: Text('No mood selected'),
                ),
                for (final mood in JournalMood.values)
                  DropdownMenuItem<JournalMood?>(
                    value: mood,
                    child: Text(mood.label),
                  ),
              ],
              onChanged: (value) => setState(() => _mood = value),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _reflectionController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Reflection (optional)',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _gratitudeController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Gratitude (optional)',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _tagsController,
              decoration: const InputDecoration(
                labelText: 'Tags (comma separated)',
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Private entry'),
              value: _isPrivate,
              onChanged: (v) => setState(() => _isPrivate = v ?? false),
            ),
            if (_validationError != null)
              Text(
                _validationError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

class _GoalDraft {
  const _GoalDraft({
    required this.title,
    this.description,
    required this.status,
    this.targetUnits,
    this.unitLabel,
    required this.isPrivate,
  });

  final String title;
  final String? description;
  final GoalStatus status;
  final int? targetUnits;
  final String? unitLabel;
  final bool isPrivate;
}

class _CreateGoalDialog extends StatefulWidget {
  const _CreateGoalDialog();

  @override
  State<_CreateGoalDialog> createState() => _CreateGoalDialogState();
}

class _CreateGoalDialogState extends State<_CreateGoalDialog> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _targetUnitsController = TextEditingController();
  final _unitLabelController = TextEditingController();
  GoalStatus _status = GoalStatus.planned;
  bool _isPrivate = false;
  String? _validationError;

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _targetUnitsController.dispose();
    _unitLabelController.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _validationError = 'Goal title is required.');
      return;
    }
    int? targetUnits;
    final rawTarget = _targetUnitsController.text.trim();
    if (rawTarget.isNotEmpty) {
      targetUnits = int.tryParse(rawTarget);
      if (targetUnits == null || targetUnits <= 0) {
        setState(
          () => _validationError =
              'Target units must be a positive whole number.',
        );
        return;
      }
    }
    Navigator.of(context).pop(
      _GoalDraft(
        title: title,
        description: _descriptionController.text.trim(),
        status: _status,
        targetUnits: targetUnits,
        unitLabel: _unitLabelController.text.trim(),
        isPrivate: _isPrivate,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New goal'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(labelText: 'Goal title'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _descriptionController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<GoalStatus>(
              isExpanded: true,
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Initial status'),
              items: [
                for (final status in GoalStatus.values)
                  DropdownMenuItem(value: status, child: Text(status.label)),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _status = v);
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _targetUnitsController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Target units (optional)',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _unitLabelController,
              decoration: const InputDecoration(
                labelText: 'Unit label (optional, e.g. chapters)',
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Private goal'),
              value: _isPrivate,
              onChanged: (v) => setState(() => _isPrivate = v ?? false),
            ),
            if (_validationError != null)
              Text(
                _validationError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}

class _ManualProgressDraft {
  const _ManualProgressDraft({required this.units, this.note});

  final int units;
  final String? note;
}

class _ManualGoalProgressDialog extends StatefulWidget {
  const _ManualGoalProgressDialog({this.unitLabel});

  final String? unitLabel;

  @override
  State<_ManualGoalProgressDialog> createState() =>
      _ManualGoalProgressDialogState();
}

class _ManualGoalProgressDialogState extends State<_ManualGoalProgressDialog> {
  final _unitsController = TextEditingController(text: '1');
  final _noteController = TextEditingController();
  String? _validationError;

  @override
  void dispose() {
    _unitsController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _submit() {
    final units = int.tryParse(_unitsController.text.trim());
    if (units == null || units <= 0) {
      setState(
        () => _validationError = 'Enter a positive whole number of units.',
      );
      return;
    }
    Navigator.of(context).pop(
      _ManualProgressDraft(units: units, note: _noteController.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Log manual goal progress'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _unitsController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Units (${widget.unitLabel ?? 'units'})',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _noteController,
            decoration: const InputDecoration(labelText: 'Note (optional)'),
          ),
          if (_validationError != null) ...[
            const SizedBox(height: 8),
            Text(
              _validationError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

class _SingleTextDialog extends StatefulWidget {
  const _SingleTextDialog({
    required this.title,
    required this.label,
    required this.confirmLabel,
    this.allowEmpty = false,
  });

  final String title;
  final String label;
  final String confirmLabel;
  final bool allowEmpty;

  @override
  State<_SingleTextDialog> createState() => _SingleTextDialogState();
}

class _SingleTextDialogState extends State<_SingleTextDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        decoration: InputDecoration(labelText: widget.label),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final value = _controller.text.trim();
            if (!widget.allowEmpty && value.isEmpty) return;
            Navigator.of(context).pop(value);
          },
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _PickHabitDialog extends StatefulWidget {
  const _PickHabitDialog({required this.habits});

  final List<UnifiedHabitSummary> habits;

  @override
  State<_PickHabitDialog> createState() => _PickHabitDialogState();
}

class _PickHabitDialogState extends State<_PickHabitDialog> {
  late String _selectedId = widget.habits.first.habitId;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Link habit to goal'),
      content: DropdownButtonFormField<String>(
        isExpanded: true,
        initialValue: _selectedId,
        decoration: const InputDecoration(labelText: 'Habit'),
        items: [
          for (final h in widget.habits)
            DropdownMenuItem(
              value: h.habitId,
              child: Text(h.name ?? h.habitId, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (value) {
          if (value != null) setState(() => _selectedId = value);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selectedId),
          child: const Text('Link'),
        ),
      ],
    );
  }
}

String _formatDate(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
