import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/app/theme/hibi_theme.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/security/app_lock_gate.dart';
import 'package:hibi/core/security/app_lock_service.dart';
import 'package:hibi/core/security/privacy_deletion_service.dart';
import 'package:hibi/core/security/security_providers.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/gamification/data/gamification_service.dart';
import 'package:hibi/features/growth/data/journal_service.dart';
import 'package:hibi/features/habits/data/counter_habit_writer.dart';
import 'package:hibi/features/habits/data/counter_today_action_service.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/counter_target.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class _Clock implements AppClock {
  _Clock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

class _FakeBiometrics implements BiometricGateway {
  _FakeBiometrics({this.available = true, this.shouldSucceed = true});
  bool available;
  bool shouldSucceed;

  @override
  Future<bool> isBiometricAvailable() async => available;

  @override
  Future<bool> authenticate({required String localizedReason}) async =>
      shouldSucceed;
}

class _FakeWindowGateway implements PrivacyWindowGateway {
  bool? lastSecureFlag;

  @override
  Future<void> setSecureFlag(bool enabled) async {
    lastSecureFlag = enabled;
  }
}

void main() {
  group('AppLockService & Salted PBKDF2-SHA256 PIN', () {
    test('stores only salted PBKDF2 verifier (never plaintext), rate-limits, supports biometrics & wipe-based forgotten-PIN recovery', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _Clock(DateTime(2026, 11, 27, 10, 0));
      final secure = InMemorySecureKeyValueStore();
      final bio = _FakeBiometrics(available: true, shouldSucceed: true);
      final win = _FakeWindowGateway();
      final service = AppLockService(
        secureStore: secure,
        biometricGateway: bio,
        privacyWindowGateway: win,
        clock: clock,
      );

      // Configure PIN
      await service.configurePin('2580');
      expect(win.lastSecureFlag, isTrue);

      final rawStored = await secure.read('hibi_pin_verifier_v1');
      expect(rawStored, isNotNull);
      expect(
        rawStored!.contains('2580'),
        isFalse,
      ); // Never stores plaintext PIN!
      expect(rawStored.contains('pbkdf2_hmac_sha256'), isTrue);

      // Enable biometrics
      await service.setBiometricEnabled(true);
      expect(await service.unlockWithBiometrics(), isTrue);

      // 5 wrong attempts trigger rate-limit backoff
      for (var i = 0; i < 5; i++) {
        final res = await service.verifyPin('0000');
        expect(res.unlocked, isFalse);
      }
      final rateLimited = await service.verifyPin('2580');
      expect(rateLimited.unlocked, isFalse);
      expect(rateLimited.retryAfterSeconds, greaterThan(0));

      // Advance past 30s cooldown -> correct PIN unlocks!
      clock.current = DateTime(2026, 11, 27, 10, 1);
      final ok = await service.verifyPin('2580');
      expect(ok.unlocked, isTrue);

      // Forgotten PIN recovery requires exact phrase and wipes local data + PIN.
      await JournalService(db, clock).createEntry(
        id: 'j_wipe',
        localDate: LocalDate(2026, 11, 27),
        reflectionText: 'Sensitive private thought',
        isPrivate: true,
      );
      await expectLater(
        () => service.resetForgottenPinWithLocalWipe(
          db: db,
          confirmationPhrase: 'wrong phrase',
        ),
        throwsArgumentError,
      );
      await service.resetForgottenPinWithLocalWipe(
        db: db,
        confirmationPhrase: AppLockService.forgottenPinResetPhrase,
      );
      expect((await service.readConfig()).isPinEnabled, isFalse);
      expect(
        await JournalService(db, clock).readEntries(includePrivate: true),
        isEmpty,
      );
    });

    testWidgets('AppLockGate blocks UI on launch until PIN is verified', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _Clock(DateTime(2026, 11, 27, 10, 0));
      final secure = InMemorySecureKeyValueStore();
      final bio = _FakeBiometrics(available: false);
      final win = _FakeWindowGateway();
      final lockService = AppLockService(
        secureStore: secure,
        biometricGateway: bio,
        privacyWindowGateway: win,
        clock: clock,
      );
      await tester.runAsync(() => lockService.configurePin('1234'));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(clock),
            secureKeyValueStoreProvider.overrideWithValue(secure),
            biometricGatewayProvider.overrideWithValue(bio),
            privacyWindowGatewayProvider.overrideWithValue(win),
          ],
          child: MaterialApp(
            theme: createHibiTheme(),
            home: const AppLockGate(
              child: Scaffold(body: Text('Protected Dashboard')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Hibi is locked'), findsOneWidget);
      expect(find.text('Protected Dashboard'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('app-lock-pin-field')),
        '9999',
      );
      await tester.tap(find.byKey(const Key('app-lock-unlock-button')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Incorrect PIN'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('app-lock-pin-field')),
        '1234',
      );
      await tester.tap(find.byKey(const Key('app-lock-unlock-button')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Protected Dashboard'), findsOneWidget);
    });
  });

  group('PrivacyDeletionService', () {
    test('permanently deletes a habit including immutable audit, XP and preserves triggers afterward', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _Clock(DateTime(2026, 11, 27, 9, 0));
      final today = LocalDate(2026, 11, 27);

      await CounterHabitWriter(db, clock).create(
        habitId: 'h_secret',
        versionId: 'v_secret',
        lifecycleEventId: 'l_secret',
        auditId: 'a_secret',
        name: 'Sensitive Habit',
        effectiveDate: DateTime(2026, 11, 27),
        target: CounterTarget(count: 1, unit: 'time'),
        schedule: DailySchedule(start: today),
      );
      await HabitMetadataStore(db).insert(
        'v_secret',
        HabitMetadata(
          category: 'General',
          isPrivate: false,
          includeInRewards: true,
        ),
      );
      await CounterTodayActionService(db, clock).recordTodayProgress(
        habitId: 'h_secret',
        occurrenceId: 'occ_secret',
        eventId: 'ev_secret',
        quantity: 1,
      );
      await GamificationService(db, clock).reconcileAll();

      await PrivacyDeletionService(db, clock).permanentlyDeleteHabit(
        habitId: 'h_secret',
        confirmationPhrase: PrivacyDeletionService.confirmDeleteHabitPhrase,
      );

      final remainingHabits = await db
          .customSelect("SELECT id FROM habits WHERE id = 'h_secret'")
          .get();
      final remainingAudits = await db
          .customSelect(
            "SELECT id FROM habit_version_audit WHERE habit_id = 'h_secret'",
          )
          .get();
      final remainingXp = await db
          .customSelect(
            "SELECT id FROM gamification_xp_ledger WHERE habit_id = 'h_secret'",
          )
          .get();
      expect(remainingHabits, isEmpty);
      expect(remainingAudits, isEmpty);
      expect(remainingXp, isEmpty);

      // Verify immutable triggers were cleanly restored!
      final triggerCount =
          (await db
                  .customSelect(
                    "SELECT COUNT(*) AS c FROM sqlite_master WHERE type = 'trigger'",
                  )
                  .getSingle())
              .read<int>('c');
      expect(triggerCount, greaterThan(20));
    });
  });
}
