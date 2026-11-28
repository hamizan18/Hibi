import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/security/app_lock_service.dart';
import '../../../core/security/privacy_deletion_service.dart';
import '../../../core/security/security_providers.dart';
import '../../../core/services/app_clock.dart';
import '../../habits/application/counter_habit_providers.dart';
import '../../habits/data/unified_habit_registry.dart';
import '../../habits/domain/habit_schedule.dart';
import '../../reminders/application/reminder_providers.dart';
import '../../reminders/data/reminder_service.dart';
import '../application/data_providers.dart';
import '../data/backup_restore_service.dart';
import '../data/export_service.dart';

class _MoreSnapshot {
  const _MoreSnapshot({
    required this.lockConfig,
    required this.biometricAvailable,
    required this.reminders,
    required this.habits,
    required this.history,
  });

  final AppLockConfig lockConfig;
  final bool biometricAvailable;
  final List<HabitReminder> reminders;
  final List<UnifiedHabitSummary> habits;
  final List<BackupHistoryRecord> history;
}

/// Privacy, App Lock, Schedule-Aware Reminders, Encrypted Backup/Restore,
/// Private-by-Default Exports and Permanent Privacy Deletion controls on More.
class PrivacyRemindersDataView extends ConsumerStatefulWidget {
  const PrivacyRemindersDataView({super.key, required this.asOfDate});

  final LocalDate asOfDate;

  @override
  ConsumerState<PrivacyRemindersDataView> createState() =>
      _PrivacyRemindersDataViewState();
}

