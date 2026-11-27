import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/application/counter_habit_providers.dart';
import 'package:hibi/features/habits/data/unified_habit_registry.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/domain/starter_template_catalog.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import 'test_schema_downgrade.dart';

class MutableClock implements AppClock {
  MutableClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  test('StarterTemplateCatalog and UnifiedHabitRegistryReader inspect all four approved templates across counter, checklist and avoidance types', () async {
    expect(StarterTemplateCatalog.approvedSymbols, ['O', 'N', 'S', 'P']);

    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = MutableClock(DateTime(2026, 11, 26, 8));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appClockProvider.overrideWithValue(clock),
      ],
    );
    addTearDown(container.dispose);

    // 1. Self Control (O) - Avoidance
    await container
        .read(avoidanceHabitServiceProvider)
        .createFromStarterTemplate(
          template: StarterTemplateCatalog.selfControl,
          habitId: 'h1_self',
          versionId: 'v1_self',
          lifecycleEventId: 'l1_self',
          effectiveDate: DateTime(2026, 11, 26),
        );

    // 2. Quran Reading (N) - Counter
    clock.current = DateTime(2026, 11, 26, 9);
    await container
        .read(counterHabitWriterProvider)
        .createFromStarterTemplate(
          template: StarterTemplateCatalog.quranReading,
          habitId: 'h2_quran',
          versionId: 'v2_quran',
          auditId: 'a2_quran',
          lifecycleEventId: 'l2_quran',
          effectiveDate: DateTime(2026, 11, 26),
        );

    // 3. Daily Prayers (S) - Checklist
    clock.current = DateTime(2026, 11, 26, 10);
    await container
        .read(checklistHabitServiceProvider)
        .createFromStarterTemplate(
          template: StarterTemplateCatalog.dailyPrayers,
          habitId: 'h3_prayers',
          versionId: 'v3_prayers',
          lifecycleEventId: 'l3_prayers',
          itemIds: const ['f', 'd', 'a', 'm', 'i'],
          effectiveDate: DateTime(2026, 11, 26),
        );

    // 4. Push Up (P) - Counter
    clock.current = DateTime(2026, 11, 26, 11);
    await container
        .read(counterHabitWriterProvider)
        .createFromStarterTemplate(
          template: StarterTemplateCatalog.pushUp,
          habitId: 'h4_pushup',
          versionId: 'v4_pushup',
          auditId: 'a4_pushup',
          lifecycleEventId: 'l4_pushup',
          effectiveDate: DateTime(2026, 11, 26),
        );

    final summaries = await container
        .read(unifiedHabitRegistryReaderProvider)
        .readAll(asOfDate: LocalDate(2026, 11, 26));
    expect(summaries.length, 4);
    expect(summaries[0].name, 'Self Control');
    expect(summaries[0].trackingType, HabitTrackingType.avoidance);
    expect(summaries[0].metadata!.isPrivate, isTrue);
    expect(summaries[0].metadata!.recoveryEnabled, isFalse);

    expect(summaries[1].name, 'Quran Reading');
    expect(summaries[1].trackingType, HabitTrackingType.counter);

    expect(summaries[2].name, 'Daily Prayers');
    expect(summaries[2].trackingType, HabitTrackingType.checklist);

    expect(summaries[3].name, 'Push Up');
    expect(summaries[3].trackingType, HabitTrackingType.counter);
  });

  test('version 10 migration preserves existing schedules and occurrences and upgrades to version 12', () async {
    final dir = await Directory.systemTemp.createTemp('hibi_v10_to_v11_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(path.join(dir.path, 'db.sqlite'));
    final original = AppDatabase(NativeDatabase(file));
    final clock = MutableClock(DateTime(2026, 11, 26, 9));
    await ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(original),
            appClockProvider.overrideWithValue(clock),
          ],
        )
        .read(counterHabitWriterProvider)
        .createFromStarterTemplate(
          template: StarterTemplateCatalog.quranReading,
          habitId: 'h',
          versionId: 'v',
          auditId: 'a',
          lifecycleEventId: 'l',
          effectiveDate: DateTime(2026, 11, 26),
        );
    await original.close();

    final legacy = sqlite3.open(file.path);
    dropV11Tables(legacy);
    legacy.execute('PRAGMA user_version = 10');
    legacy.close();

    final migrated = AppDatabase(NativeDatabase(file));
    addTearDown(migrated.close);
    expect(
      (await migrated.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      12,
    );
    final summaries = await UnifiedHabitRegistryReader(migrated)
        .readAll(asOfDate: LocalDate(2026, 11, 26));
    expect(summaries.single.name, 'Quran Reading');
    expect(summaries.single.trackingType, HabitTrackingType.counter);
    expect(summaries.single.schedule, isA<DailySchedule>());
  });
}
