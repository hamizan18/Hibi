import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/app/app.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/security/app_lock_service.dart';
import 'package:hibi/core/security/security_providers.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/reminders/application/reminder_providers.dart';
import 'package:hibi/features/reminders/data/reminder_service.dart';

class FakeClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

void main() {
  test('Japanese date uses local calendar date and weekday', () {
    expect(japaneseDate(DateTime(2026, 11, 26)), '2026年11月26日(木)');
    expect(japaneseDate(DateTime(2024, 2, 29)), '2024年2月29日(木)');
  });

  testWidgets('navigates between clearly unavailable sections', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appClockProvider.overrideWithValue(FakeClock()),
          databaseInitializationProvider.overrideWith((ref) async {}),
          secureKeyValueStoreProvider.overrideWithValue(
            InMemorySecureKeyValueStore(),
          ),
          localNotificationGatewayProvider.overrideWithValue(
            InMemoryNotificationGateway(),
          ),
        ],
        child: const HibiApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2026年11月26日(木)'), findsOneWidget);
    expect(find.text('Welcome to Hibi'), findsOneWidget);
    await tester.tap(find.text('Growth'));
    // Tab content switches on the next frame, without a route animation.
    await tester.pump();
    expect(find.text('Welcome to Hibi'), findsNothing);
    expect(find.text('Journal, Goals & Focus'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Journal, Goals & Focus'), findsOneWidget);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Privacy & App Lock'), findsOneWidget);
    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Hibi'), findsOneWidget);
  });

  testWidgets('opens habit builder from Today and More', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appClockProvider.overrideWithValue(FakeClock()),
          databaseInitializationProvider.overrideWith((ref) async {}),
          secureKeyValueStoreProvider.overrideWithValue(
            InMemorySecureKeyValueStore(),
          ),
          localNotificationGatewayProvider.overrideWithValue(
            InMemoryNotificationGateway(),
          ),
        ],
        child: const HibiApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create habit'));
    await tester.pumpAndSettle();
    expect(find.text('Habit Builder'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create habit'));
    await tester.pumpAndSettle();
    expect(find.text('Habit Builder'), findsOneWidget);
  });

  testWidgets('shows local storage initialization errors', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseInitializationProvider.overrideWith(
            (ref) async => throw StateError('Storage unavailable'),
          ),
        ],
        child: const HibiApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Unable to open local storage'), findsOneWidget);
    expect(find.text('Welcome to Hibi'), findsNothing);
  });
}
