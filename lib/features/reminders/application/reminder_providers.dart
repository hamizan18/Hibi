import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../data/reminder_service.dart';

final localNotificationGatewayProvider = Provider<LocalNotificationGateway>(
  (ref) => FlutterLocalNotificationsGateway(),
);

final reminderServiceProvider = Provider<ReminderService>(
  (ref) => ReminderService(
    ref.watch(databaseProvider),
    ref.watch(appClockProvider),
    ref.watch(localNotificationGatewayProvider),
  ),
);
