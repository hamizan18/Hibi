import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/app_clock.dart';
import '../../habits/data/unified_habit_registry.dart';
import '../application/gamification_providers.dart';
import '../data/gamification_service.dart';
import '../domain/gamification_models.dart';

/// User-facing Gamification section (XP ledger, levels, deterministic
/// achievements with preserved unlock history, custom attributes, opt-out and
/// reward history).
class GamificationSection extends ConsumerStatefulWidget {
  const GamificationSection({super.key, required this.habits});

  final List<UnifiedHabitSummary> habits;

  @override
  ConsumerState<GamificationSection> createState() =>
      _GamificationSectionState();
}

class _GamificationSectionState extends ConsumerState<GamificationSection> {
  bool _loading = true;
  Object? _error;
  GamificationSnapshot? _snapshot;
  int _idSeq = 0;

  @override
  void initState() {
    super.initState();
    _reconcileAndLoad();
  }

  String _nextId(String prefix) {
    _idSeq++;
    final us = ref.read(appClockProvider).now().toUtc().microsecondsSinceEpoch;
    return '${prefix}_${us}_$_idSeq';
  }

  Future<void> _reconcileAndLoad() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await ref
          .read(gamificationServiceProvider)
          .reconcileAll();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _toggleEnabled(bool enabled) async {
    try {
      await ref
          .read(gamificationServiceProvider)
          .setGamificationEnabled(enabled);
      await _reconcileAndLoad();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to update setting: $error')),
      );
    }
  }

  Future<void> _openCreateAttributeDialog() async {
    final draft = await showDialog<_AttributeDraft>(
      context: context,
      builder: (_) => const _CreateAttributeDialog(),
    );
    if (draft == null) return;
    try {
      await ref
          .read(gamificationServiceProvider)
          .createAttribute(
            id: _nextId('attr'),
            name: draft.name,
            description: draft.description,
          );
      await _reconcileAndLoad();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to create attribute: $error')),
      );
    }
  }

  Future<void> _openLinkHabitDialog(AttributeActivitySummary summary) async {
    // Only public, reward-eligible habits can link to attributes so private
    // activity never leaks into attribute summaries.
    final eligible = widget.habits
        .where(
          (h) =>
              h.metadata != null &&
              !h.metadata!.isPrivate &&
              h.metadata!.includeInRewards &&
              !summary.linkedHabitIds.contains(h.habitId),
        )
        .toList();
    if (eligible.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No unlinked public reward-eligible habits available.'),
        ),
      );
      return;
    }
    final habitId = await showDialog<String>(
      context: context,
      builder: (_) => _LinkHabitToAttributeDialog(habits: eligible),
    );
    if (habitId == null) return;
    try {
      await ref
          .read(gamificationServiceProvider)
          .linkHabitToAttribute(
            habitId: habitId,
            attributeId: summary.attribute.id,
          );
      await _reconcileAndLoad();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Unable to link habit: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _snapshot == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
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
                'Unable to load rewards',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text('$_error'),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _reconcileAndLoad,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final snapshot = _snapshot!;
    final level = snapshot.levelProgress;
    final habitNames = {
      for (final h in widget.habits)
        if (h.metadata != null && !h.metadata!.isPrivate)
          h.habitId: h.name ?? h.habitId,
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
                  'Level ${level.level} • ${level.totalXp} XP',
                  key: const Key('gamification-level-heading'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: level.progressRatio),
                const SizedBox(height: 6),
                Text(
                  '${level.xpIntoCurrentLevel} / ${level.xpRequiredForNextLevel} XP to Level ${level.level + 1} '
                  '(rule v${GamificationRules.currentRuleVersion}: 10 XP completed, 5 XP recovered)',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  GamificationRules.nonMoralizingNotice,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enable XP & achievements'),
                  subtitle: const Text(
                    'Opt out anytime. Finance spending/income and private habits never earn XP.',
                  ),
                  value: snapshot.isEnabled,
                  onChanged: _toggleEnabled,
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _reconcileAndLoad,
                  icon: const Icon(Icons.sync),
                  label: const Text('Reconcile rewards'),
                ),
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
                  'Achievements',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Deterministic badges — unlock history is preserved even if a correction later invalidates an achievement.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (final ach in snapshot.achievements)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(
                      ach.isCurrentlyValid
                          ? Icons.emoji_events
                          : ach.isUnlockedEver
                          ? Icons.history
                          : Icons.lock_outline,
                    ),
                    title: Text(ach.definition.title),
                    subtitle: Text(
                      '${ach.definition.description}\n'
                      'Status: ${ach.isCurrentlyValid
                          ? 'Unlocked (valid)'
                          : ach.isUnlockedEver
                          ? 'Previously unlocked (invalidated)'
                          : 'Locked'}',
                    ),
                    isThreeLine: true,
                  ),
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
                  'Custom Attributes',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Attributes reflect recorded habit activity only, never competence or moral worth.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                FilledButton.tonalIcon(
                  onPressed: _openCreateAttributeDialog,
                  icon: const Icon(Icons.add),
                  label: const Text('Add attribute'),
                ),
                const SizedBox(height: 10),
                if (snapshot.attributes.isEmpty)
                  const Text('No custom attributes configured yet.')
                else
                  for (final summary in snapshot.attributes) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${summary.attribute.name} — Lv ${summary.levelProgress.level} (${summary.totalActivityXp} XP)',
                      ),
                      subtitle: Text(
                        summary.attribute.description ??
                            'Linked habits: ${summary.linkedHabitIds.length}',
                      ),
                      trailing: OutlinedButton(
                        onPressed: () => _openLinkHabitDialog(summary),
                        child: const Text('Link habit'),
                      ),
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
                  'Reward History (${snapshot.ledgerEntries.length})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (snapshot.ledgerEntries.isEmpty)
                  const Text('No XP reward entries recorded yet.')
                else
                  for (final entry in snapshot.ledgerEntries.take(20))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        '${entry.xpDelta > 0 ? '+${entry.xpDelta}' : '${entry.xpDelta}'} XP • '
                        '${habitNames[entry.habitId] ?? entry.habitId}',
                      ),
                      subtitle: Text(
                        '${entry.localDate.year.toString().padLeft(4, '0')}-'
                        '${entry.localDate.month.toString().padLeft(2, '0')}-'
                        '${entry.localDate.day.toString().padLeft(2, '0')} • '
                        '${entry.entryKind.label} (${entry.statusSnapshot.label}, rule v${entry.ruleVersion})'
                        '${entry.reason != null ? ' • ${entry.reason}' : ''}',
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

class _AttributeDraft {
  const _AttributeDraft({required this.name, this.description});

  final String name;
  final String? description;
}

class _CreateAttributeDialog extends StatefulWidget {
  const _CreateAttributeDialog();

  @override
  State<_CreateAttributeDialog> createState() => _CreateAttributeDialogState();
}

class _CreateAttributeDialogState extends State<_CreateAttributeDialog> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Attribute name is required.');
      return;
    }
    Navigator.of(context).pop(
      _AttributeDraft(
        name: name,
        description: _descriptionController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New custom attribute'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Attribute name (e.g. Consistency)',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _descriptionController,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
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
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}

class _LinkHabitToAttributeDialog extends StatefulWidget {
  const _LinkHabitToAttributeDialog({required this.habits});

  final List<UnifiedHabitSummary> habits;

  @override
  State<_LinkHabitToAttributeDialog> createState() =>
      _LinkHabitToAttributeDialogState();
}

class _LinkHabitToAttributeDialogState
    extends State<_LinkHabitToAttributeDialog> {
  late String _selectedId = widget.habits.first.habitId;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Link habit to attribute'),
      content: DropdownButtonFormField<String>(
        isExpanded: true,
        initialValue: _selectedId,
        decoration: const InputDecoration(labelText: 'Public eligible habit'),
        items: [
          for (final h in widget.habits)
            DropdownMenuItem(
              value: h.habitId,
              child: Text(h.name ?? h.habitId, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) {
          if (v != null) setState(() => _selectedId = v);
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
