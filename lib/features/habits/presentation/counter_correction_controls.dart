import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/counter_habit_providers.dart';
import '../data/counter_configuration_reader.dart';
import '../data/counter_correction_preview.dart';
import '../data/habit_analytics_reader.dart';
import '../data/unified_habit_registry.dart';
import '../domain/habit_schedule.dart';

/// User-facing workflow to preview and explicitly confirm a historical counter
/// target correction bound to a read-set snapshot.
class CounterCorrectionControls extends ConsumerStatefulWidget {
  const CounterCorrectionControls({
    super.key,
    required this.habit,
    required this.date,
    required this.showPrivateHistory,
    required this.onChanged,
  });

  final UnifiedHabitSummary habit;
  final LocalDate date;
  final bool showPrivateHistory;
  final VoidCallback onChanged;

  @override
  ConsumerState<CounterCorrectionControls> createState() =>
      _CounterCorrectionControlsState();
}

class _CounterCorrectionControlsState
    extends ConsumerState<CounterCorrectionControls> {
  final _random = Random.secure();
  final _proposedTarget = TextEditingController();
  final _reason = TextEditingController();

  CounterHabitConfiguration? _config;
  String? _selectedVersionId;
  bool _loading = true;
  bool _busy = false;
  bool _expanded = false;
  String? _error;
  int _generation = 0;
  BuildContext? _dialogContext;

  bool _isVisible(CounterVersionSnapshot version) =>
      widget.showPrivateHistory ||
      (version.metadata != null && !version.metadata!.isPrivate);

  String _id() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  String _formatDate(LocalDate d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CounterCorrectionControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.habit.habitId != widget.habit.habitId ||
        oldWidget.date.compareTo(widget.date) != 0 ||
        oldWidget.showPrivateHistory != widget.showPrivateHistory) {
      final dialogContext = _dialogContext;
      if (dialogContext != null) {
        _dialogContext = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (dialogContext.mounted) Navigator.of(dialogContext).pop(false);
        });
      }
      _busy = false;
      _expanded = false;
      _load();
    }
  }

  @override
  void dispose() {
    _generation++;
    _proposedTarget.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final config = await ref
          .read(counterConfigurationReaderProvider)
          .read(habitId: widget.habit.habitId, asOfDate: widget.date);
      if (!mounted || generation != _generation) return;
      final eligible = config.allVersions
          .where((v) => v.target != null && _isVisible(v))
          .toList();
      final chosen =
          config.effectiveVersion != null &&
              config.effectiveVersion!.target != null &&
              _isVisible(config.effectiveVersion!)
          ? config.effectiveVersion!
          : (eligible.isNotEmpty ? eligible.last : null);
      setState(() {
        _config = config;
        _selectedVersionId = chosen?.versionId;
        if (chosen?.target != null) {
          _proposedTarget.text = '${chosen!.target!.count}';
        }
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _config = null;
        _loading = false;
        _error = 'Could not load versions for historical correction.';
      });
    }
  }

  CounterVersionSnapshot? _selectedVersion() {
    final config = _config;
    if (config == null || _selectedVersionId == null) return null;
    for (final v in config.allVersions) {
      if (v.versionId == _selectedVersionId && v.target != null) return v;
    }
    return null;
  }

  Future<void> _previewAndConfirm() async {
    final version = _selectedVersion();
    if (_busy || _loading || version == null || version.target == null) return;
    if (!_isVisible(version)) {
      setState(() {
        _error = 'Reveal private habits before previewing a private version.';
      });
      return;
    }

    final text = _proposedTarget.text.trim();
    final count = RegExp(r'^[0-9]+$').hasMatch(text)
        ? int.tryParse(text)
        : null;
    if (count == null || count <= 0) {
      setState(() => _error = 'Enter a positive whole-number target count.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final habitId = widget.habit.habitId;
    final generation = _generation;
    final includePrivate = widget.showPrivateHistory;
    AnalyticsCorrectionImpactPreview impact;
    try {
      impact = await ref
          .read(analyticsCorrectionImpactReaderProvider)
          .previewImpact(
            CounterTargetCorrectionProposal(
              habitId: habitId,
              versionId: version.versionId,
              proposedTargetCount: count,
              proposedUnit: version.target!.unit,
              reason: _reason.text.trim().isEmpty ? null : _reason.text.trim(),
            ),
            includePrivate: includePrivate,
          );
    } on Object catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _busy = false;
        _error =
            'Correction preview rejected: ${e.toString().replaceFirst(RegExp(r'^.*?: '), '')}';
      });
      return;
    }
    final preview = impact.preview;

    if (!mounted || generation != _generation) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        _dialogContext = context;
        return AlertDialog(
          title: const Text('Confirm historical target correction?'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(preview.englishConfirmationSummary),
                const SizedBox(height: 8),
                for (final occ in preview.affectedOccurrences)
                  Text(
                    '• ${_formatDate(occ.date)}: recorded ${occ.recordedTotal} '
                    '(${occ.originalProgressStatus.name} @ ${occ.originalTarget} -> '
                    '${occ.proposedProgressStatus.name} @ ${occ.proposedTarget})',
                  ),
                if (impact.dateScoreImpacts.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('Recalculated daily weighted score impact:'),
                  for (final s in impact.dateScoreImpacts)
                    Text(
                      '• ${_formatDate(s.date)}: '
                      '${s.beforeScorePercent == null ? 'No Data' : '${s.beforeScorePercent!.toStringAsFixed(1)}%'} -> '
                      '${s.afterScorePercent == null ? 'No Data' : '${s.afterScorePercent!.toStringAsFixed(1)}%'}',
                    ),
                ],
                const SizedBox(height: 8),
                Text(
                  'Recalculated streak (completed + recovered): '
                  '${impact.beforeStreakWithRecovery.currentStreak} -> '
                  '${impact.afterStreakWithRecovery.currentStreak} '
                  '(completed only: ${impact.beforeStreakCompletedOnly.currentStreak} -> '
                  '${impact.afterStreakCompletedOnly.currentStreak})',
                ),
                const SizedBox(height: 8),
                const Text(
                  'Audit preimages are stored locally in unencrypted SQLite. '
                  'Reward and achievement recalculation engines are not implemented.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm correction'),
            ),
          ],
        );
      },
    );
    _dialogContext = null;

    if (!mounted || generation != _generation) return;
    if (confirmed != true) {
      setState(() => _busy = false);
      return;
    }

    try {
      await ref
          .read(counterCorrectionWriterProvider)
          .commit(correctionAuditId: _id(), confirmedPreview: impact.preview);
      if (!mounted) return;
      _expanded = false;
      _reason.clear();
      widget.onChanged();
      if (mounted && widget.habit.habitId == habitId) {
        await _load();
      }
    } on Object {
      if (!mounted || widget.habit.habitId != habitId) return;
      await _load();
      if (mounted && widget.habit.habitId == habitId) {
        setState(() {
          _error = 'Correction preview became stale or conflicted with recent changes. Generate a fresh preview.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    final eligible = config == null
        ? const <CounterVersionSnapshot>[]
        : config.allVersions
              .where((v) => v.target != null && _isVisible(v))
              .toList();
    final selected = _selectedVersion();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: !_loading && !_busy && eligible.isNotEmpty
              ? () => setState(() => _expanded = !_expanded)
              : null,
          child: Text(
            _expanded ? 'Close target correction' : 'Correct historical target',
          ),
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_expanded && eligible.isNotEmpty) ...[
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: eligible.any((v) => v.versionId == _selectedVersionId)
                ? _selectedVersionId
                : eligible.last.versionId,
            decoration: const InputDecoration(labelText: 'Version to correct'),
            items: [
              for (final v in eligible)
                DropdownMenuItem(
                  value: v.versionId,
                  child: Text(
                    'Revision ${v.revision}: ${v.name} (${_formatDate(v.effectiveStart)} to ${v.effectiveEnd == null ? 'open' : _formatDate(v.effectiveEnd!)})',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _busy
                ? null
                : (id) {
                    setState(() {
                      _selectedVersionId = id;
                      final ver = _selectedVersion();
                      if (ver?.target != null) {
                        _proposedTarget.text = '${ver!.target!.count}';
                      }
                    });
                  },
          ),
          if (selected?.target != null)
            Text(
              'Current version target: ${selected!.target!.count} ${selected.target!.unit} (unit cannot be changed)',
            ),
          TextField(
            controller: _proposedTarget,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Proposed target count',
            ),
          ),
          TextField(
            controller: _reason,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Correction reason (optional)',
            ),
          ),
          ElevatedButton(
            onPressed: _busy ? null : _previewAndConfirm,
            child: const Text('Preview target correction'),
          ),
        ],
      ],
    );
  }
}
