import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/habits/data/avoidance_habit_store.dart';
import 'package:hibi/features/habits/data/boolean_duration_habit_store.dart';
import 'package:hibi/features/habits/data/checklist_habit_store.dart';
import 'package:hibi/features/habits/data/measurement_time_range_habit_store.dart';
import 'package:hibi/features/habits/domain/avoidance_habit.dart';
import 'package:hibi/features/habits/domain/boolean_duration_habit.dart';
import 'package:hibi/features/habits/domain/checklist_habit.dart';
import 'package:hibi/features/habits/domain/habit_metadata.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/domain/measurement_time_range_habit.dart';
import 'package:path/path.dart' as path;

class FixedClock implements AppClock {
  @override
  DateTime now() => DateTime.utc(2026, 11, 26, 12, 34, 56, 123, 456);
}

const types = [
  'checklist',
  'avoidance',
  'boolean',
  'duration',
  'measurement',
  'time_of_day',
  'range',
];

Future<void> create(
  AppDatabase db,
  String type, {
  bool withMetadata = true,
}) async {
  final clock = FixedClock();
  final date = DateTime(2026, 11, 26);
  final schedule = WeekdaySchedule(
    start: LocalDate(2026, 11, 26),
    weekdays: {1, 4, 7},
  );
  final metadata = withMetadata
      ? HabitMetadata(
          category: 'Health',
          description: 'Description',
          symbol: 'H',
          priority: HabitPriority.high,
          isPrivate: true,
          includeInRewards: false,
          displayOrder: 3,
        )
      : null;
  final habitId = 'h_$type';
  final versionId = 'v_$type';
  final lifecycleEventId = 'l_$type';
  switch (type) {
    case 'checklist':
      await ChecklistHabitService(db, clock).create(
        habitId: habitId,
        versionId: versionId,
        lifecycleEventId: lifecycleEventId,
        name: 'Checklist',
        effectiveDate: date,
        schedule: schedule,
        metadata: metadata,
        items: [
          ChecklistItemDefinition(
            id: 'item_second',
            label: 'Second',
            displayOrder: 1,
            recoveryEnabled: false,
          ),
          ChecklistItemDefinition(
            id: 'item_first',
            label: 'First',
            displayOrder: 0,
          ),
        ],
      );
    case 'avoidance':
      await AvoidanceHabitService(db, clock).create(
        habitId: habitId,
        versionId: versionId,
        lifecycleEventId: lifecycleEventId,
        name: 'Avoidance',
        effectiveDate: date,
        schedule: schedule,
        metadata: metadata,
        target: AvoidanceTarget(maxIncidents: 2),
      );
    case 'boolean':
      await BooleanDurationHabitService(db, clock).createBoolean(
        habitId: habitId,
        versionId: versionId,
        lifecycleEventId: lifecycleEventId,
        name: 'Boolean',
        effectiveDate: date,
        schedule: schedule,
        metadata: metadata,
      );
    case 'duration':
      await BooleanDurationHabitService(db, clock).createDuration(
        habitId: habitId,
        versionId: versionId,
        lifecycleEventId: lifecycleEventId,
        name: 'Duration',
        effectiveDate: date,
        schedule: schedule,
        metadata: metadata,
        target: DurationTarget(targetSeconds: 1800),
      );
    case 'measurement':
      await MeasurementTimeRangeHabitService(db, clock).createMeasurement(
        habitId: habitId,
        versionId: versionId,
        lifecycleEventId: lifecycleEventId,
        name: 'Measurement',
        effectiveDate: date,
        schedule: schedule,
        metadata: metadata,
        target: MeasurementTarget(
          scaledTarget: 250,
          decimalPlaces: 2,
          unit: 'L',
          rule: MeasurementComparisonRule.atLeast,
        ),
      );
    case 'time_of_day':
      await MeasurementTimeRangeHabitService(db, clock).createTimeOfDay(
        habitId: habitId,
        versionId: versionId,
        lifecycleEventId: lifecycleEventId,
        name: 'Time',
        effectiveDate: date,
        schedule: schedule,
        metadata: metadata,
        target: TimeOfDayTarget(
          targetMinutesSinceMidnight: 330,
          rule: TimeComparisonRule.atOrBefore,
        ),
      );
    case 'range':
      await MeasurementTimeRangeHabitService(db, clock).createRange(
        habitId: habitId,
        versionId: versionId,
        lifecycleEventId: lifecycleEventId,
        name: 'Range',
        effectiveDate: date,
        schedule: schedule,
        metadata: metadata,
        target: RangeTarget(
          minScaled: 70,
          maxScaled: 85,
          decimalPlaces: 1,
          unit: 'hours',
        ),
      );
    default:
      throw ArgumentError.value(type);
  }
}

Future<Map<String, dynamic>> row(AppDatabase db, String sql) async =>
    (await db.customSelect(sql).getSingle()).data;

