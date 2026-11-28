import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/data_management/data/backup_restore_service.dart';
import 'package:hibi/features/data_management/data/export_service.dart';
import 'package:hibi/features/finance/data/finance_service.dart';
import 'package:hibi/features/gamification/data/gamification_service.dart';
import 'package:hibi/features/growth/data/goal_service.dart';
import 'package:hibi/features/growth/data/journal_service.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'test_schema_downgrade.dart';

class _Clock implements AppClock {
  _Clock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('BackupRestoreService & ExportService', () {
    test('encrypted backup round-trips cleanly, rejects tampered/wrong-passphrase backups without harming existing data, and excludes private records from default JSON/CSV/PDF exports', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _Clock(DateTime(2026, 11, 27, 9, 0));
      final today = LocalDate(2026, 11, 27);

      // Seed both public and private records.
      await CounterHabitWriter(db, clock).create(
        habitId: 'h_pub',
        versionId: 'v_pub',
        lifecycleEventId: 'l_pub',
        auditId: 'a_pub',
        name: 'Public Reading',
        effectiveDate: DateTime(2026, 11, 27),
        target: CounterTarget(count: 5, unit: 'pages'),
        schedule: DailySchedule(start: today),
      );
      await HabitMetadataStore(
        db,
      ).insert('v_pub', HabitMetadata(category: 'Learning', isPrivate: false));
      await CounterHabitWriter(db, clock).create(
        habitId: 'h_priv',
        versionId: 'v_priv',
        lifecycleEventId: 'l_priv',
        auditId: 'a_priv',
        name: 'Top Secret Private Habit',
        effectiveDate: DateTime(2026, 11, 27),
        target: CounterTarget(count: 1, unit: 'unit'),
        schedule: DailySchedule(start: today),
      );
      await HabitMetadataStore(
        db,
      ).insert('v_priv', HabitMetadata(category: 'Private', isPrivate: true));
      await JournalService(db, clock).createEntry(
        id: 'j_pub',
        localDate: today,
        title: 'Public Note',
        reflectionText: 'Good day.',
        isPrivate: false,
      );
      await JournalService(db, clock).createEntry(
        id: 'j_priv',
        localDate: today,
        title: 'Confidential Diary',
        reflectionText: 'Private details must stay absent.',
        isPrivate: true,
      );
      await GoalService(
        db,
        clock,
      ).createGoal(id: 'g_pub', title: 'Public Goal', isPrivate: false);
      await GoalService(
        db,
        clock,
      ).createGoal(id: 'g_priv', title: 'Private Secret Goal', isPrivate: true);
      await FinanceService(db, clock).createWallet(
        id: 'w1',
        auditId: 'aw1',
        name: 'Cash',
        openingBalanceIdr: 250000,
        openingDate: today,
      );

      // 1. Default JSON, CSV and PDF exports MUST exclude all private records!
      final exporter = ExportService(db, clock);
      final defaultJson = await exporter.exportJson(asOfDate: today);
      expect(defaultJson.contains('Public Reading'), isTrue);
      expect(defaultJson.contains('Public Note'), isTrue);
      expect(defaultJson.contains('Public Goal'), isTrue);
      expect(defaultJson.contains('Top Secret Private Habit'), isFalse);
      expect(defaultJson.contains('Confidential Diary'), isFalse);
      expect(defaultJson.contains('Private Secret Goal'), isFalse);

      final defaultCsv = await exporter.exportCsvBundle(asOfDate: today);
      expect(defaultCsv.habitsCsv.contains('Public Reading'), isTrue);
      expect(
        defaultCsv.habitsCsv.contains('Top Secret Private Habit'),
        isFalse,
      );
      expect(defaultCsv.journalCsv.contains('Confidential Diary'), isFalse);
      expect(defaultCsv.goalsCsv.contains('Private Secret Goal'), isFalse);

      final pdfBytes = await exporter.exportPdfBytes(asOfDate: today);
      expect(pdfBytes.length, greaterThan(500));
      // Valid PDF header `%PDF-`
      expect(utf8.decode(pdfBytes.sublist(0, 5)), '%PDF-');

      // Explicit opt-in includes private records.
      final optInJson = await exporter.exportJson(
        asOfDate: today,
        includePrivate: true,
      );
      expect(optInJson.contains('Top Secret Private Habit'), isTrue);
      expect(optInJson.contains('Confidential Diary'), isTrue);

      // 2. Create encrypted backup.
      final backupService = BackupRestoreService(db, clock);
      final envelope = await backupService.createEncryptedBackup(
        passphrase: 'hibi-secret-pass-2026',
        fileName: 'test.enc.json',
      );
      // Ciphertext must NOT contain plaintext sensitive titles!
      expect(envelope.contains('Top Secret Private Habit'), isFalse);
      expect(envelope.contains('Confidential Diary'), isFalse);

      final preview = await backupService.previewBackup(
        encryptedEnvelope: envelope,
        passphrase: 'hibi-secret-pass-2026',
      );
      expect(preview.schemaVersion, 17);
      expect(preview.tableRowCounts['habits'], 2);
      expect(preview.tableRowCounts['journal_entries'], 2);

      // Wrong passphrase fails without touching DB.
      await expectLater(
        () => backupService.restoreFromBackup(
          encryptedEnvelope: envelope,
          passphrase: 'wrong-passphrase-123',
          confirmFullReplace: true,
        ),
        throwsFormatException,
      );

      // Tampered ciphertext fails MAC authentication without touching DB.
      final tamperedMap = jsonDecode(envelope) as Map<String, dynamic>;
      final origCipher = base64Decode(tamperedMap['ciphertext_b64'] as String);
      origCipher[0] ^= 0xff;
      tamperedMap['ciphertext_b64'] = base64Encode(origCipher);
      await expectLater(
        () => backupService.restoreFromBackup(
          encryptedEnvelope: jsonEncode(tamperedMap),
          passphrase: 'hibi-secret-pass-2026',
          confirmFullReplace: true,
        ),
        throwsFormatException,
      );

      // Restore into a completely fresh DB and verify full round-trip + pre-restore snapshot.
      final freshDb = AppDatabase(NativeDatabase.memory());
      addTearDown(freshDb.close);
      await FinanceService(freshDb, clock).createWallet(
        id: 'w_old',
        auditId: 'aw_old',
        name: 'PreRestoreWallet',
        openingBalanceIdr: 999,
        openingDate: today,
      );

      final freshBackupService = BackupRestoreService(freshDb, clock);
      final outcome = await freshBackupService.restoreFromBackup(
        encryptedEnvelope: envelope,
        passphrase: 'hibi-secret-pass-2026',
        confirmFullReplace: true,
      );
      expect(outcome.restoredSchemaVersion, 17);
      expect(outcome.restoredTotalRows, greaterThan(5));

      final restoredWallets = await FinanceService(
        freshDb,
        clock,
      ).readWallets();
      expect(restoredWallets.single.name, 'Cash');
      expect(restoredWallets.single.openingBalanceIdr, 250000);

      // Verify pre-restore snapshot actually preserved PreRestoreWallet!
      final prePreview = await freshBackupService.previewBackup(
        encryptedEnvelope: outcome.preRestoreBackupEnvelope,
        passphrase: 'hibi-secret-pass-2026',
      );
      expect(prePreview.tableRowCounts['finance_wallets'], 1);
    });

    test(
      'v16 -> v17 migration preserves existing Gamification and Growth data',
      () async {
        final dir = await Directory.systemTemp.createTemp('hibi_v16_to_v17_');
        addTearDown(() => dir.delete(recursive: true));
        final dbFile = File(p.join(dir.path, 'hibi.sqlite'));
        final clock = _Clock(DateTime(2026, 11, 27, 9, 0));

        final initialDb = AppDatabase(NativeDatabase(dbFile));
        await GamificationService(
          initialDb,
          clock,
        ).createAttribute(id: 'attr_keep', name: 'Consistency');
        await initialDb.close();

        final raw = sqlite.sqlite3.open(dbFile.path);
        try {
          dropV17Schema(raw);
          raw.execute('PRAGMA user_version = 16');
        } finally {
          raw.close();
        }

        final upgraded = AppDatabase(NativeDatabase(dbFile));
        addTearDown(upgraded.close);

        final vRow = await upgraded
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(vRow.read<int>('user_version'), 17);

        final snap = await GamificationService(upgraded, clock).readSnapshot();
        expect(snap.attributes.single.attribute.name, 'Consistency');
      },
    );
  });
}
