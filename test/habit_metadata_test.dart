import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/features/habits/data/habit_metadata_store.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';

void main() {
  test('validates priority weights, nonblank category and optional fields', () {
    expect(HabitPriority.critical.weight, 4);
    expect(HabitPriority.high.weight, 3);
    expect(HabitPriority.normal.weight, 2);
    expect(HabitPriority.low.weight, 1);

    expect(() => HabitMetadata(category: '   '), throwsArgumentError);
    expect(
      () => HabitMetadata(category: 'Health', symbol: '   '),
      throwsArgumentError,
    );
    expect(
      () => HabitMetadata(category: 'Health', description: '  '),
      throwsArgumentError,
    );

    final meta = HabitMetadata(
      description: '  Daily reflection  ',
      symbol: ' N ',
      category: ' Spiritual ',
      priority: HabitPriority.high,
      isPrivate: true,
      recoveryEnabled: true,
      includeInScore: false,
      includeInStreak: true,
      includeInRewards: false,
      displayOrder: 3,
    );
    expect(meta.description, 'Daily reflection');
    expect(meta.symbol, 'N');
    expect(meta.category, 'Spiritual');
    expect(meta.priority, HabitPriority.high);
    expect(meta.isPrivate, isTrue);
    expect(meta.recoveryEnabled, isTrue);
    expect(meta.includeInScore, isFalse);
    expect(meta.includeInStreak, isTrue);
    expect(meta.includeInRewards, isFalse);
    expect(meta.displayOrder, 3);
  });

  test('HabitMetadataStore persists per-version metadata and blocks mutation once occurrences exist', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement("INSERT INTO habits VALUES ('h', 1)");
    await db.customStatement(
      "INSERT INTO habit_versions VALUES ('v1', 'h', 'Quran Reading', '2026-11-26', NULL, 1, 1)",
    );
    await db.customStatement(
      "INSERT INTO habit_counter_targets VALUES ('v1', 5, 'pages')",
    );

    final store = HabitMetadataStore(db);
    expect(await store.findForVersion('v1'), isNull);

    await store.insert(
      'v1',
      HabitMetadata(
        description: 'Read 5 pages',
        symbol: 'N',
        category: 'Spiritual',
        priority: HabitPriority.critical,
        isPrivate: true,
        recoveryEnabled: true,
        includeInScore: true,
        includeInStreak: true,
        includeInRewards: false,
        displayOrder: 1,
      ),
    );

    final loaded = await store.findForVersion('v1');
    expect(loaded!.description, 'Read 5 pages');
    expect(loaded.symbol, 'N');
    expect(loaded.category, 'Spiritual');
    expect(loaded.priority, HabitPriority.critical);
    expect(loaded.isPrivate, isTrue);
    expect(loaded.recoveryEnabled, isTrue);
    expect(loaded.includeInRewards, isFalse);
    expect(loaded.displayOrder, 1);

    await db.customStatement(
      "INSERT INTO habit_occurrences VALUES ('o1', 'h', 'v1', '2026-11-26', 5, 'pages')",
    );
    await expectLater(
      db.customStatement(
        "UPDATE habit_version_metadata SET category = 'Other' WHERE habit_version_id = 'v1'",
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      db.customStatement(
        "DELETE FROM habit_version_metadata WHERE habit_version_id = 'v1'",
      ),
      throwsA(isA<Exception>()),
    );
  });
}
