import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/finance/data/finance_service.dart';
import 'package:hibi/features/finance/domain/finance_models.dart';
import 'package:hibi/features/gamification/data/gamification_service.dart';
import 'package:hibi/features/gamification/domain/gamification_models.dart';
import 'package:hibi/features/growth/data/journal_service.dart';
import 'package:hibi/features/habits/data/counter_correction_preview.dart';
import 'package:hibi/features/habits/data/counter_correction_writer.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'test_schema_downgrade.dart';

class _MutableClock implements AppClock {
  _MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  group('GamificationService', () {
    test('grants one idempotent reward per eligible occurrence, excludes private/opt-out/finance, and reconciles on correction', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _MutableClock(DateTime(2026, 11, 26, 9, 0));
      final counterWriter = CounterHabitWriter(db, clock);
      final metadataStore = HabitMetadataStore(db);
      final todayActions = CounterTodayActionService(db, clock);
      final gamification = GamificationService(db, clock);
      final finance = FinanceService(db, clock);

      final day1 = LocalDate(2026, 11, 26);
      final day1Dt = DateTime(2026, 11, 26);

      // 1. Public reward-eligible counter habit
      await counterWriter.create(
        habitId: 'h_pub',
        versionId: 'v_pub',
        lifecycleEventId: 'l_pub',
        auditId: 'a_pub',
        name: 'Reading',
        effectiveDate: day1Dt,
        target: CounterTarget(count: 5, unit: 'pages'),
        schedule: DailySchedule(start: day1),
      );
      await metadataStore.insert(
        'v_pub',
        HabitMetadata(
          category: 'Learning',
          isPrivate: false,
          includeInRewards: true,
          recoveryEnabled: true,
        ),
      );

      // 2. Private habit (must NEVER earn XP or unlock achievements)
      await counterWriter.create(
        habitId: 'h_priv',
        versionId: 'v_priv',
        lifecycleEventId: 'l_priv',
        auditId: 'a_priv',
        name: 'Private Habit',
        effectiveDate: day1Dt,
        target: CounterTarget(count: 1, unit: 'time'),
        schedule: DailySchedule(start: day1),
      );
      await metadataStore.insert(
        'v_priv',
        HabitMetadata(
          category: 'Private',
          isPrivate: true,
          includeInRewards: true,
        ),
      );

      // 3. Public habit that opted out of rewards (includeInRewards: false)
      await counterWriter.create(
        habitId: 'h_optout',
        versionId: 'v_optout',
        lifecycleEventId: 'l_optout',
        auditId: 'a_optout',
        name: 'Spiritual Reading',
        effectiveDate: day1Dt,
        target: CounterTarget(count: 1, unit: 'session'),
        schedule: DailySchedule(start: day1),
      );
      await metadataStore.insert(
        'v_optout',
        HabitMetadata(
          category: 'Spiritual',
          isPrivate: false,
          includeInRewards: false,
        ),
      );

      // Log completed on all 3 habits + record a large Finance income.
      await todayActions.recordTodayProgress(
        habitId: 'h_pub',
        occurrenceId: 'occ_pub_1',
        eventId: 'ev_pub_1',
        quantity: 5,
      );
      await todayActions.recordTodayProgress(
        habitId: 'h_priv',
        occurrenceId: 'occ_priv_1',
        eventId: 'ev_priv_1',
        quantity: 1,
      );
      await todayActions.recordTodayProgress(
        habitId: 'h_optout',
        occurrenceId: 'occ_opt_1',
        eventId: 'ev_opt_1',
        quantity: 1,
      );
      await finance.createWallet(
        id: 'w1',
        auditId: 'aw1',
        name: 'Bank',
        openingBalanceIdr: 1000000,
        openingDate: day1,
      );
      await finance.createCategory(
        id: 'c_inc',
        auditId: 'ac1',
        name: 'Salary',
        kind: FinanceCategoryKind.income,
      );
      await finance.createTransaction(
        id: 'tx1',
        auditId: 'atx1',
        walletId: 'w1',
        categoryId: 'c_inc',
        type: FinanceTransactionType.income,
        amountIdr: 5000000,
        localDate: day1,
      );

      // First reconcile awards 10 XP ONLY for h_pub and unlocks first_step.
      final snap1 = await gamification.reconcileAll();
      expect(snap1.levelProgress.totalXp, 10);
      expect(snap1.ledgerEntries.length, 1);
      expect(snap1.ledgerEntries.single.habitId, 'h_pub');
      final firstStep1 = snap1.achievements.firstWhere(
        (a) => a.definition.key == AchievementCatalog.firstStep,
      );
      expect(firstStep1.isUnlockedEver, isTrue);
      expect(firstStep1.isCurrentlyValid, isTrue);

      // Repeated reconcile calls are strictly idempotent (zero duplicate XP/events).
      final snapRepeat = await gamification.reconcileAll();
      expect(snapRepeat.levelProgress.totalXp, 10);
      expect(snapRepeat.ledgerEntries.length, 1);

      // Historical counter target correction raises target from 5 -> 10 pages,
      // dropping occ_pub_1 from completed to partial -> atomically reconciles XP to 0
      // and invalidates first_step while PRESERVING its unlock history!
      clock.current = DateTime(2026, 11, 26, 11, 0);
      final preview = await CounterCorrectionPreviewer(db, clock).preview(
        CounterTargetCorrectionProposal(
          habitId: 'h_pub',
          versionId: 'v_pub',
          proposedTargetCount: 10,
          proposedUnit: 'pages',
          reason: 'Correct target to 10 pages',
        ),
      );
      await CounterCorrectionWriter(
        db,
        clock,
      ).commit(correctionAuditId: 'corr_1', confirmedPreview: preview);

      final snapAfterCorr = await gamification.readSnapshot();
      expect(snapAfterCorr.levelProgress.totalXp, 0);
      expect(
        snapAfterCorr.ledgerEntries.length,
        2,
      ); // +10 award, -10 reconciliation
      final firstStepAfter = snapAfterCorr.achievements.firstWhere(
        (a) => a.definition.key == AchievementCatalog.firstStep,
      );
      expect(firstStepAfter.isUnlockedEver, isTrue);
      expect(firstStepAfter.isCurrentlyValid, isFalse);
      expect(firstStepAfter.unlockedAtUtc, isNotNull);
      expect(firstStepAfter.invalidatedAtUtc, isNotNull);
      expect(firstStepAfter.history.map((e) => e.eventType).toList(), [
        AchievementHistoryEventType.unlocked,
        AchievementHistoryEventType.invalidated,
      ]);

      // Ledger and achievement history are immutable at SQLite trigger level.
      await expectLater(
        () => db.customStatement('DELETE FROM gamification_xp_ledger'),
        throwsException,
      );
      await expectLater(
        () =>
            db.customStatement('DELETE FROM gamification_achievement_history'),
        throwsException,
      );
    });

    test('awards 5 XP for eligible recovered prior-date occurrence and tracks custom attribute activity', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _MutableClock(DateTime(2026, 11, 26, 9, 0));
      final counterWriter = CounterHabitWriter(db, clock);
      final metadataStore = HabitMetadataStore(db);
      final todayActions = CounterTodayActionService(db, clock);
      final gamification = GamificationService(db, clock);

      final day1 = LocalDate(2026, 11, 26);
      await counterWriter.create(
        habitId: 'h_rec',
        versionId: 'v_rec',
        lifecycleEventId: 'l_rec',
        auditId: 'a_rec',
        name: 'Push Up',
        effectiveDate: DateTime(2026, 11, 26),
        target: CounterTarget(count: 10, unit: 'reps'),
        schedule: DailySchedule(start: day1),
      );
      await metadataStore.insert(
        'v_rec',
        HabitMetadata(
          category: 'Fitness',
          isPrivate: false,
          includeInRewards: true,
          recoveryEnabled: true,
        ),
      );
      await gamification.createAttribute(
        id: 'attr_fit',
        name: 'Movement',
        description: 'Physical activity consistency',
      );
      await gamification.linkHabitToAttribute(
        habitId: 'h_rec',
        attributeId: 'attr_fit',
      );

      // Day 1: log 4 reps and explicitly resolve as failed -> 0 XP.
      await todayActions.recordTodayProgress(
        habitId: 'h_rec',
        occurrenceId: 'occ_1',
        eventId: 'ev_1',
        quantity: 4,
      );
      await todayActions.resolveToday(
        habitId: 'h_rec',
        occurrenceId: 'occ_1',
        resolutionId: 'res_1',
        state: CounterResolutionState.failed,
        reason: 'Tired',
      );
      final snapFailed = await gamification.reconcileAll();
      expect(snapFailed.levelProgress.totalXp, 0);

      // Day 2: recover remaining 6 reps -> 5 XP + recovery_comeback achievement!
      clock.current = DateTime(2026, 11, 27, 9, 0);
      await todayActions.recoverPriorDeficit(
        occurrenceId: 'occ_1',
        recoveryId: 'rec_1',
        quantity: 6,
      );
      final snapRecovered = await gamification.reconcileAll();
      expect(snapRecovered.levelProgress.totalXp, 5);
      expect(snapRecovered.attributes.single.totalActivityXp, 5);
      final comeback = snapRecovered.achievements.firstWhere(
        (a) => a.definition.key == AchievementCatalog.recoveryComeback,
      );
      expect(comeback.isCurrentlyValid, isTrue);
    });
  });

  group('Schema v15 -> v16 migration', () {
    test('preserves existing v15 Growth data when upgrading to v16', () async {
      final dir = await Directory.systemTemp.createTemp('hibi_v15_to_v16_');
      addTearDown(() => dir.delete(recursive: true));
      final dbFile = File(p.join(dir.path, 'hibi.sqlite'));
      final clock = _MutableClock(DateTime(2026, 11, 27, 9, 0));

      final initialDb = AppDatabase(NativeDatabase(dbFile));
      await JournalService(initialDb, clock).createEntry(
        id: 'j_keep',
        localDate: LocalDate(2026, 11, 27),
        reflectionText: 'Must survive v15 -> v16 upgrade',
      );
      await initialDb.close();

      final raw = sqlite.sqlite3.open(dbFile.path);
      try {
        dropV16Schema(raw);
        raw.execute('PRAGMA user_version = 15');
      } finally {
        raw.close();
      }

      final upgraded = AppDatabase(NativeDatabase(dbFile));
      addTearDown(upgraded.close);

      final vRow = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(vRow.read<int>('user_version'), 17);

      final entries = await JournalService(upgraded, clock).readEntries();
      expect(entries.single.id, 'j_keep');

      final snap = await GamificationService(upgraded, clock).reconcileAll();
      expect(snap.levelProgress.level, 1);
      expect(snap.levelProgress.totalXp, 0);
    });
  });
}
