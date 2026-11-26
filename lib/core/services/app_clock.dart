import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Supplies local device time; override the provider for deterministic tests.
abstract interface class AppClock {
  DateTime now();
}

class SystemAppClock implements AppClock {
  const SystemAppClock();

  @override
  DateTime now() => DateTime.now();
}

final appClockProvider = Provider<AppClock>((ref) => const SystemAppClock());

String japaneseDate(DateTime date) {
  const weekdays = ['月', '火', '水', '木', '金', '土', '日'];
  return '${date.year}年${date.month}月${date.day}日(${weekdays[date.weekday - 1]})';
}