Future<void> checkSnapshot(
  AppDatabase db,
  String type, {
  required bool withMetadata,
}) async {
  final versionId = 'v_$type';
  final audit = await row(
    db,
    "SELECT * FROM habit_version_audit WHERE habit_id = 'h_$type'",
  );
  expect(audit['id'], isA<String>());
  expect((audit['id'] as String).trim(), isNotEmpty);
  expect(audit['operation'], 'create');
  expect(audit['previous_values'], isNull);
  final snapshot =
      jsonDecode(audit['updated_values'] as String) as Map<String, dynamic>;
  expect(snapshot.keys.toSet(), {
    'version',
    'schedule',
    'metadata',
    'lifecycle',
    'tracking_type',
    'target',
    'items',
  });
  final version = await row(
    db,
    "SELECT * FROM habit_versions WHERE id = '$versionId'",
  );
  final schedule = await row(
    db,
    "SELECT * FROM habit_schedules WHERE habit_version_id = '$versionId'",
  );
  final lifecycle = await row(
    db,
    "SELECT * FROM habit_lifecycle_events WHERE id = 'l_$type'",
  );
  expect(snapshot['version'], version);
  expect(snapshot['schedule'], schedule);
  expect(snapshot['lifecycle'], lifecycle);
  expect(snapshot['tracking_type'], type);
  expect(
    version['created_at_utc_us'],
    FixedClock().now().microsecondsSinceEpoch,
  );
  expect(audit['occurred_at_utc_us'], version['created_at_utc_us']);
  expect(lifecycle['created_at_utc_us'], version['created_at_utc_us']);
  expect(lifecycle['state'], 'active');
  expect(schedule['recurrence'], 'weekdays');
  expect(schedule['weekday_mask'], 73);
  if (withMetadata) {
    final metadata = await row(
      db,
      "SELECT * FROM habit_version_metadata WHERE habit_version_id = '$versionId'",
    );
    expect(snapshot['metadata'], metadata);
    expect(metadata['category'], 'Health');
    expect(metadata['is_private'], 1);
  } else {
    expect(snapshot['metadata'], isNull);
    expect(
      await db
          .customSelect(
            "SELECT * FROM habit_version_metadata WHERE habit_version_id = '$versionId'",
          )
          .get(),
      isEmpty,
    );
  }
  if (type == 'checklist') {
    final items = await db
        .customSelect(
          "SELECT * FROM habit_checklist_items WHERE habit_version_id = '$versionId'",
        )
        .get();
    expect(items, hasLength(2));
    expect(snapshot['target'], isNull);
    expect(snapshot['items'], unorderedEquals(items.map((item) => item.data)));
    expect((snapshot['items'] as List).map((item) => item['label']), [
      'First',
      'Second',
    ]);
  } else {
    final table = type == 'avoidance'
        ? 'habit_avoidance_targets'
        : 'habit_typed_targets';
    final target = await row(
      db,
      "SELECT * FROM $table WHERE habit_version_id = '$versionId'",
    );
    expect(snapshot['target'], target);
    expect(snapshot['items'], isEmpty);
    switch (type) {
      case 'avoidance':
        expect(target['max_incidents'], 2);
      case 'boolean':
        expect(target['tracking_type'], 'boolean');
      case 'duration':
        expect(target['target_seconds'], 1800);
      case 'measurement':
        expect(target['scaled_target'], 250);
        expect(target['decimal_places'], 2);
        expect(target['unit'], 'L');
        expect(target['comparison_rule'], 'at_least');
      case 'time_of_day':
        expect(target['target_minutes_since_midnight'], 330);
        expect(target['comparison_rule'], 'at_or_before');
      case 'range':
        expect(target['min_scaled'], 70);
        expect(target['max_scaled'], 85);
        expect(target['decimal_places'], 1);
        expect(target['unit'], 'hours');
    }
  }
}

void main() {
  for (final type in types) {
    for (final withMetadata in [true, false]) {
      test(
        '$type creation snapshots persisted rows with metadata=$withMetadata',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          await create(db, type, withMetadata: withMetadata);
          await checkSnapshot(db, type, withMetadata: withMetadata);
        },
      );
    }

    test(
      '$type audit insertion failure rolls back every creation record',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        await db.customStatement('''
        CREATE TRIGGER reject_creation_audit BEFORE INSERT ON habit_version_audit
        BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
      ''');
        await expectLater(create(db, type), throwsA(anything));
        for (final table in [
          'habits',
          'habit_versions',
          'habit_version_metadata',
          'habit_schedules',
          'habit_lifecycle_events',
          'habit_checklist_items',
          'habit_avoidance_targets',
          'habit_typed_targets',
          'habit_version_audit',
        ]) {
          expect(
            (await row(db, 'SELECT COUNT(*) AS n FROM $table'))['n'],
            0,
            reason: '$type left a row in $table',
          );
        }
      },
    );
  }

  test('reopening preserves new snapshots and legacy rows without fabricating audits', () async {
    final directory = await Directory.systemTemp.createTemp(
      'non_counter_audit_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File(path.join(directory.path, 'habits.sqlite'));
    final first = AppDatabase(NativeDatabase(file));
    await first.customStatement("INSERT INTO habits VALUES ('legacy', 42)");
    await first.customStatement(
      "INSERT INTO habit_versions VALUES ('legacy_v', 'legacy', 'Old', '2026-01-01', NULL, 42, 1)",
    );
    await first.customStatement(
      "INSERT INTO habit_avoidance_targets VALUES ('legacy_v', 3)",
    );
    for (final type in types) {
      await create(first, type);
    }
    await first.close();
    final reopened = AppDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    expect(await row(reopened, "SELECT * FROM habits WHERE id = 'legacy'"), {
      'id': 'legacy',
      'created_at_utc_us': 42,
    });
    expect(
      (await row(
        reopened,
        "SELECT * FROM habit_versions WHERE id = 'legacy_v'",
      ))['name'],
      'Old',
    );
    expect(
      (await row(
        reopened,
        "SELECT * FROM habit_avoidance_targets WHERE habit_version_id = 'legacy_v'",
      ))['max_incidents'],
      3,
    );
    expect(
      await reopened
          .customSelect(
            "SELECT * FROM habit_version_audit WHERE habit_id = 'legacy'",
          )
          .get(),
      isEmpty,
    );
    expect(
      (await row(
        reopened,
        'SELECT COUNT(*) AS n FROM habit_version_audit',
      ))['n'],
      types.length,
    );
    for (final type in types) {
      await checkSnapshot(reopened, type, withMetadata: true);
    }
  });
}
