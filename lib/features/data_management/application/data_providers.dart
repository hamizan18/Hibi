import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../data/backup_restore_service.dart';
import '../data/export_service.dart';

final backupRestoreServiceProvider = Provider<BackupRestoreService>(
  (ref) => BackupRestoreService(
    ref.watch(databaseProvider),
    ref.watch(appClockProvider),
  ),
);

final exportServiceProvider = Provider<ExportService>(
  (ref) =>
      ExportService(ref.watch(databaseProvider), ref.watch(appClockProvider)),
);