class _PrivacyRemindersDataViewState
    extends ConsumerState<PrivacyRemindersDataView> {
  bool _loading = true;
  Object? _error;
  _MoreSnapshot? _snapshot;
  bool _includePrivateInExport = false;
  int _idSeq = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  String _nextId(String prefix) {
    _idSeq++;
    final us = ref.read(appClockProvider).now().toUtc().microsecondsSinceEpoch;
    return '${prefix}_${us}_$_idSeq';
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lockService = ref.read(appLockServiceProvider);
      final reminderService = ref.read(reminderServiceProvider);
      final backupService = ref.read(backupRestoreServiceProvider);
      final registry = ref.read(unifiedHabitRegistryReaderProvider);

      final lockConfig = await lockService.readConfig();
      final bioAvailable = await lockService.isBiometricAvailable();
      final reminders = await reminderService.readAllReminders();
      final habits = await registry.readAll(asOfDate: widget.asOfDate);
      final history = await backupService.readHistory(limit: 20);

      if (!mounted) return;
      setState(() {
        _snapshot = _MoreSnapshot(
          lockConfig: lockConfig,
          biometricAvailable: bioAvailable,
          reminders: reminders,
          habits: habits,
          history: history,
        );
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

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<Directory> _exportDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'hibi_exports'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _openSetPinDialog() async {
    final pin = await showDialog<String>(
      context: context,
      builder: (_) => const _PinInputDialog(
        title: 'Set local App Lock PIN',
        label: 'New PIN (4-12 digits)',
        confirmLabel: 'Save PIN',
      ),
    );
    if (pin == null) return;
    try {
      await ref.read(appLockServiceProvider).configurePin(pin);
      await _reload();
      _snack('Local PIN enabled.');
    } catch (error) {
      _snack('Unable to set PIN: $error');
    }
  }

  Future<void> _openDisablePinDialog() async {
    final current = await showDialog<String>(
      context: context,
      builder: (_) => const _PinInputDialog(
        title: 'Disable App Lock PIN',
        label: 'Current PIN',
        confirmLabel: 'Disable PIN',
      ),
    );
    if (current == null) return;
    try {
      await ref.read(appLockServiceProvider).disablePin(current);
      await _reload();
      _snack('Local PIN disabled.');
    } catch (error) {
      _snack('Unable to disable PIN: $error');
    }
  }

  Future<void> _openAddReminderDialog(List<UnifiedHabitSummary> habits) async {
    if (habits.isEmpty) {
      _snack('Create a habit first before adding a reminder.');
      return;
    }
    final draft = await showDialog<_ReminderDraft>(
      context: context,
      builder: (_) => _AddReminderDialog(habits: habits),
    );
    if (draft == null) return;
    try {
      final created = await ref
          .read(reminderServiceProvider)
          .createReminder(
            id: _nextId('rem'),
            habitId: draft.habitId,
            hour: draft.hour,
            minute: draft.minute,
            allowSensitiveText: draft.allowSensitiveText,
            customMessage: draft.customMessage,
          );
      await _reload();
      _snack('Reminder saved (mode: ${created.lastScheduleMode}).');
    } catch (error) {
      _snack('Unable to add reminder: $error');
    }
  }

  Future<void> _openCreateEncryptedBackupDialog() async {
    final passphrase = await showDialog<String>(
      context: context,
      builder: (_) => const _PassphraseDialog(
        title: 'Create encrypted backup',
        description:
            'Backups use PBKDF2-SHA256 + AES-GCM-256 encryption. PIN verifiers '
            'and biometric credentials are never exported.',
        confirmLabel: 'Create backup',
      ),
    );
    if (passphrase == null) return;
    try {
      final ts = ref
          .read(appClockProvider)
          .now()
          .toUtc()
          .millisecondsSinceEpoch;
      final fileName = 'hibi_backup_$ts.enc.json';
      final envelope = await ref
          .read(backupRestoreServiceProvider)
          .createEncryptedBackup(passphrase: passphrase, fileName: fileName);
      final dir = await _exportDir();
      final file = File(p.join(dir.path, fileName));
      await file.writeAsString(envelope);
      await _reload();
      _snack('Encrypted backup saved: $fileName');
    } catch (error) {
      _snack('Backup failed: $error');
    }
  }

  Future<void> _openRestoreBackupDialog() async {
    final dir = await _exportDir();
    final files =
        (await dir.list().toList())
            .whereType<File>()
            .where((f) => f.path.endsWith('.enc.json'))
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    if (files.isEmpty) {
      _snack('No encrypted backup files found in local exports folder.');
      return;
    }
    if (!mounted) return;
    final pick = await showDialog<_RestoreSelection>(
      context: context,
      builder: (_) => _SelectRestoreFileDialog(files: files),
    );
    if (pick == null) return;
    try {
      final envelope = await pick.file.readAsString();
      final service = ref.read(backupRestoreServiceProvider);
      final preview = await service.previewBackup(
        encryptedEnvelope: envelope,
        passphrase: pick.passphrase,
      );
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Confirm atomic full restore'),
          content: Text(
            'Schema version: v${preview.schemaVersion}\n'
            'Total rows: ${preview.totalRows}\n'
            'Created (UTC): ${preview.createdAtUtc.toIso8601String()}\n\n'
            'Restoring replaces all current local data atomically after '
            'saving a recoverable pre-restore encrypted snapshot.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Confirm full restore'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      final outcome = await service.restoreFromBackup(
        encryptedEnvelope: envelope,
        passphrase: pick.passphrase,
        confirmFullReplace: true,
        fileName: p.basename(pick.file.path),
      );
      final preName =
          'hibi_pre_restore_${ref.read(appClockProvider).now().toUtc().millisecondsSinceEpoch}.enc.json';
      await File(p.join(dir.path, preName))
          .writeAsString(outcome.preRestoreBackupEnvelope);
      await _reload();
      _snack(
        'Restored ${outcome.restoredTotalRows} rows. Pre-restore snapshot: $preName',
      );
    } catch (error) {
      _snack('Restore failed (original data preserved): $error');
    }
  }

  Future<void> _runExport(String format) async {
    try {
      final exportService = ref.read(exportServiceProvider);
      final dir = await _exportDir();
      final ts = ref
          .read(appClockProvider)
          .now()
          .toUtc()
          .millisecondsSinceEpoch;
      if (format == 'json') {
        final content = await exportService.exportJson(
          asOfDate: widget.asOfDate,
          includePrivate: _includePrivateInExport,
        );
        final name = 'hibi_export_$ts.json';
        await File(p.join(dir.path, name)).writeAsString(content);
        await _reload();
        _snack('Unencrypted JSON exported: $name');
      } else if (format == 'csv') {
        final bundle = await exportService.exportCsvBundle(
          asOfDate: widget.asOfDate,
          includePrivate: _includePrivateInExport,
        );
        final prefix = 'hibi_export_$ts';
        await File(p.join(dir.path, '${prefix}_habits.csv'))
            .writeAsString(bundle.habitsCsv);
        await File(p.join(dir.path, '${prefix}_finance.csv'))
            .writeAsString(bundle.financeTransactionsCsv);
        await File(p.join(dir.path, '${prefix}_journal.csv'))
            .writeAsString(bundle.journalCsv);
        await File(p.join(dir.path, '${prefix}_goals.csv'))
            .writeAsString(bundle.goalsCsv);
        await _reload();
        _snack('Unencrypted CSV bundle exported ($prefix*.csv)');
      } else if (format == 'pdf') {
        final bytes = await exportService.exportPdfBytes(
          asOfDate: widget.asOfDate,
          includePrivate: _includePrivateInExport,
        );
        final name = 'hibi_report_$ts.pdf';
        await File(p.join(dir.path, name)).writeAsBytes(bytes);
        await _reload();
        _snack('Unencrypted PDF exported: $name');
      }
    } catch (error) {
      _snack('Export failed: $error');
    }
  }

  Future<void> _openPermanentDeleteHabitDialog(
    List<UnifiedHabitSummary> habits,
  ) async {
    if (habits.isEmpty) {
      _snack('No habits available to delete.');
      return;
    }
    final request = await showDialog<({String habitId, String phrase})>(
      context: context,
      builder: (_) => _PermanentDeleteHabitDialog(habits: habits),
    );
    if (request == null) return;
    try {
      await ref
          .read(privacyDeletionServiceProvider)
          .permanentlyDeleteHabit(
            habitId: request.habitId,
            confirmationPhrase: request.phrase,
          );
      await _reload();
      _snack(
        'Habit and all related audit/derived records permanently deleted.',
      );
    } catch (error) {
      _snack('Permanent deletion failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _snapshot == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('Loading settings…'),
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
                'Unable to load privacy & data controls',
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
    final lock = snapshot.lockConfig;
    final habitNames = {
      for (final h in snapshot.habits)
        h.habitId: (h.metadata?.isPrivate ?? true)
            ? 'Private habit'
            : (h.name ?? h.habitId),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Privacy & App Lock Card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Privacy & App Lock',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'App Lock protects ordinary UI access using a salted PBKDF2-SHA256 '
                  'PIN verifier in Android Keystore. Local SQLite is not encrypted at rest.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (!lock.isPinEnabled)
                      FilledButton.icon(
                        onPressed: _openSetPinDialog,
                        icon: const Icon(Icons.lock_outline),
                        label: const Text('Set local PIN'),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: _openDisablePinDialog,
                        icon: const Icon(Icons.lock_open),
                        label: const Text('Disable PIN'),
                      ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Biometric unlock'),
                  subtitle: Text(
                    snapshot.biometricAvailable
                        ? 'Use Android BiometricPrompt when PIN is enabled.'
                        : 'Biometrics unavailable or not enrolled on this device.',
                  ),
                  value: lock.isBiometricEnabled,
                  onChanged: lock.isPinEnabled && snapshot.biometricAvailable
                      ? (v) async {
                          try {
                            await ref
                                .read(appLockServiceProvider)
                                .setBiometricEnabled(v);
                            await _reload();
                          } catch (error) {
                            _snack('$error');
                          }
                        }
                      : null,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Lock on app resume'),
                  value: lock.lockOnResume,
                  onChanged: lock.isPinEnabled
                      ? (v) async {
                          await ref
                              .read(appLockServiceProvider)
                              .setLockOnResume(v);
                          await _reload();
                        }
                      : null,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Hide recent-app preview (FLAG_SECURE)'),
                  value: lock.protectRecentAppPreview || lock.isPinEnabled,
                  onChanged: lock.isPinEnabled
                      ? null
                      : (v) async {
                          await ref
                              .read(appLockServiceProvider)
                              .setProtectRecentAppPreview(v);
                          await _reload();
                        },
                ),
                const Divider(),
                Text(
                  'Permanent Privacy Deletion',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                Text(
                  'Permanently removes source, audit and derived records.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () =>
                      _openPermanentDeleteHabitDialog(snapshot.habits),
                  icon: const Icon(Icons.delete_forever_outlined),
                  label: const Text('Permanently delete a habit'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // 2. Local Schedule-Aware Reminders Card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Local Habit Reminders',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  ReminderService.androidLimitationNotice,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => _openAddReminderDialog(snapshot.habits),
                      icon: const Icon(Icons.notifications_active_outlined),
                      label: const Text('Add reminder'),
                    ),
                    OutlinedButton(
                      onPressed: () async {
                        final granted = await ref
                            .read(reminderServiceProvider)
                            .requestPermission();
                        await ref.read(reminderServiceProvider).rescheduleAll();
                        await _reload();
                        _snack(
                          granted
                              ? 'Notification permission granted.'
                              : 'Notification permission not granted.',
                        );
                      },
                      child: const Text('Request permission'),
                    ),
                    OutlinedButton(
                      onPressed: () async {
                        await ref.read(reminderServiceProvider).rescheduleAll();
                        await _reload();
                        _snack('Reminders rescheduled.');
                      },
                      child: const Text('Reschedule all'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (snapshot.reminders.isEmpty)
                  const Text('No reminders configured yet.')
                else
                  for (final r in snapshot.reminders)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        '${r.formattedTime} • ${habitNames[r.habitId] ?? r.habitId}',
                      ),
                      subtitle: Text(
                        'Mode: ${r.lastScheduleMode} • '
                        '${r.allowSensitiveText ? 'Sensitive text allowed' : 'Generic text for private habits'}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(
                            value: r.isEnabled,
                            onChanged: (v) async {
                              await ref
                                  .read(reminderServiceProvider)
                                  .setReminderEnabled(r.id, v);
                              await _reload();
                            },
                          ),
                          IconButton(
                            tooltip: 'Delete reminder',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await ref
                                  .read(reminderServiceProvider)
                                  .deleteReminder(r.id);
                              await _reload();
                            },
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // 3. Encrypted Backup, Atomic Restore & Exports Card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Backup, Restore & Exports',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  ExportService.unencryptedExportWarning,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _openCreateEncryptedBackupDialog,
                      icon: const Icon(Icons.enhanced_encryption_outlined),
                      label: const Text('Encrypted backup'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _openRestoreBackupDialog,
                      icon: const Icon(Icons.restore),
                      label: const Text('Restore backup'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Include private records in exports'),
                  subtitle: const Text(
                    'Off by default so private habits, journals and goals stay excluded.',
                  ),
                  value: _includePrivateInExport,
                  onChanged: (v) => setState(() => _includePrivateInExport = v),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () => _runExport('json'),
                      child: const Text('Export JSON'),
                    ),
                    OutlinedButton(
                      onPressed: () => _runExport('csv'),
                      child: const Text('Export CSV'),
                    ),
                    OutlinedButton(
                      onPressed: () => _runExport('pdf'),
                      child: const Text('Export PDF'),
                    ),
                  ],
                ),
                if (snapshot.history.isNotEmpty) ...[
                  const Divider(),
                  Text(
                    'Recent Data Operations (${snapshot.history.length})',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  for (final item in snapshot.history.take(8))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('${item.operation} (${item.format})'),
                      subtitle: Text(item.summaryNote ?? ''),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PinInputDialog extends StatefulWidget {
  const _PinInputDialog({
    required this.title,
    required this.label,
    required this.confirmLabel,
  });

  final String title;
  final String label;
  final String confirmLabel;

  @override
  State<_PinInputDialog> createState() => _PinInputDialogState();
}

class _PinInputDialogState extends State<_PinInputDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _controller.text.trim();
    try {
      PinVerifier.validatePinFormat(pin);
      Navigator.of(context).pop(pin);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: widget.label),
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
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({
    required this.title,
    required this.description,
    required this.confirmLabel,
  });

  final String title;
  final String description;
  final String confirmLabel;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final pass = _controller.text;
    if (pass.length < BackupRestoreService.minPassphraseLength) {
      setState(
        () => _error =
            'Passphrase must be at least ${BackupRestoreService.minPassphraseLength} characters.',
      );
      return;
    }
    Navigator.of(context).pop(pass);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.description),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Backup passphrase (min 8 chars)',
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
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

class _RestoreSelection {
  const _RestoreSelection({required this.file, required this.passphrase});

  final File file;
  final String passphrase;
}

class _SelectRestoreFileDialog extends StatefulWidget {
  const _SelectRestoreFileDialog({required this.files});

  final List<File> files;

  @override
  State<_SelectRestoreFileDialog> createState() =>
      _SelectRestoreFileDialogState();
}

class _SelectRestoreFileDialogState extends State<_SelectRestoreFileDialog> {
  late File _selected = widget.files.first;
  final _passphraseController = TextEditingController();

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Restore encrypted backup'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<File>(
            isExpanded: true,
            initialValue: _selected,
            decoration: const InputDecoration(labelText: 'Backup file'),
            items: [
              for (final f in widget.files)
                DropdownMenuItem(
                  value: f,
                  child: Text(
                    p.basename(f.path),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _selected = v);
            },
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _passphraseController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Passphrase'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _RestoreSelection(
              file: _selected,
              passphrase: _passphraseController.text,
            ),
          ),
          child: const Text('Preview restore'),
        ),
      ],
    );
  }
}

class _ReminderDraft {
  const _ReminderDraft({
    required this.habitId,
    required this.hour,
    required this.minute,
    required this.allowSensitiveText,
    this.customMessage,
  });

  final String habitId;
  final int hour;
  final int minute;
  final bool allowSensitiveText;
  final String? customMessage;
}

class _AddReminderDialog extends StatefulWidget {
  const _AddReminderDialog({required this.habits});

  final List<UnifiedHabitSummary> habits;

  @override
  State<_AddReminderDialog> createState() => _AddReminderDialogState();
}

class _AddReminderDialogState extends State<_AddReminderDialog> {
  late String _habitId = widget.habits.first.habitId;
  final _hourController = TextEditingController(text: '08');
  final _minuteController = TextEditingController(text: '00');
  final _messageController = TextEditingController();
  bool _allowSensitiveText = false;
  String? _error;

  @override
  void dispose() {
    _hourController.dispose();
    _minuteController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  void _submit() {
    final hour = int.tryParse(_hourController.text.trim());
    final minute = int.tryParse(_minuteController.text.trim());
    if (hour == null || hour < 0 || hour > 23) {
      setState(() => _error = 'Hour must be 0..23.');
      return;
    }
    if (minute == null || minute < 0 || minute > 59) {
      setState(() => _error = 'Minute must be 0..59.');
      return;
    }
    Navigator.of(context).pop(
      _ReminderDraft(
        habitId: _habitId,
        hour: hour,
        minute: minute,
        allowSensitiveText: _allowSensitiveText,
        customMessage: _messageController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add habit reminder'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: _habitId,
              decoration: const InputDecoration(labelText: 'Habit'),
              items: [
                for (final h in widget.habits)
                  DropdownMenuItem(
                    value: h.habitId,
                    child: Text(
                      (h.metadata?.isPrivate ?? true)
                          ? 'Private habit (${h.habitId})'
                          : (h.name ?? h.habitId),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _habitId = v);
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _hourController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Hour (0-23)'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _minuteController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Minute (0-59)',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _messageController,
              decoration: const InputDecoration(
                labelText: 'Custom message (optional)',
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow sensitive text for private habit'),
              subtitle: const Text('Off by default (generic check-in text).'),
              value: _allowSensitiveText,
              onChanged: (v) =>
                  setState(() => _allowSensitiveText = v ?? false),
            ),
            if (_error != null)
              Text(
                _error!,
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

class _PermanentDeleteHabitDialog extends StatefulWidget {
  const _PermanentDeleteHabitDialog({required this.habits});

  final List<UnifiedHabitSummary> habits;

  @override
  State<_PermanentDeleteHabitDialog> createState() =>
      _PermanentDeleteHabitDialogState();
}

class _PermanentDeleteHabitDialogState
    extends State<_PermanentDeleteHabitDialog> {
  late String _habitId = widget.habits.first.habitId;
  final _phraseController = TextEditingController();

  @override
  void dispose() {
    _phraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Permanent privacy deletion'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: _habitId,
              decoration: const InputDecoration(labelText: 'Habit to delete'),
              items: [
                for (final h in widget.habits)
                  DropdownMenuItem(
                    value: h.habitId,
                    child: Text(
                      h.name ?? h.habitId,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _habitId = v);
              },
            ),
            const SizedBox(height: 12),
            const Text(
              'This permanently removes the habit, all occurrences, audit '
              'snapshots, reminders and XP entries. Type '
              '"${PrivacyDeletionService.confirmDeleteHabitPhrase}" to confirm:',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _phraseController,
              decoration: const InputDecoration(
                labelText: 'Confirmation phrase',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context)
              .pop((habitId: _habitId, phrase: _phraseController.text.trim())),
          child: const Text('Delete permanently'),
        ),
      ],
    );
  }
}
