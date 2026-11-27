import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/app/app.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/security/app_lock_service.dart';
import 'package:hibi/core/security/security_providers.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/reminders/application/reminder_providers.dart';
import 'package:hibi/features/reminders/data/reminder_service.dart';
import 'package:integration_test/integration_test.dart';

class _IntegrationClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 27, 10, 0);
}

class _StubBiometrics implements BiometricGateway {
  @override
  Future<bool> isBiometricAvailable() async => false;

  @override
  Future<bool> authenticate({required String localizedReason}) async => false;
}

class _StubWindow implements PrivacyWindowGateway {
  @override
  Future<void> setSecureFlag(bool enabled) async {}
}

/// End-to-end integration test exercising all five primary destinations
/// using an isolated in-memory database so no real user data is touched.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('launches Hibi and navigates all five destinations cleanly', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appClockProvider.overrideWithValue(_IntegrationClock()),
          databaseInitializationProvider.overrideWith((ref) async {}),
          secureKeyValueStoreProvider.overrideWithValue(
            InMemorySecureKeyValueStore(),
          ),
          biometricGatewayProvider.overrideWithValue(_StubBiometrics()),
          privacyWindowGatewayProvider.overrideWithValue(_StubWindow()),
          localNotificationGatewayProvider.overrideWithValue(
            InMemoryNotificationGateway(),
          ),
        ],
        child: const HibiApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2026年11月27日(金)'), findsOneWidget);
    expect(find.text('Welcome to Hibi'), findsOneWidget);

    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('History & Analytics'), findsOneWidget);

    await tester.tap(find.text('Finance'));
    await tester.pumpAndSettle();
    expect(find.text('Finance (IDR)'), findsOneWidget);

    await tester.tap(find.text('Growth'));
    await tester.pumpAndSettle();
    expect(find.text('Journal, Goals & Focus'), findsOneWidget);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Privacy & App Lock'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
