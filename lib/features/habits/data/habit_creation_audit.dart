import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';

/// Records the persisted configuration inside the caller's creation transaction.
/// Existing habits are never backfilled because their original values are unknown.
Future<void> writeNonCounterCreationAudit(
  AppDatabase db, {
  required String habitId,
  required String versionId,
  required String lifecycleEventId,
  required String trackingType,
}) async {
  final version = await db
      .customSelect(
        'SELECT * FROM habit_versions WHERE id = ? AND habit_id = ?',
        variables: [Variable<String>(versionId), Variable<String>(habitId)],
      )
      .getSingle();
  final schedule = await db
      .customSelect(
        'SELECT * FROM habit_schedules WHERE habit_version_id = ?',
        variables: [Variable<String>(versionId)],
      )
      .getSingle();
  final metadata = await db
      .customSelect(
        'SELECT * FROM habit_version_metadata WHERE habit_version_id = ?',
        variables: [Variable<String>(versionId)],
      )
      .getSingleOrNull();
  final lifecycle = await db
      .customSelect(
        'SELECT * FROM habit_lifecycle_events WHERE id = ? AND habit_id = ?',
        variables: [
          Variable<String>(lifecycleEventId),
          Variable<String>(habitId),
        ],
      )
      .getSingle();

  final targetSql = switch (trackingType) {
    'checklist' => null,
    'avoidance' =>
      'SELECT * FROM habit_avoidance_targets WHERE habit_version_id = ?',
    'boolean' || 'duration' || 'measurement' || 'time_of_day' || 'range' => 'SELECT * FROM habit_typed_targets WHERE habit_version_id = ? AND tracking_type = ?',
    _ => throw ArgumentError.value(trackingType, 'trackingType'),
  };
  final target = targetSql == null
      ? null
      : await db
            .customSelect(
              targetSql,
              variables: [
                Variable<String>(versionId),
                if (trackingType != 'avoidance') Variable<String>(trackingType),
              ],
            )
            .getSingle();
  final items = trackingType == 'checklist'
      ? await db
            .customSelect(
              'SELECT * FROM habit_checklist_items WHERE habit_version_id = ? ORDER BY display_order, id',
              variables: [Variable<String>(versionId)],
            )
            .get()
      : <QueryRow>[];
  if (trackingType == 'checklist' && items.isEmpty) {
    throw StateError('Checklist creation requires items');
  }
  final scoring = await db
      .customSelect(
        'SELECT * FROM habit_version_scoring WHERE habit_version_id = ?',
        variables: [Variable<String>(versionId)],
      )
      .getSingleOrNull();

  final random = Random.secure();
  final auditId = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  await db.customStatement(
    '''
    INSERT INTO habit_version_audit
      (id, habit_id, operation, previous_values, updated_values, occurred_at_utc_us)
    VALUES (?, ?, 'create', NULL, ?, ?)
    ''',
    [
      auditId,
      habitId,
      jsonEncode({
        'version': version.data,
        'schedule': schedule.data,
        'metadata': metadata?.data,
        'lifecycle': lifecycle.data,
        'tracking_type': trackingType,
        'target': target?.data,
        'scoring': scoring?.data,
        'items': [for (final item in items) item.data],
      }),
      version.read<int>('created_at_utc_us'),
    ],
  );
}
