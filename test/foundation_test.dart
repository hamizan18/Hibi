import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/app/app.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';

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
        ],
        child: const HibiApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2026年11月26日(木)'), findsOneWidget);
    expect(find.text('Welcome to Hibi'), findsOneWidget);
    await tester.tap(find.text('Growth'));
    await tester.pumpAndSettle();
    expect(find.text('Growth is not available yet'), findsOneWidget);
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
