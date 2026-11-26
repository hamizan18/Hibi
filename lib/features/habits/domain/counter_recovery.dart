import '../data/counter_resolution.dart';
import 'counter_progress.dart';

/// Recovery completion state against an occurrence's original failed deficit.
enum CounterRecoveryStatus { unrecovered, partiallyRecovered, recovered }

/// Bounded recovery calculation against an explicitly failed counter occurrence.
/// Original same-day progress is preserved separately from recovered quantities.
class CounterRecovery {
  const CounterRecovery._({
    required this.target,
    required this.recordedTotal,
    required this.initialDeficit,
    required this.recoveredTotal,
    required this.remainingDeficit,
    required this.status,
  });

  factory CounterRecovery.fromEvents({
    required CounterProgress progress,
    required CounterResolutionState? resolution,
    required Iterable<int> quantities,
  }) {
    if (progress.status == CounterProgressStatus.completed ||
        progress.total >= progress.target) {
      throw StateError('Completed occurrences have no deficit to recover');
    }
    if (resolution != CounterResolutionState.failed) {
      throw StateError(
        'Only explicitly failed occurrences are eligible for recovery',
      );
    }
    final initialDeficit = progress.target - progress.total;
    var recoveredTotal = 0;
    for (final quantity in quantities) {
      if (quantity <= 0) {
        throw RangeError.value(quantity, 'quantity', 'Must be positive');
      }
      final remaining = initialDeficit - recoveredTotal;
      if (quantity > remaining) {
        throw RangeError.value(
          quantity,
          'quantity',
          'Recovery cannot exceed remaining deficit',
        );
      }
      recoveredTotal += quantity;
    }
    final remainingDeficit = initialDeficit - recoveredTotal;
    final status = recoveredTotal == 0
        ? CounterRecoveryStatus.unrecovered
        : remainingDeficit > 0
        ? CounterRecoveryStatus.partiallyRecovered
        : CounterRecoveryStatus.recovered;
    return CounterRecovery._(
      target: progress.target,
      recordedTotal: progress.total,
      initialDeficit: initialDeficit,
      recoveredTotal: recoveredTotal,
      remainingDeficit: remainingDeficit,
      status: status,
    );
  }

  final int target;
  final int recordedTotal;
  final int initialDeficit;
  final int recoveredTotal;
  final int remainingDeficit;
  final CounterRecoveryStatus status;
}
