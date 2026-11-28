import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/presentation/habit_builder_screen.dart';

class _Clock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 9);
}

void main() {
  for (final type in ['Time of Day', 'Range']) {
    testWidgets('$type requires an explicit positive score tolerance', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(_Clock()),
          ],
          child: const MaterialApp(home: HabitBuilderScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Test habit',
      );
      await tester.ensureVisible(find.text('Counter').first);
      await tester.tap(find.text('Counter').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(type).last);
      await tester.pumpAndSettle();
      final submit = find.text('Create habit');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(
        (await db.customSelect('SELECT COUNT(*) AS n FROM habits').getSingle())
            .read<int>('n'),
        0,
      );
      final label = type == 'Range'
          ? 'Score tolerance (target units)'
          : 'Score tolerance (minutes)';
      final field = find.widgetWithText(TextFormField, label);
      await tester.ensureVisible(field);
      await tester.enterText(field, '0');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(
        (await db.customSelect('SELECT COUNT(*) AS n FROM habits').getSingle())
            .read<int>('n'),
        0,
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, '2');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      final scoring = await db
          .customSelect(
            'SELECT tracking_type, tolerance FROM habit_version_scoring',
          )
          .getSingle();
      expect(scoring.read<int>('tolerance'), 2);
      expect(
        scoring.read<String>('tracking_type'),
        type == 'Range' ? 'range' : 'time_of_day',
      );
    });
  }
}
