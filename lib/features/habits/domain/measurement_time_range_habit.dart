enum MeasurementComparisonRule { atLeast, atMost, exact }

enum TimeComparisonRule { atOrBefore, atOrAfter, atOrNear }

enum TypedValueStatus { completed, partial, failed, excused }

/// Fixed-scale integer measurement target (decimalPlaces 0..6, no floating point).
class MeasurementTarget {
  MeasurementTarget({
    required this.scaledTarget,
    required this.decimalPlaces,
    required String unit,
    required this.rule,
  }) : unit = unit.trim() {
    if (decimalPlaces < 0 || decimalPlaces > 6) {
      throw RangeError.range(decimalPlaces, 0, 6, 'decimalPlaces');
    }
    if (this.unit.isEmpty) {
      throw ArgumentError.value(unit, 'unit', 'Must not be blank');
    }
  }

  final int scaledTarget;
  final int decimalPlaces;
  final String unit;
  final MeasurementComparisonRule rule;

  TypedValueStatus evaluate(int scaledValue) {
    final matches = switch (rule) {
      MeasurementComparisonRule.atLeast => scaledValue >= scaledTarget,
      MeasurementComparisonRule.atMost => scaledValue <= scaledTarget,
      MeasurementComparisonRule.exact => scaledValue == scaledTarget,
    };
    return matches ? TypedValueStatus.completed : TypedValueStatus.partial;
  }
}

/// Time-of-day target in minutes since local midnight (0..1439).
class TimeOfDayTarget {
  TimeOfDayTarget({
    required this.targetMinutesSinceMidnight,
    required this.rule,
  }) {
    if (targetMinutesSinceMidnight < 0 || targetMinutesSinceMidnight > 1439) {
      throw RangeError.range(
        targetMinutesSinceMidnight,
        0,
        1439,
        'targetMinutesSinceMidnight',
      );
    }
  }

  final int targetMinutesSinceMidnight;
  final TimeComparisonRule rule;

  TypedValueStatus evaluate(
    int loggedMinutesSinceMidnight, {
    int dayOffset = 0,
  }) {
    if (loggedMinutesSinceMidnight < 0 || loggedMinutesSinceMidnight > 1439) {
      throw RangeError.range(
        loggedMinutesSinceMidnight,
        0,
        1439,
        'loggedMinutesSinceMidnight',
      );
    }
    if (dayOffset < -1 || dayOffset > 1) {
      throw RangeError.range(dayOffset, -1, 1, 'dayOffset');
    }
    final absoluteMinutes = loggedMinutesSinceMidnight + dayOffset * 1440;
    final matches = switch (rule) {
      TimeComparisonRule.atOrBefore =>
        absoluteMinutes <= targetMinutesSinceMidnight,
      TimeComparisonRule.atOrAfter =>
        absoluteMinutes >= targetMinutesSinceMidnight,
      TimeComparisonRule.atOrNear =>
        loggedMinutesSinceMidnight == targetMinutesSinceMidnight,
    };
    return matches
        ? TypedValueStatus.completed
        : rule == TimeComparisonRule.atOrNear
        ? TypedValueStatus.partial
        : TypedValueStatus.failed;
  }
}

/// Inclusive fixed-scale integer range target `[minScaled, maxScaled]`.
class RangeTarget {
  RangeTarget({
    required this.minScaled,
    required this.maxScaled,
    required this.decimalPlaces,
    required String unit,
  }) : unit = unit.trim() {
    if (decimalPlaces < 0 || decimalPlaces > 6) {
      throw RangeError.range(decimalPlaces, 0, 6, 'decimalPlaces');
    }
    if (maxScaled < minScaled) {
      throw ArgumentError('maxScaled must be >= minScaled');
    }
    if (this.unit.isEmpty) {
      throw ArgumentError.value(unit, 'unit', 'Must not be blank');
    }
  }

  final int minScaled;
  final int maxScaled;
  final int decimalPlaces;
  final String unit;

  TypedValueStatus evaluate(int scaledValue) =>
      (scaledValue >= minScaled && scaledValue <= maxScaled)
      ? TypedValueStatus.completed
      : TypedValueStatus.partial;
}
