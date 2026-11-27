import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/security/app_lock_service.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/data_management/data/backup_restore_service.dart';
import 'package:hibi/features/data_management/data/export_service.dart';
import 'package:hibi/features/growth/data/journal_service.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/reminders/data/reminder_service.dart';
import 'package:path/path.dart' as p;

class _AcceptanceClock implements AppClock {
  _AcceptanceClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

class _NoBio implements BiometricGateway {
  @override
  Future<bool> isBiometricAvailable() async => false;

  @override
  Future<bool> authenticate({required String localizedReason}) async => false;
}

class _NoWin implements PrivacyWindowGateway {
  bool secure = false;

  @override
  Future<void> setSecureFlag(bool enabled) async {
    secure = enabled;
  }
}

/// T-010 acceptance test:
/// Private records absent from default exports; app lock; valid encrypted
/// backup round trip across disk reopen, invalid restore rejection preserving
/// original data; schedule-aware reminders with generic private text & inexact
/// Android fallback.
void main() {
  test('T-010: privacy controls, app lock, encrypted backup/restore and safe reminders survive disk reopen', () async {
    final dir = await Directory.systemTemp.createTemp('hibi_m6_t010_');
    addTearDown(() => dir.delete(recursive: true));
    final dbFile = File(p.join(dir.path, 'hibi.sqlite'));
    final clock = _AcceptanceClock(DateTime(2026, 11, 27, 7, 0));
    final today = LocalDate(2026, 11, 27);

    final secureStore = InMemorySecureKeyValueStore();
    final win = _NoWin();
    final lock = AppLockService(
      secureStore: secureStore,
      biometricGateway: _NoBio(),
      privacyWindowGateway: win,
      clock: clock,
    );
    await lock.configurePin('4826');
    expect(win.secure, isTrue);

    final db1 = AppDatabase(NativeDatabase(dbFile));
    await CounterHabitWriter(db1, clock).create(
      habitId: 'h_priv',
      versionId: 'v_priv',
      lifecycleEventId: 'l_priv',
      auditId: 'a_priv',
      name: 'Private Sensitive Habit',
      effectiveDate: DateTime(2026, 11, 27),
      target: CounterTarget(count: 1, unit: 'time'),
      schedule: DailySchedule(start: today),
    );
    await HabitMetadataStore(db1)
        .insert('v_priv', HabitMetadata(category: 'Private', isPrivate: true));
    await JournalService(db1, clock).createEntry(
      id: 'j_pub',
      localDate: today,
      title: 'Public Summary',
      reflectionText: 'Calm evening.',
      isPrivate: false,
    );
    await JournalService(db1, clock).createEntry(
      id: 'j_priv',
      localDate: today,
      title: 'Private Diary Entry',
      reflectionText: 'Never export by default.',
      isPrivate: true,
    );

    final notifGateway = InMemoryNotificationGateway(
      permissionGranted: true,
      exactAlarmsAvailable: false,
    );
    final rem = await ReminderService(
      db1,
      clock,
      notifGateway,
    ).createReminder(id: 'r1', habitId: 'h_priv', hour: 8, minute: 0);
    expect(rem.lastScheduleMode, 'inexact');
    expect(
      notifGateway.scheduled.values.single.title,
      ReminderService.genericPrivateTitle,
    );

    // Default exports omit all private content.
    final exportedJson = await ExportService(
      db1,
      clock,
    ).exportJson(asOfDate: today);
    expect(exportedJson.contains('Public Summary'), isTrue);
    expect(exportedJson.contains('Private Sensitive Habit'), isFalse);
    expect(exportedJson.contains('Private Diary Entry'), isFalse);

    // Encrypted backup never contains PIN verifier or plaintext secrets.
    final backupEnvelope = await BackupRestoreService(
      db1,
      clock,
    ).createEncryptedBackup(passphrase: 'strong-passphrase-2026');
    expect(backupEnvelope.contains('4826'), isFalse);
    expect(backupEnvelope.contains('Private Sensitive Habit'), isFalse);
    await db1.close();

    // Corrupt restore attempt on reopened DB leaves original data intact.
    final db2 = AppDatabase(NativeDatabase(dbFile));
    await expectLater(
      () => BackupRestoreService(db2, clock).restoreFromBackup(
        encryptedEnvelope: '{"format":"bad"}',
        passphrase: 'strong-passphrase-2026',
        confirmFullReplace: true,
      ),
      throwsFormatException,
    );
    final stillThere = await JournalService(
      db2,
      clock,
    ).readEntries(includePrivate: true);
    expect(stillThere.length, 2);
    await db2.close();

    // Restore into a second isolated disk database and reopen to verify persistence.
    final restoreFile = File(p.join(dir.path, 'hibi_restored.sqlite'));
    final dbRestored1 = AppDatabase(NativeDatabase(restoreFile));
    await BackupRestoreService(dbRestored1, clock).restoreFromBackup(
      encryptedEnvelope: backupEnvelope,
      passphrase: 'strong-passphrase-2026',
      confirmFullReplace: true,
    );
    await dbRestored1.close();

    final dbRestored2 = AppDatabase(NativeDatabase(restoreFile));
    addTearDown(dbRestored2.close);
    final reopenedJournals = await JournalService(
      dbRestored2,
      clock,
    ).readEntries(includePrivate: true);
    expect(reopenedJournals.length, 2);
    final reopenedReminders = await ReminderService(
      dbRestored2,
      clock,
      notifGateway,
    ).readAllReminders();
    expect(reopenedReminders.single.id, 'r1');

    // PIN verification still works cleanly.
    expect((await lock.verifyPin('4826')).unlocked, isTrue);
  });
}
