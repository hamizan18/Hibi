import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/app/app.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/security/app_lock_service.dart';
import 'package:hibi/core/security/security_providers.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/data_management/data/backup_restore_service.dart';
import 'package:hibi/features/data_management/data/export_service.dart';
import 'package:hibi/features/finance/data/finance_service.dart';
import 'package:hibi/features/finance/domain/finance_models.dart';
import 'package:hibi/features/gamification/data/gamification_service.dart';
import 'package:hibi/features/growth/data/journal_service.dart';
import 'package:hibi/features/growth/domain/journal_models.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_analytics_reader.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_analytics.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/reminders/application/reminder_providers.dart';
import 'package:hibi/features/reminders/data/reminder_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

class _MutableClock implements AppClock {
  _MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

class _StubBio implements BiometricGateway {
  @override
  Future<bool> isBiometricAvailable() async => false;

  @override
  Future<bool> authenticate({required String localizedReason}) async => false;
}

class _StubWin implements PrivacyWindowGateway {
  @override
  Future<void> setSecureFlag(bool enabled) async {}
}

void main() {
  group('T-001: Offline-only & boundary verification', () {
    test('AndroidManifest has no INTERNET permission and pubspec has no backend/ads/AI SDKs', () async {
      final manifest = await File('android/app/src/main/AndroidManifest.xml')
          .readAsString();
      expect(manifest.contains('android.permission.INTERNET'), isFalse);
      expect(manifest.contains('ACCESS_FINE_LOCATION'), isFalse);
      expect(manifest.contains('ACCESS_COARSE_LOCATION'), isFalse);

      final pubspec = await File('pubspec.yaml').readAsString();
      for (final forbidden in [
        'firebase_',
        'supabase_',
        'google_mobile_ads',
        'openai',
        'google_generative_ai',
        'dio:',
      ]) {
        expect(pubspec.contains(forbidden), isFalse);
      }
    });
  });

  group('T-011: Midnight, leap year, year boundary and timezone stability', () {
    test('handles leap years (2024/2028) vs non-leap years (2025) and year rollover deterministically', () {
      // Leap day schedules: monthly day 29 skips Feb in 2025 unless lastDayFallback is true.
      final monthlySkip = MonthlyDaySchedule(
        start: LocalDate(2024, 1, 1),
        dayOfMonth: 29,
        lastDayFallback: false,
      );
      final monthlyFallback = MonthlyDaySchedule(
        start: LocalDate(2024, 1, 1),
        dayOfMonth: 29,
        lastDayFallback: true,
      );

      expect(monthlySkip.appliesOn(LocalDate(2024, 2, 29)), isTrue);
      expect(monthlySkip.appliesOn(LocalDate(2025, 2, 28)), isFalse);
      expect(monthlySkip.appliesOn(LocalDate(2028, 2, 29)), isTrue);
      expect(monthlyFallback.appliesOn(LocalDate(2025, 2, 28)), isTrue);

      // Japanese date formatting across all 7 weekdays + leap days + year rollover.
      expect(japaneseDate(DateTime(2024, 2, 29)), '2024年2月29日(木)');
      expect(japaneseDate(DateTime(2026, 12, 31)), '2026年12月31日(木)');
      expect(japaneseDate(DateTime(2027, 1, 1)), '2027年1月1日(金)');
      expect(japaneseDate(DateTime(2026, 11, 23)), '2026年11月23日(月)');
      expect(japaneseDate(DateTime(2026, 11, 24)), '2026年11月24日(火)');
      expect(japaneseDate(DateTime(2026, 11, 25)), '2026年11月25日(水)');
      expect(japaneseDate(DateTime(2026, 11, 28)), '2026年11月28日(土)');
      expect(japaneseDate(DateTime(2026, 11, 29)), '2026年11月29日(日)');
    });

    test('ISO local_date records are not reinterpreted when UTC clock offset changes', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      // Record near midnight in UTC vs later read with shifted UTC instant.
      final clock = _MutableClock(DateTime.utc(2026, 12, 31, 23, 55));
      final dec31 = LocalDate(2026, 12, 31);
      final jan1 = LocalDate(2027, 1, 1);

      await JournalService(db, clock).createEntry(
        id: 'j_nye',
        localDate: dec31,
        title: 'Year-end reflection',
        mood: JournalMood.good,
      );
      await FinanceService(db, clock).createWallet(
        id: 'w_tz',
        auditId: 'aw_tz',
        name: 'Wallet',
        openingBalanceIdr: 100000,
        openingDate: dec31,
      );
      await FinanceService(db, clock).createCategory(
        id: 'c_tz',
        auditId: 'ac_tz',
        name: 'Food',
        kind: FinanceCategoryKind.expense,
      );
      await FinanceService(db, clock).createTransaction(
        id: 'tx_nye',
        auditId: 'atx_nye',
        walletId: 'w_tz',
        categoryId: 'c_tz',
        type: FinanceTransactionType.expense,
        amountIdr: 25000,
        localDate: dec31,
      );

      // Simulate user traveling to another timezone on Jan 1 next year.
      clock.current = DateTime.utc(2027, 1, 1, 14, 0);

      final decEntries = await JournalService(
        db,
        clock,
      ).readEntries(startInclusive: dec31, endInclusive: dec31);
      expect(decEntries.single.localDate, dec31);

      final janReport = await FinanceService(
        db,
        clock,
      ).readDashboardSnapshot(startInclusive: jan1, endInclusive: jan1);
      // Dec 31 expense stays in Dec 31 cash flow (0 in Jan 1), while wallet balance carries 75,000 IDR.
      expect(janReport.report.periodExpenseIdr, 0);
      expect(janReport.report.totalRecordedWalletBalanceIdr, 75000);
    });
  });

