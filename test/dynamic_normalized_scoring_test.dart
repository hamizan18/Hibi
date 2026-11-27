import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/features/habits/domain/dynamic_normalized_scoring.dart';
import 'package:hibi/features/habits/domain/measurement_time_range_habit.dart';

void main() {
  group('scoring configuration', () {
    test('preserves type and explicit tolerance', () {
      const measurement = HabitScoringConfig.measurement();
      const time = HabitScoringConfig.timeOfDay(toleranceMinutes: 30);
      const range = HabitScoringConfig.range(toleranceScaled: 25);
      expect(measurement.type, DynamicScoreType.measurement);
      expect(measurement.tolerance, isNull);
      expect(time.type, DynamicScoreType.timeOfDay);
      expect(time.tolerance, 30);
      expect(range.type, DynamicScoreType.range);
      expect(range.tolerance, 25);
    });
  });

  group('measurement', () {
    double? score(int actual, int target, MeasurementComparisonRule rule) =>
        DynamicNormalizedScoring.measurement(
          actual: actual,
          target: target,
          rule: rule,
        );
    test(
      'at least clamps positive targets and handles nonpositive targets',
      () {
        const rule = MeasurementComparisonRule.atLeast;
        expect(score(5, 10, rule), .5);
        expect(score(10, 10, rule), 1);
        expect(score(20, 10, rule), 1);
        expect(score(-2, 10, rule), 0);
        expect(score(0, 0, rule), 1);
        expect(score(-1, 0, rule), isNull);
        expect(score(-2, -3, rule), 1);
        expect(score(-4, -3, rule), isNull);
      },
    );
    test(
      'at most handles zero and negative targets without division by zero',
      () {
        const rule = MeasurementComparisonRule.atMost;
        expect(score(5, 10, rule), 1);
        expect(score(10, 10, rule), 1);
        expect(score(20, 10, rule), .5);
        expect(score(0, 0, rule), 1);
        expect(score(1, 0, rule), 0);
        expect(score(-4, -3, rule), 1);
        expect(score(-2, -3, rule), isNull);
      },
    );
    test('exact matches only, including negative and zero values', () {
      const rule = MeasurementComparisonRule.exact;
      expect(score(0, 0, rule), 1);
      expect(score(-3, -3, rule), 1);
      expect(score(-2, -3, rule), isNull);
      expect(score(2, 3, rule), isNull);
    });
    test('supports signed 64-bit boundaries', () {
      const low = -9223372036854775807 - 1;
      const high = 9223372036854775807;
      expect(score(low, high, MeasurementComparisonRule.atLeast), 0);
      expect(score(high, low, MeasurementComparisonRule.atMost), isNull);
      expect(score(high, high, MeasurementComparisonRule.exact), 1);
    });
  });

  group('time of day', () {
    double? score(
      int actual,
      int target,
      TimeComparisonRule rule,
      int tolerance, [
      int offset = 0,
    ]) => DynamicNormalizedScoring.timeOfDay(
      actualMinutes: actual,
      targetMinutes: target,
      rule: rule,
      toleranceMinutes: tolerance,
      dayOffset: offset,
    );
    test('before and after use directional day offsets', () {
      const before = TimeComparisonRule.atOrBefore;
      const after = TimeComparisonRule.atOrAfter;
      expect(score(590, 600, before, 20), 1);
      expect(score(610, 600, before, 20), .5);
      expect(score(620, 600, before, 20), 0);
      expect(score(610, 600, after, 20), 1);
      expect(score(590, 600, after, 20), .5);
      expect(score(10, 1430, before, 40, 1), .5);
      expect(score(1430, 10, after, 40, -1), .5);
      expect(score(10, 1430, before, 40), 1);
      expect(score(1430, 10, after, 40), 1);
    });
    test('near uses shortest circular distance, independently of offset', () {
      const near = TimeComparisonRule.atOrNear;
      expect(score(0, 0, near, 20), 1);
      expect(score(5, 1435, near, 20), .5);
      expect(score(1435, 5, near, 20, -1), .5);
      expect(score(5, 1435, near, 20, 1), .5);
      expect(score(720, 0, near, 720), 0);
    });
    test('rejects invalid inputs and tolerance even when satisfied', () {
      const rule = TimeComparisonRule.atOrBefore;
      expect(score(-1, 0, rule, 10), isNull);
      expect(score(1440, 0, rule, 10), isNull);
      expect(score(0, -1, rule, 10), isNull);
      expect(score(0, 1440, rule, 10), isNull);
      expect(score(0, 0, rule, 0), isNull);
      expect(score(0, 0, rule, -1), isNull);
      expect(score(0, 0, rule, 10, -2), isNull);
      expect(score(0, 0, rule, 10, 2), isNull);
    });
  });

  group('range', () {
    double? score(int actual, int min, int max, int tolerance) =>
        DynamicNormalizedScoring.range(
          actual: actual,
          min: min,
          max: max,
          toleranceScaled: tolerance,
        );
    test('scores inside and decays symmetrically outside', () {
      expect(score(10, 10, 20, 4), 1);
      expect(score(15, 10, 20, 4), 1);
      expect(score(20, 10, 20, 4), 1);
      expect(score(8, 10, 20, 4), .5);
      expect(score(22, 10, 20, 4), .5);
      expect(score(6, 10, 20, 4), 0);
      expect(score(25, 10, 20, 4), 0);
      expect(score(-12, -10, -10, 4), .5);
    });
    test('rejects invalid bounds and tolerance', () {
      expect(score(10, 20, 10, 5), isNull);
      expect(score(10, 10, 20, 0), isNull);
      expect(score(10, 10, 20, -1), isNull);
    });
    test('distance does not overflow at signed 64-bit boundaries', () {
      const low = -9223372036854775807 - 1;
      const high = 9223372036854775807;
      expect(score(low, high, high, high), 0);
      expect(score(high, low, low, high), 0);
      expect(score(high - 1, high, high, 2), .5);
      expect(score(low + 1, low, low, 2), .5);
    });
  });
}
