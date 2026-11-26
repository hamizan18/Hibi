/// A counter target uses whole, positive units, never floating-point values.
class CounterTarget {
  CounterTarget({required this.count, required String unit})
    : unit = unit.trim() {
    if (count <= 0) {
      throw RangeError.value(count, 'count', 'Must be a positive whole number');
    }
    if (this.unit.isEmpty) {
      throw ArgumentError.value(unit, 'unit', 'Must not be blank');
    }
  }

  final int count;
  final String unit;
}