  group(
    'T-012: Accessibility (320px + 2.0x text scale) & PDF Unicode safety',
    () {
      testWidgets(
        'all 5 tabs render cleanly at 320px width and 2.0x text scaling without exceptions',
        (tester) async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final clock = _MutableClock(DateTime(2026, 11, 27, 10, 0));

          tester.view.physicalSize = const Size(320, 720);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                databaseProvider.overrideWithValue(db),
                appClockProvider.overrideWithValue(clock),
                databaseInitializationProvider.overrideWith((ref) async {}),
                secureKeyValueStoreProvider.overrideWithValue(
                  InMemorySecureKeyValueStore(),
                ),
                biometricGatewayProvider.overrideWithValue(_StubBio()),
                privacyWindowGatewayProvider.overrideWithValue(_StubWin()),
                localNotificationGatewayProvider.overrideWithValue(
                  InMemoryNotificationGateway(),
                ),
              ],
              child: const MediaQuery(
                data: MediaQueryData(
                  size: Size(320, 720),
                  textScaler: TextScaler.linear(2.0),
                ),
                child: HibiApp(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          for (final label in [
            'History',
            'Finance',
            'Growth',
            'More',
            'Today',
          ]) {
            await tester.tap(find.text(label));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        },
      );

      test(
        'PDF export produces a document for a Japanese habit title',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final clock = _MutableClock(DateTime(2026, 11, 27, 9, 0));
          final today = LocalDate(2026, 11, 27);

          await CounterHabitWriter(db, clock).create(
            habitId: 'h_jp',
            versionId: 'v_jp',
            lifecycleEventId: 'l_jp',
            auditId: 'a_jp',
            name: 'Hibi 日々 Reading',
            effectiveDate: DateTime(2026, 11, 27),
            target: CounterTarget(count: 5, unit: 'pages'),
            schedule: DailySchedule(start: today),
          );
          await HabitMetadataStore(
            db,
          ).insert('v_jp', HabitMetadata(category: 'Daily', isPrivate: false));

          final bytes = await ExportService(
            db,
            clock,
          ).exportPdfBytes(asOfDate: today);
          expect(bytes.length, greaterThan(500));
          expect(utf8.decode(bytes.sublist(0, 5)), '%PDF-');
        },
      );
    },
  );

