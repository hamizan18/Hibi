import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../data/finance_service.dart';

final financeServiceProvider = Provider<FinanceService>(
  (ref) =>
      FinanceService(ref.watch(databaseProvider), ref.watch(appClockProvider)),
);
