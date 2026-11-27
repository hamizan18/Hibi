import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../data/gamification_service.dart';

final gamificationServiceProvider = Provider<GamificationService>(
  (ref) => GamificationService(
    ref.watch(databaseProvider),
    ref.watch(appClockProvider),
  ),
);