  group('T-013 & Performance: Full v1 -> v17 migration and multi-domain responsiveness', () {
    test('upgrades a genuine v1 SQLite database to v17 preserving app_settings and enforcing foreign keys', () async {
      final dir = await Directory.systemTemp.createTemp('hibi_v1_to_v17_');
      addTearDown(() => dir.delete(recursive: true));
      final dbFile = File(p.join(dir.path, 'hibi.sqlite'));

      final raw = sqlite.sqlite3.open(dbFile.path);
      try {
        raw.execute(
          'CREATE TABLE app_settings (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)',
        );
        raw.execute(
          "INSERT INTO app_settings (key, value) VALUES ('theme', 'dark')",
        );
        raw.execute('PRAGMA user_version = 1');
      } finally {
        raw.close();
      }

      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);

      final version = (await db.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version');
      expect(version, 17);
      expect(await db.getSetting('theme'), 'dark');

      final fkOn = (await db.customSelect('PRAGMA foreign_keys').getSingle())
          .read<int>('foreign_keys');
      expect(fkOn, 1);

      final fkErrors = await db.customSelect('PRAGMA foreign_key_check').get();
      expect(fkErrors, isEmpty);
    });

    test('evaluates 60 days of habits, 60 finance transactions, gamification reconciliation and encrypted backup quickly', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _MutableClock(DateTime(2026, 9, 1, 9, 0));
      final start = LocalDate(2026, 9, 1);

      await CounterHabitWriter(db, clock).create(
        habitId: 'h_perf',
        versionId: 'v_perf',
        lifecycleEventId: 'l_perf',
        auditId: 'a_perf',
        name: 'Daily Reading',
        effectiveDate: DateTime(2026, 9, 1),
        target: CounterTarget(count: 5, unit: 'pages'),
        schedule: DailySchedule(start: start),
      );
      await HabitMetadataStore(db).insert(
        'v_perf',
        HabitMetadata(
          category: 'Learning',
          isPrivate: false,
          includeInRewards: true,
        ),
      );

      final finance = FinanceService(db, clock);
      await finance.createWallet(
        id: 'w_perf',
        auditId: 'aw_perf',
        name: 'Main',
        openingBalanceIdr: 1000000,
        openingDate: start,
      );
      await finance.createCategory(
        id: 'c_perf',
        auditId: 'ac_perf',
        name: 'Expense',
        kind: FinanceCategoryKind.expense,
      );

      final actions = CounterTodayActionService(db, clock);
      final journal = JournalService(db, clock);
      for (var i = 0; i < 60; i++) {
        final d = DateTime(2026, 9, 1 + i, 10, 0);
        final ld = LocalDate(d.year, d.month, d.day);
        clock.current = d;
        await actions.recordTodayProgress(
          habitId: 'h_perf',
          occurrenceId: 'occ_$i',
          eventId: 'ev_$i',
          quantity: 5,
        );
        await finance.createTransaction(
          id: 'tx_$i',
          auditId: 'atx_$i',
          walletId: 'w_perf',
          categoryId: 'c_perf',
          type: FinanceTransactionType.expense,
          amountIdr: 10000,
          localDate: ld,
        );
        if (i < 30) {
          await journal.createEntry(
            id: 'j_$i',
            localDate: ld,
            reflectionText: 'Day $i note',
          );
        }
      }

      final end = LocalDate(2026, 10, 30);
      final sw = Stopwatch()..start();
      final analyticsSnap = await AnalyticsReportReader(db)
          .readDashboardSnapshot(
            startInclusive: start,
            endInclusive: end,
            asOfDate: end,
            filter: const HabitAnalyticsFilter(includePrivate: false),
            streakMode: StreakCompletionMode.completedAndRecovered,
          );
      final finSnap = await finance.readDashboardSnapshot(
        startInclusive: start,
        endInclusive: end,
      );
      final gamSnap = await GamificationService(db, clock).reconcileAll();
      final backup = await BackupRestoreService(
        db,
        clock,
      ).createEncryptedBackup(passphrase: 'perf-benchmark-pass');
      sw.stop();

      expect(analyticsSnap.report.totalCalendarDays, 60);
      expect(analyticsSnap.report.dailyCells.length, 60);
      expect(analyticsSnap.streaks.single.currentStreak, 60);
      expect(finSnap.report.totalRecordedWalletBalanceIdr, 400000);
      expect(gamSnap.levelProgress.totalXp, 600);
      expect(gamSnap.levelProgress.level, 4);
      expect(backup.isNotEmpty, isTrue);
      expect(sw.elapsedMilliseconds, lessThan(5000));
    });
  });
}
