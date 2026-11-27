import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/gamification/data/gamification_service.dart';
import 'package:hibi/features/gamification/domain/gamification_models.dart';
import 'package:hibi/features/habits/data/counter_correction_preview.dart';
import 'package:hibi/features/habits/data/counter_correction_writer.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as p;

class _AcceptanceClock implements AppClock {
  _AcceptanceClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

/// T-009 acceptance test:
/// One reward per eligible occurrence, repeated saves, correction reconciliation,
/// level boundaries (100 * L), achievement validity with preserved unlock history,
/// and private exclusions — surviving disk database close and reopen.
void main() {
  test('T-009: idempotent XP, level boundary, private exclusion and correction reconciliation persist across disk reopen', () async {
    final dir = await Directory.systemTemp.createTemp('hibi_m5_t009_');
    addTearDown(() => dir.delete(recursive: true));
    final dbFile = File(p.join(dir.path, 'hibi.sqlite'));
    final clock = _AcceptanceClock(DateTime(2026, 11, 1, 9, 0));

    // Phase 1: Create 1 public eligible habit + 1 private habit, log 10 eligible days
    // to reach exactly 100 XP (Level 2 boundary) and unlock xp_century + steady_five + first_step.
    final db1 = AppDatabase(NativeDatabase(dbFile));
    final writer1 = CounterHabitWriter(db1, clock);
    final metadata1 = HabitMetadataStore(db1);
    final actions1 = CounterTodayActionService(db1, clock);
    final gam1 = GamificationService(db1, clock);

    final start = LocalDate(2026, 11, 1);
    final startDt = DateTime(2026, 11, 1);
    await writer1.create(
      habitId: 'h_pub',
      versionId: 'v_pub',
      lifecycleEventId: 'l_pub',
      auditId: 'a_pub',
      name: 'Quran Reading',
      effectiveDate: startDt,
      target: CounterTarget(count: 5, unit: 'pages'),
      schedule: DailySchedule(start: start),
    );
    await metadata1.insert(
      'v_pub',
      HabitMetadata(
        category: 'Daily',
        isPrivate: false,
        includeInRewards: true,
        recoveryEnabled: true,
      ),
    );
    await writer1.create(
      habitId: 'h_priv',
      versionId: 'v_priv',
      lifecycleEventId: 'l_priv',
      auditId: 'a_priv',
      name: 'Private Habit',
      effectiveDate: startDt,
      target: CounterTarget(count: 1, unit: 'unit'),
      schedule: DailySchedule(start: start),
    );
    await metadata1.insert(
      'v_priv',
      HabitMetadata(
        category: 'Private',
        isPrivate: true,
        includeInRewards: true,
      ),
    );

    for (var day = 1; day <= 10; day++) {
      clock.current = DateTime(2026, 11, day, 10, 0);
      await actions1.recordTodayProgress(
        habitId: 'h_pub',
        occurrenceId: 'occ_pub_$day',
        eventId: 'ev_pub_$day',
        quantity: 5,
      );
      // Repeated save on same day (extra 2 pages above target) must NOT add duplicate XP!
      await actions1.recordTodayProgress(
        habitId: 'h_pub',
        occurrenceId: 'occ_pub_$day',
        eventId: 'ev_pub_extra_$day',
        quantity: 2,
      );
      await actions1.recordTodayProgress(
        habitId: 'h_priv',
        occurrenceId: 'occ_priv_$day',
        eventId: 'ev_priv_$day',
        quantity: 1,
      );
      await gam1.reconcileAll();
    }

    final snap1 = await gam1.reconcileAll();
    expect(snap1.levelProgress.totalXp, 100);
    expect(snap1.levelProgress.level, 2);
    expect(snap1.levelProgress.xpIntoCurrentLevel, 0);
    expect(snap1.levelProgress.xpRequiredForNextLevel, 200);
    expect(snap1.ledgerEntries.length, 10);
    expect(
      snap1.achievements
          .firstWhere((a) => a.definition.key == AchievementCatalog.xpCentury)
          .isCurrentlyValid,
      isTrue,
    );
    await db1.close();

    // Phase 2: Reopen DB, run historical target correction raising target 5 -> 10 pages
    // (each day has 7 recorded pages -> drops from completed to partial -> reconciles to 0 XP),
    // close DB again, and verify reconciled state & preserved unlock history survive restart.
    clock.current = DateTime(2026, 11, 10, 12, 0);
    final db2 = AppDatabase(NativeDatabase(dbFile));
    final preview = await CounterCorrectionPreviewer(db2, clock).preview(
      CounterTargetCorrectionProposal(
        habitId: 'h_pub',
        versionId: 'v_pub',
        proposedTargetCount: 10,
        proposedUnit: 'pages',
        reason: 'Target adjusted to 10 pages',
      ),
    );
    await CounterCorrectionWriter(
      db2,
      clock,
    ).commit(correctionAuditId: 'corr_t009', confirmedPreview: preview);
    await db2.close();

    final db3 = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db3.close);
    final snapAfterRestart = await GamificationService(
      db3,
      clock,
    ).readSnapshot();

    expect(snapAfterRestart.levelProgress.totalXp, 0);
    expect(snapAfterRestart.levelProgress.level, 1);
    final century = snapAfterRestart.achievements.firstWhere(
      (a) => a.definition.key == AchievementCatalog.xpCentury,
    );
    expect(century.isUnlockedEver, isTrue);
    expect(century.isCurrentlyValid, isFalse);
    expect(century.unlockedAtUtc, isNotNull);
    expect(century.invalidatedAtUtc, isNotNull);
    expect(century.history.map((h) => h.eventType).toList(), [
      AchievementHistoryEventType.unlocked,
      AchievementHistoryEventType.invalidated,
    ]);
  });
}
