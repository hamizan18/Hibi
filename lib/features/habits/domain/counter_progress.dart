/// Counter status derived solely from recorded quantities, not scheduling or failure.
enum CounterProgressStatus { pending, partial, completed }

/// Exact whole-number progress against the occurrence's historical target.
class CounterProgress {
  const CounterProgress._(this.target, this.total, this.status);

  factory CounterProgress.fromEvents({
    required int target,
    required Iterable<int> quantities,
  }) {
    const maximum = 9223372036854775807;
    if (target <= 0 || target > maximum) {
      throw RangeError.value(
        target,
        'target',
        'Must be a positive signed 64-bit integer',
      );
    }
    var total = 0;
    for (final quantity in quantities) {
      if (quantity <= 0 || quantity > maximum - total) {
        throw RangeError.value(
          quantity,
          'quantity',
          'Must be positive and fit the signed 64-bit total',
        );
      }
      total += quantity;
    }
    final status = total == 0
        ? CounterProgressStatus.pending
        : total < target
        ? CounterProgressStatus.partial
        : CounterProgressStatus.completed;
    return CounterProgress._(target, total, status);
  }

  final int target;
  final int total;
  final CounterProgressStatus status;
}
