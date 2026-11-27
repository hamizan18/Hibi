import 'measurement_time_range_habit.dart';

enum DynamicScoreType { measurement, timeOfDay, range }

class HabitScoringConfig {
  const HabitScoringConfig.measurement()
    : type = DynamicScoreType.measurement,
      tolerance = null;

  const HabitScoringConfig.timeOfDay({required int toleranceMinutes})
    : type = DynamicScoreType.timeOfDay,
      tolerance = toleranceMinutes;

  const HabitScoringConfig.range({required int toleranceScaled})
    : type = DynamicScoreType.range,
      tolerance = toleranceScaled;

  final DynamicScoreType type;
  final int? tolerance;
}

class DynamicNormalizedScoring {
  const DynamicNormalizedScoring._();

  static double? measurement({
    required int actual,
    required int target,
    required MeasurementComparisonRule rule,
  }) {
    switch (rule) {
      case MeasurementComparisonRule.atLeast:
        if (actual >= target) return 1;
        if (target <= 0) return null;
        if (actual <= 0) return 0;
        return actual / target;
      case MeasurementComparisonRule.atMost:
        if (actual <= target) return 1;
        if (target < 0) return null;
        if (target == 0) return 0;
        return target / actual;
      case MeasurementComparisonRule.exact:
        return actual == target ? 1 : null;
    }
  }

  static double? timeOfDay({
    required int actualMinutes,
    required int targetMinutes,
    required TimeComparisonRule rule,
    required int toleranceMinutes,
    required int dayOffset,
  }) {
    if (actualMinutes < 0 ||
        actualMinutes >= 1440 ||
        targetMinutes < 0 ||
        targetMinutes >= 1440 ||
        dayOffset < -1 ||
        dayOffset > 1 ||
        toleranceMinutes <= 0) {
      return null;
    }
    final int delta = actualMinutes + dayOffset * 1440 - targetMinutes;
    int deviation;
    switch (rule) {
      case TimeComparisonRule.atOrBefore:
        deviation = delta > 0 ? delta : 0;
      case TimeComparisonRule.atOrAfter:
        deviation = delta < 0 ? -delta : 0;
      case TimeComparisonRule.atOrNear:
        final int direct = (actualMinutes - targetMinutes).abs();
        deviation = direct < 1440 - direct ? direct : 1440 - direct;
    }
    if (deviation >= toleranceMinutes) return 0;
    return 1 - deviation / toleranceMinutes;
  }

  static double? range({
    required int actual,
    required int min,
    required int max,
    required int toleranceScaled,
  }) {
    if (min > max || toleranceScaled <= 0) return null;
    if (actual >= min && actual <= max) return 1;
    final double distance = actual < min
        ? _distance(min, actual)
        : _distance(actual, max);
    if (distance >= toleranceScaled) return 0;
    return 1 - distance / toleranceScaled;
  }

  // Halving before subtracting keeps the integer intermediate in int64 range.
  static double _distance(int greater, int lesser) =>
      (greater ~/ 2 - lesser ~/ 2).toDouble() * 2 +
      (greater.remainder(2) - lesser.remainder(2));
}
