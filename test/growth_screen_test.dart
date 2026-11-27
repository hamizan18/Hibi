import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/app/theme/hibi_theme.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/growth/presentation/growth_screen.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class _TestClock implements AppClock {
  _TestClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  testWidgets(
    'GrowthView creates journal entries, goals/milestones and runs focus controls',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _TestClock(DateTime(2026, 11, 27, 10, 0, 0));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(
            theme: createHibiTheme(),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: GrowthView(asOfDate: LocalDate(2026, 11, 27)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Journal section
      expect(find.text('Journal & Mood'), findsOneWidget);
      await tester.tap(find.text('Add journal entry'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Title (optional)'),
        'Afternoon note',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Reflection (optional)'),
        'Steady focus today.',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Tags (comma separated)'),
        'deepwork, calm',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Afternoon note'), findsOneWidget);
      expect(find.text('Steady focus today.'), findsOneWidget);
      expect(find.text('#deepwork'), findsWidgets);

      // 2. Goals section
      await tester.tap(find.widgetWithText(ChoiceChip, 'Goals'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add goal'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Goal title'),
        'Read 5 books',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Target units (optional)'),
        '5',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Unit label (optional, e.g. chapters)'),
        'books',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.text('Read 5 books'), findsOneWidget);

      await tester.tap(find.text('Add milestone'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Milestone title'),
        'Finish book 1',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('Finish book 1'), findsOneWidget);

      // 3. Focus section
      await tester.tap(find.widgetWithText(ChoiceChip, 'Focus'));
      await tester.pumpAndSettle();

      expect(find.text('Focus / Pomodoro (25 / 5 / 15)'), findsOneWidget);
      await tester.tap(find.text('Start Focus'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byKey(const Key('focus-remaining-clock')), findsOneWidget);
      expect(find.text('25:00'), findsOneWidget);

      // Pause stops the periodic timer cleanly so pumpAndSettle succeeds.
      await tester.tap(find.text('Pause'));
      await tester.pumpAndSettle();
      expect(find.text('Resume'), findsOneWidget);

      await tester.tap(find.text('Complete'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Completed focus: 1'), findsOneWidget);
    },
  );

  testWidgets('GrowthView renders cleanly at 320px width and 2.0x text scale', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = _TestClock(DateTime(2026, 11, 27, 10, 0, 0));

    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appClockProvider.overrideWithValue(clock),
        ],
        child: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 800),
            textScaler: TextScaler.linear(2.0),
          ),
          child: MaterialApp(
            theme: createHibiTheme(),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: GrowthView(asOfDate: LocalDate(2026, 11, 27)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
