import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/app/app.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/core/security/app_lock_service.dart';
import 'package:hibi/core/security/security_providers.dart';
import 'package:hibi/features/reminders/application/reminder_providers.dart';
import 'package:hibi/features/reminders/data/reminder_service.dart';
import 'package:hibi/features/habits/presentation/habit_builder_screen.dart';

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 9);
}

Future<void> pumpBuilder(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appClockProvider.overrideWithValue(FixedClock()),
      ],
      child: const MaterialApp(home: HabitBuilderScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<int> rowCount(AppDatabase db, String table) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<void> enterField(WidgetTester tester, String label, String value) async {
  final field = find.widgetWithText(TextFormField, label);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> chooseTemplate(WidgetTester tester, String name) async {
  await tester.tap(find.text('None').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

Future<void> createHabit(WidgetTester tester) async {
  final button = find.text('Create habit');
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('selected suggestions persist as category and unit', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpBuilder(tester, db);
    await enterField(tester, 'Name', 'Read');
    final category = find.widgetWithText(ChoiceChip, 'Learning');
    await tester.ensureVisible(category);
    await tester.tap(category);
    await tester.pumpAndSettle();
    final unit = find.widgetWithText(ChoiceChip, 'pages');
    await tester.ensureVisible(unit);
    await tester.tap(unit);
    await tester.pumpAndSettle();
    await createHabit(tester);
    final row = await db.customSelect('''
      SELECT m.category, t.unit FROM habit_version_metadata m
      JOIN habit_counter_targets t ON t.habit_version_id = m.habit_version_id
    ''').getSingle();
    expect(row.read<String>('category'), 'Learning');
    expect(row.read<String>('unit'), 'pages');
  });

  testWidgets('suggestions and custom category and unit are saved', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpBuilder(tester, db);
    expect(find.text('Group similar habits, or type your own category.'), findsOneWidget);
    final fitness = find.widgetWithText(ChoiceChip, 'Fitness');
    await tester.ensureVisible(fitness);
    await tester.tap(fitness);
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'Category')).controller!.text, 'Fitness');
    final pages = find.widgetWithText(ChoiceChip, 'pages');
    await tester.ensureVisible(pages);
    await tester.tap(pages);
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'Unit')).controller!.text, 'pages');
    await enterField(tester, 'Name', 'Read');
    await enterField(tester, 'Category', 'My books');
    await enterField(tester, 'Unit', 'chapters');
    await createHabit(tester);
    final row = await db.customSelect('''
      SELECT m.category, t.unit FROM habit_version_metadata m
      JOIN habit_counter_targets t ON t.habit_version_id = m.habit_version_id
    ''').getSingle();
    expect(row.read<String>('category'), 'My books');
    expect(row.read<String>('unit'), 'chapters');
    expect(await rowCount(db, 'habits'), 1);
    expect(tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Create habit')).onPressed, isNull);
  });

  testWidgets('creation from More returns to Today only after success', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appClockProvider.overrideWithValue(FixedClock()),
        databaseInitializationProvider.overrideWith((ref) async {}),
        secureKeyValueStoreProvider.overrideWithValue(InMemorySecureKeyValueStore()),
        localNotificationGatewayProvider.overrideWithValue(InMemoryNotificationGateway()),
      ],
      child: const HibiApp(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create habit'));
    await tester.pumpAndSettle();
    await createHabit(tester);
    expect(find.text('Habit Builder'), findsOneWidget);
    expect(await rowCount(db, 'habits'), 0);
    await enterField(tester, 'Name', 'Read today');
    await createHabit(tester);
    expect(find.text('Habit Builder'), findsNothing);
    expect(find.text('Today'), findsWidgets);
    expect(await rowCount(db, 'habits'), 1);
  });

  testWidgets('storage errors keep the builder open and allow retry', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpBuilder(tester, db);
    await rowCount(db, 'habits');
    await db.customStatement("CREATE TRIGGER reject_habit BEFORE INSERT ON habits BEGIN SELECT RAISE(ABORT, 'failed'); END");
    await enterField(tester, 'Name', 'Read');
    await createHabit(tester);
    expect(find.text('Habit Builder'), findsOneWidget);
    expect(find.text('Could not create habit. Please try again.'), findsOneWidget);
    expect(await rowCount(db, 'habits'), 0);
    await db.customStatement('DROP TRIGGER reject_habit');
    await createHabit(tester);
    expect(await rowCount(db, 'habits'), 1);
  });

  testWidgets('skipping templates does not write until explicit creation', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpBuilder(tester, db);

    expect(find.text('Habit Builder'), findsOneWidget);
    expect(find.text('Starter template'), findsOneWidget);
    expect(find.text('None'), findsOneWidget);
    await tester.tap(find.text('None').first);
    await tester.pumpAndSettle();
    expect(find.text('Self Control'), findsOneWidget);
    expect(find.text('Quran Reading'), findsOneWidget);
    expect(find.text('Daily Prayers'), findsOneWidget);
    expect(find.text('Push Up'), findsOneWidget);
    await tester.tap(find.text('None').last);
    await tester.pumpAndSettle();
    expect(await rowCount(db, 'habits'), 0);
    expect(await rowCount(db, 'habit_occurrences'), 0);

    await enterField(tester, 'Name', 'My habit');
    await enterField(tester, 'Category', 'Personal');
    await enterField(tester, 'Target', '3');
    await enterField(tester, 'Unit', 'times');
    expect(await rowCount(db, 'habits'), 0);
    expect(await rowCount(db, 'habit_versions'), 0);

    await createHabit(tester);
    expect(find.text('Habit created'), findsOneWidget);
    expect(await rowCount(db, 'habits'), 1);
    expect(await rowCount(db, 'habit_occurrences'), 0);
  });

  testWidgets(
    'customized counter template persists edits without occurrences',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpBuilder(tester, db);
      await chooseTemplate(tester, 'Push Up');

      expect(find.text('Push Up'), findsWidgets);
      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, 'Name'))
            .controller!
            .text,
        'Push Up',
      );
      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, 'Target'))
            .controller!
            .text,
        '10',
      );
      expect(await rowCount(db, 'habits'), 0);
      await enterField(tester, 'Name', 'Morning push ups');
      await enterField(tester, 'Category', 'Fitness');
      await enterField(tester, 'Target', '15');
      await enterField(tester, 'Unit', 'reps');
      expect(await rowCount(db, 'habits'), 0);
      await createHabit(tester);

      expect(find.text('Habit created'), findsOneWidget);
      final row = await db.customSelect('''
      SELECT v.name, v.effective_start, t.target_count, t.unit,
             m.category, m.symbol
      FROM habit_versions v
      JOIN habit_counter_targets t ON t.habit_version_id = v.id
      JOIN habit_version_metadata m ON m.habit_version_id = v.id
    ''').getSingle();
      expect(row.read<String>('name'), 'Morning push ups');
      expect(row.read<String>('effective_start'), '2026-11-26');
      expect(row.read<int>('target_count'), 15);
      expect(row.read<String>('unit'), 'reps');
      expect(row.read<String>('category'), 'Fitness');
      expect(row.read<String>('symbol'), 'P');
      expect(await rowCount(db, 'habits'), 1);
      expect(await rowCount(db, 'habit_occurrences'), 0);
    },
  );

  testWidgets('Self Control creates a private habit without recovery', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpBuilder(tester, db);
    await chooseTemplate(tester, 'Self Control');
    expect(await rowCount(db, 'habits'), 0);
    await createHabit(tester);

    expect(find.text('Habit created'), findsOneWidget);
    final row = await db.customSelect('''
      SELECT v.name, v.effective_start, m.symbol, m.is_private,
             m.recovery_enabled, t.max_incidents
      FROM habit_versions v
      JOIN habit_version_metadata m ON m.habit_version_id = v.id
      JOIN habit_avoidance_targets t ON t.habit_version_id = v.id
    ''').getSingle();
    expect(row.read<String>('name'), 'Self Control');
    expect(row.read<String>('effective_start'), '2026-11-26');
    expect(row.read<String>('symbol'), 'O');
    expect(row.read<int>('is_private'), 1);
    expect(row.read<int>('recovery_enabled'), 0);
    expect(row.read<int>('max_incidents'), 0);
    expect(await rowCount(db, 'habit_avoidance_occurrences'), 0);
    expect(await rowCount(db, 'habit_occurrences'), 0);
  });

  testWidgets('invalid required and counter fields do not create records', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpBuilder(tester, db);
    await chooseTemplate(tester, 'Quran Reading');
    await enterField(tester, 'Name', ' ');
    await enterField(tester, 'Category', ' ');
    await createHabit(tester);
    expect(find.text('Required'), findsWidgets);
    expect(await rowCount(db, 'habits'), 0);
    expect(await rowCount(db, 'habit_versions'), 0);

    await enterField(tester, 'Name', 'Reading');
    await enterField(tester, 'Category', 'Spiritual');
    await enterField(tester, 'Target', '0');
    await enterField(tester, 'Unit', ' ');
    await createHabit(tester);
    expect(find.text('Enter a valid value'), findsWidgets);
    expect(await rowCount(db, 'habits'), 0);
    expect(await rowCount(db, 'habit_counter_targets'), 0);
    expect(await rowCount(db, 'habit_occurrences'), 0);
  });
  testWidgets('checklist template saves independent editable items', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpBuilder(tester, db);
    await chooseTemplate(tester, 'Daily Prayers');
    await enterField(tester, 'Checklist items (one per line)', 'First\nSecond');
    await createHabit(tester);
    expect(find.text('Habit created'), findsOneWidget);
    final rows = await db
        .customSelect(
          'SELECT label, recovery_enabled FROM habit_checklist_items ORDER BY display_order',
        )
        .get();
    expect(rows.map((row) => row.read<String>('label')), ['First', 'Second']);
    expect(rows.map((row) => row.read<int>('recovery_enabled')), [1, 1]);
    expect(await rowCount(db, 'habit_checklist_occurrences'), 0);
  });

  testWidgets('measurement saves exact decimal target and interval schedule', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpBuilder(tester, db);
    await enterField(tester, 'Name', 'Measurement');
    final type = find.text('Counter').first;
    await tester.ensureVisible(type);
    await tester.tap(type);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Measurement').last);
    await tester.pumpAndSettle();
    await enterField(tester, 'Decimal places', '2');
    await enterField(tester, 'Target', '12.34');
    await enterField(tester, 'Unit', 'kg');
    final schedule = find.text('Daily').first;
    await tester.ensureVisible(schedule);
    await tester.tap(schedule);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Interval').last);
    await tester.pumpAndSettle();
    await enterField(tester, 'Every days', '3');
    await createHabit(tester);
    expect(find.text('Habit created'), findsOneWidget);
    final target = await db
        .customSelect(
          'SELECT scaled_target, decimal_places, unit FROM habit_typed_targets',
        )
        .getSingle();
    expect(target.read<int>('scaled_target'), 1234);
    expect(target.read<int>('decimal_places'), 2);
    expect(target.read<String>('unit'), 'kg');
    final recurrence = await db
        .customSelect('SELECT recurrence, weekday_mask FROM habit_schedules')
        .getSingle();
    expect(recurrence.read<String>('recurrence'), 'interval');
    expect(recurrence.read<int>('weekday_mask'), 3);
    expect(await rowCount(db, 'habit_typed_occurrences'), 0);
  });
  testWidgets('builder keeps fields spaced and actions inside safe area', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 80);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpBuilder(tester, db);

    final name = find.widgetWithText(TextFormField, 'Name');
    final category = find.widgetWithText(TextFormField, 'Category');
    expect(
      tester.getTopLeft(category).dy - tester.getBottomLeft(name).dy,
      greaterThanOrEqualTo(24),
    );

    final button = find.text('Create habit');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    expect(tester.getBottomRight(button).dy, lessThanOrEqualTo(844 - 80));
  });

  testWidgets('privacy changes only when its switch is pressed', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpBuilder(tester, db);
    final label = find.text('Private');
    await tester.ensureVisible(label);
    await tester.pumpAndSettle();
    final privacySwitch = find.byKey(const ValueKey('builder-switch-Private'));
    expect(tester.widget<Switch>(privacySwitch).value, isFalse);
    await tester.tap(label);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(privacySwitch).value, isFalse);
    await tester.tap(privacySwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(privacySwitch).value, isTrue);
  });
}
