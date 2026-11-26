import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/habit_metadata.dart';

/// Stores and retrieves version-scoped habit metadata without inferring defaults
/// for unconfigured legacy versions.
class HabitMetadataStore {
  const HabitMetadataStore(this._db);

  final AppDatabase _db;

  Future<void> insert(String versionId, HabitMetadata metadata) =>
      _db.customStatement(
        '''
      INSERT INTO habit_version_metadata
        (habit_version_id, description, symbol, category, priority,
         is_private, recovery_enabled, include_in_score, include_in_streak,
         include_in_rewards, display_order)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
        [
          versionId,
          metadata.description,
          metadata.symbol,
          metadata.category,
          metadata.priority.name,
          metadata.isPrivate ? 1 : 0,
          metadata.recoveryEnabled ? 1 : 0,
          metadata.includeInScore ? 1 : 0,
          metadata.includeInStreak ? 1 : 0,
          metadata.includeInRewards ? 1 : 0,
          metadata.displayOrder,
        ],
      );

  Future<HabitMetadata?> findForVersion(String versionId) async {
    final row = await _db
        .customSelect(
          '''
      SELECT description, symbol, category, priority, is_private,
             recovery_enabled, include_in_score, include_in_streak,
             include_in_rewards, display_order
      FROM habit_version_metadata
      WHERE habit_version_id = ?
      ''',
          variables: [Variable<String>(versionId)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    return HabitMetadata(
      description: row.readNullable<String>('description'),
      symbol: row.readNullable<String>('symbol'),
      category: row.read<String>('category'),
      priority: HabitPriority.values.byName(row.read<String>('priority')),
      isPrivate: row.read<int>('is_private') == 1,
      recoveryEnabled: row.read<int>('recovery_enabled') == 1,
      includeInScore: row.read<int>('include_in_score') == 1,
      includeInStreak: row.read<int>('include_in_streak') == 1,
      includeInRewards: row.read<int>('include_in_rewards') == 1,
      displayOrder: row.read<int>('display_order'),
    );
  }
}
