import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/app/app.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/security/app_lock_service.dart';
import 'package:hibi/core/security/security_providers.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/finance/data/finance_service.dart';
import 'package:hibi/features/finance/domain/finance_models.dart';
import 'package:hibi/features/finance/presentation/finance_screen.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

class _TestClock implements AppClock {
  @override
  DateTime now() => DateTime(2026, 11, 26, 12);
}

void main() {
  testWidgets('Wallet form keeps outlined fields separated at large text scale', (
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
        overrides: [
          databaseProvider.overrideWithValue(db),
          appClockProvider.overrideWithValue(_TestClock()),
        ],
        child: MaterialApp(
          theme: ThemeData(
            inputDecorationTheme: const InputDecorationTheme(
              border: OutlineInputBorder(),
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: FinanceView(asOfDate: LocalDate(2026, 11, 26)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add wallet'));
    await tester.tap(find.text('Add wallet'));
    await tester.pumpAndSettle();

    final name = find.widgetWithText(TextField, 'Wallet name');
    final opening = find.widgetWithText(
      TextField,
      'Opening balance (integer IDR)',
    );
    await tester.enterText(name, 'Cash');
    await tester.ensureVisible(opening);
    await tester.tap(opening);
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(opening).dy - tester.getBottomLeft(name).dy, 16);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'FinanceView creates wallets, categories, transactions, transfers, budgets and reflects audited edits',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = _TestClock();
      final today = LocalDate(2026, 11, 26);

      // Seed 2 wallets and 1 expense category to keep widget interaction fast & focused
      final service = FinanceService(db, clock);
      await service.createWallet(
        id: 'w_cash',
        auditId: 'a_w1',
        name: 'Cash',
        openingBalanceIdr: 500000,
        openingDate: today,
      );
      await service.createWallet(
        id: 'w_bank',
        auditId: 'a_w2',
        name: 'Bank',
        openingBalanceIdr: 1000000,
        openingDate: today,
      );
      await service.createCategory(
        id: 'c_food',
        auditId: 'a_c1',
        name: 'Food',
        kind: FinanceCategoryKind.expense,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appClockProvider.overrideWithValue(clock),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: FinanceView(asOfDate: today)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Total recorded wallet balance: Rp 1.500.000'),
        findsOneWidget,
      );

      // Add expense transaction of Rp 100.000
      final addTxBtn = find.text('Add transaction');
      await tester.ensureVisible(addTxBtn);
      await tester.tap(addTxBtn);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Amount (IDR)'),
        '100000',
      );
      final saveTx = find.byKey(const Key('finance-save-tx'));
      await tester.ensureVisible(saveTx);
      await tester.tap(saveTx);
      await tester.pumpAndSettle();

      expect(find.text('Period expense: Rp 100.000'), findsOneWidget);
      expect(
        find.text('Total recorded wallet balance: Rp 1.400.000'),
        findsOneWidget,
      );

      // Edit expense transaction to Rp 150.000
      final editBtn = find.text('Edit');
      await tester.ensureVisible(editBtn);
      await tester.tap(editBtn);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Updated amount (IDR)'),
        '150000',
      );
      await tester.tap(find.text('Save edit'));
      await tester.pumpAndSettle();

      expect(find.text('Period expense: Rp 150.000'), findsOneWidget);
      expect(
        find.text('Total recorded wallet balance: Rp 1.350.000'),
        findsOneWidget,
      );

      // Add atomic transfer of Rp 200.000 (excluded from income/expense!)
      final addTrBtn = find.text('Add transfer');
      await tester.ensureVisible(addTrBtn);
      await tester.tap(addTrBtn);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Transfer amount (IDR)'),
        '200000',
      );
      final saveTr = find.byKey(const Key('finance-save-transfer'));
      await tester.ensureVisible(saveTr);
      await tester.tap(saveTr);
      await tester.pumpAndSettle();

      // Income/expense unchanged, total wallet balance unchanged (Rp 1.350.000)
      expect(find.text('Period expense: Rp 150.000'), findsOneWidget);
      expect(
        find.text('Total recorded wallet balance: Rp 1.350.000'),
        findsOneWidget,
      );
      expect(find.textContaining('Rp 200.000 (1 transfers)'), findsOneWidget);

      // Add expense budget of Rp 120.000 -> immediately shows [OVER BUDGET]
      final addBudgetBtn = find.text('Add budget');
      await tester.ensureVisible(addBudgetBtn);
      await tester.tap(addBudgetBtn);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Budget limit (IDR)'),
        '120000',
      );
      final saveBudget = find.byKey(const Key('finance-save-budget'));
      await tester.ensureVisible(saveBudget);
      await tester.tap(saveBudget);
      await tester.pumpAndSettle();

      expect(find.textContaining('[OVER BUDGET]'), findsOneWidget);
    },
  );

  testWidgets('HibiApp navigates to operational Finance tab', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appClockProvider.overrideWithValue(_TestClock()),
          databaseInitializationProvider.overrideWith((ref) async {}),
          secureKeyValueStoreProvider.overrideWithValue(
            InMemorySecureKeyValueStore(),
          ),
        ],
        child: const HibiApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finance'));
    await tester.pumpAndSettle();
    expect(find.text('Finance (IDR)'), findsOneWidget);
    expect(find.byKey(const Key('finance-summary-card')), findsOneWidget);
  });
}
