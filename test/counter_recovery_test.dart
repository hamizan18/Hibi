import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/features/habits/data/counter_resolution.dart';
import 'package:hibi/features/habits/domain/counter_progress.dart';
import 'package:hibi/features/habits/domain/counter_recovery.dart';

void main() {
  test('unrecovered, partial and multi-step exact recovery preserve original progress', () {
    final progress = CounterProgress.fromEvents(
      target: 5,
      quantities: const [2],
    );

    final unrecovered = CounterRecovery.fromEvents(
      progress: progress,
      resolution: CounterResolutionState.failed,
      quantities: const [],
    );
    expect(unrecovered.target, 5);
    expect(unrecovered.recordedTotal, 2);
    expect(unrecovered.initialDeficit, 3);
    expect(unrecovered.recoveredTotal, 0);
    expect(unrecovered.remainingDeficit, 3);
    expect(unrecovered.status, CounterRecoveryStatus.unrecovered);

    final partial = CounterRecovery.fromEvents(
      progress: progress,
      resolution: CounterResolutionState.failed,
      quantities: const [1],
    );
    expect(partial.recordedTotal, 2);
    expect(partial.initialDeficit, 3);
    expect(partial.recoveredTotal, 1);
    expect(partial.remainingDeficit, 2);
    expect(partial.status, CounterRecoveryStatus.partiallyRecovered);

    final recovered = CounterRecovery.fromEvents(
      progress: progress,
      resolution: CounterResolutionState.failed,
      quantities: const [1, 2],
    );
    expect(recovered.recordedTotal, 2);
    expect(recovered.initialDeficit, 3);
    expect(recovered.recoveredTotal, 3);
    expect(recovered.remainingDeficit, 0);
    expect(recovered.status, CounterRecoveryStatus.recovered);
  });

  test(
    'zero-progress failed occurrence can be fully recovered in multiple steps',
    () {
      final progress = CounterProgress.fromEvents(
        target: 10,
        quantities: const [],
      );
      final recovered = CounterRecovery.fromEvents(
        progress: progress,
        resolution: CounterResolutionState.failed,
        quantities: const [4, 6],
      );
      expect(recovered.recordedTotal, 0);
      expect(recovered.initialDeficit, 10);
      expect(recovered.recoveredTotal, 10);
      expect(recovered.remainingDeficit, 0);
      expect(recovered.status, CounterRecoveryStatus.recovered);
    },
  );

  test(
    'unresolved, excused and completed occurrences are rejected for recovery',
    () {
      final partial = CounterProgress.fromEvents(
        target: 5,
        quantities: const [2],
      );
      expect(
        () => CounterRecovery.fromEvents(
          progress: partial,
          resolution: null,
          quantities: const [1],
        ),
        throwsStateError,
      );
      expect(
        () => CounterRecovery.fromEvents(
          progress: partial,
          resolution: CounterResolutionState.excused,
          quantities: const [1],
        ),
        throwsStateError,
      );

      final completed = CounterProgress.fromEvents(
        target: 5,
        quantities: const [5],
      );
      expect(
        () => CounterRecovery.fromEvents(
          progress: completed,
          resolution: CounterResolutionState.failed,
          quantities: const [1],
        ),
        throwsStateError,
      );
    },
  );

  test('non-positive recovery quantities and quantities exceeding deficit are rejected', () {
    final progress = CounterProgress.fromEvents(
      target: 5,
      quantities: const [2],
    );
    for (final invalid in [0, -1]) {
      expect(
        () => CounterRecovery.fromEvents(
          progress: progress,
          resolution: CounterResolutionState.failed,
          quantities: [invalid],
        ),
        throwsRangeError,
      );
    }
    expect(
      () => CounterRecovery.fromEvents(
        progress: progress,
        resolution: CounterResolutionState.failed,
        quantities: const [4],
      ),
      throwsRangeError,
    );
    expect(
      () => CounterRecovery.fromEvents(
        progress: progress,
        resolution: CounterResolutionState.failed,
        quantities: const [2, 2],
      ),
      throwsRangeError,
    );
  });

  test('supports signed 64-bit maximum deficit boundary without overflow', () {
    const max = 9223372036854775807;
    final progress = CounterProgress.fromEvents(
      target: max,
      quantities: const [max - 5],
    );
    final recovered = CounterRecovery.fromEvents(
      progress: progress,
      resolution: CounterResolutionState.failed,
      quantities: const [2, 3],
    );
    expect(recovered.initialDeficit, 5);
    expect(recovered.recoveredTotal, 5);
    expect(recovered.remainingDeficit, 0);
    expect(recovered.status, CounterRecoveryStatus.recovered);
    expect(
      () => CounterRecovery.fromEvents(
        progress: progress,
        resolution: CounterResolutionState.failed,
        quantities: const [2, 4],
      ),
      throwsRangeError,
    );
  });
}
