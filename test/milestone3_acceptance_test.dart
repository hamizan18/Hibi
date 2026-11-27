import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/finance/data/finance_service.dart';
import 'package:hibi/features/finance/domain/finance_models.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as path;

class _AcceptanceClock implements AppClock {
  DateTime current = DateTime(2026, 11, 20, 9);
  @override
  DateTime now() => current;
}

void main() {
  test('Milestone 3 acceptance (T-007): integer IDR opening balances, income, expense, atomic transfers excluded from cash flow, audited edits and expense budgets persist across disk reopen', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'hibi_m3_acceptance_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final dbFile = File(path.join(tempDir.path, 'hibi_m3.sqlite'));
    final clock = _AcceptanceClock();

    final db1 = AppDatabase(NativeDatabase(dbFile));
    try {
      final service = FinanceService(db1, clock);
      final nov1 = LocalDate(2026, 11, 1);
      final nov20 = LocalDate(2026, 11, 20);
      final nov25 = LocalDate(2026, 11, 25);
      final nov30 = LocalDate(2026, 11, 30);

      await service.createWallet(
        id: 'w_cash',
        auditId: 'aud_w1',
        name: 'Cash',
        openingBalanceIdr: 300000,
        openingDate: nov1,
      );
      await service.createWallet(
        id: 'w_bank',
        auditId: 'aud_w2',
        name: 'Bank BCA',
        openingBalanceIdr: 5000000,
        openingDate: nov1,
      );
      await service.createCategory(
        id: 'c_salary',
        auditId: 'aud_c1',
        name: 'Salary',
        kind: FinanceCategoryKind.income,
      );
      await service.createCategory(
        id: 'c_food',
        auditId: 'aud_c2',
        name: 'Food',
        kind: FinanceCategoryKind.expense,
      );

      // Income Rp 7.500.000 to Bank
      await service.createTransaction(
        id: 'tx_sal',
        auditId: 'aud_tx1',
        walletId: 'w_bank',
        categoryId: 'c_salary',
        type: FinanceTransactionType.income,
        amountIdr: 7500000,
        localDate: nov20,
      );

      // Expense Rp 450.000 from Cash
      await service.createTransaction(
        id: 'tx_food',
        auditId: 'aud_tx2',
        walletId: 'w_cash',
        categoryId: 'c_food',
        type: FinanceTransactionType.expense,
        amountIdr: 450000,
        localDate: nov20,
      );

      // Atomic transfer Rp 1.000.000 from Bank -> Cash
      await service.createTransfer(
        id: 'tr_atm',
        auditId: 'aud_tr1',
        fromWalletId: 'w_bank',
        toWalletId: 'w_cash',
        amountIdr: 1000000,
        localDate: nov20,
        note: 'ATM withdrawal',
      );

      // Monthly expense budget Rp 600.000 for Food (rollover off)
      await service.createBudget(
        id: 'b_food',
        auditId: 'aud_b1',
        categoryId: 'c_food',
        periodStart: nov1,
        periodEndInclusive: nov30,
        limitIdr: 600000,
        rolloverEnabled: false,
      );

      // Edit expense on Nov 25: Rp 450.000 -> Rp 650.000 (audited)
      clock.current = DateTime(2026, 11, 25, 14);
      await service.updateTransaction(
        transactionId: 'tx_food',
        auditId: 'aud_tx2_upd',
        walletId: 'w_cash',
        categoryId: 'c_food',
        type: FinanceTransactionType.expense,
        amountIdr: 650000,
        localDate: nov25,
        note: 'Updated grocery total',
        reason: 'Included dinner',
      );
    } finally {
      await db1.close();
    }

    // Reopen database from disk and verify exact IDR balances, cash flow, budget and audits
    final db2 = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db2.close);
    final service2 = FinanceService(db2, clock);
    final snapshot = await service2.readDashboardSnapshot(
      startInclusive: LocalDate(2026, 11, 1),
      endInclusive: LocalDate(2026, 11, 30),
    );

    final cash = snapshot.walletBalances.firstWhere(
      (w) => w.wallet.id == 'w_cash',
    );
    final bank = snapshot.walletBalances.firstWhere(
      (w) => w.wallet.id == 'w_bank',
    );
    // Cash = 300,000 - 650,000 + 1,000,000 = 650,000
    expect(cash.currentBalanceIdr, 650000);
    // Bank = 5,000,000 + 7,500,000 - 1,000,000 = 11,500,000
    expect(bank.currentBalanceIdr, 11500000);
    // Total balance = 12,150,000
    expect(snapshot.report.totalRecordedWalletBalanceIdr, 12150000);
    // Cash flow strictly excludes the Rp 1.000.000 transfer and opening balances!
    expect(snapshot.report.periodIncomeIdr, 7500000);
    expect(snapshot.report.periodExpenseIdr, 650000);
    expect(snapshot.report.periodNetCashFlowIdr, 6850000);
    expect(snapshot.report.periodTransferVolumeIdr, 1000000);
    expect(snapshot.report.periodTransferCount, 1);

    // Budget reflects the edited expense (650,000 / 600,000 -> over budget by 50,000)
    final foodBudget = snapshot.budgetStatuses.single;
    expect(foodBudget.spentIdr, 650000);
    expect(foodBudget.remainingIdr, -50000);
    expect(foodBudget.isOverBudget, isTrue);

    // Audit trail persisted across disk reopen
    expect(snapshot.auditTrail.length, 9);
    final txEdits = snapshot.auditTrail
        .where(
          (a) =>
              a.entityId == 'tx_food' &&
              a.operation == FinanceAuditOperation.update,
        )
        .toList();
    expect(txEdits.single.previousValues!['amount_idr'], 450000);
    expect(txEdits.single.updatedValues['amount_idr'], 650000);
  });
}
