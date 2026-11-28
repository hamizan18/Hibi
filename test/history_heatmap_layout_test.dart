import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:hibi/features/habits/presentation/history_analytics_screen.dart';

void main() {
  testWidgets('heatmap dates and N/A remain readable on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: HistoryAnalyticsView(asOfDate: LocalDate(2026, 11, 26)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final cell = find.byKey(const Key('heatmap-cell-2026-11-20'));
    await tester.ensureVisible(cell);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: cell, matching: find.text('11-20')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: cell, matching: find.text('N/A')),
      findsOneWidget,
    );
    expect(tester.getSize(cell).width, greaterThan(150));
    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(find.text('Selected Day: 2026-11-20'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
