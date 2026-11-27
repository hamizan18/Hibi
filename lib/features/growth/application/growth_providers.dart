import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../data/focus_service.dart';
import '../data/goal_service.dart';
import '../data/journal_service.dart';

final journalServiceProvider = Provider<JournalService>(
  (ref) =>
      JournalService(ref.watch(databaseProvider), ref.watch(appClockProvider)),
);

final goalServiceProvider = Provider<GoalService>(
  (ref) =>
      GoalService(ref.watch(databaseProvider), ref.watch(appClockProvider)),
);

final focusServiceProvider = Provider<FocusService>(
  (ref) =>
      FocusService(ref.watch(databaseProvider), ref.watch(appClockProvider)),
);
