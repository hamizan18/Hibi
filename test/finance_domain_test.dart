import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/features/finance/domain/finance_models.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';

void main() {
  test('formatIdr formats positive, zero, negative and int64 boundary rupiah values', () {
    expect(formatIdr(0), 'Rp 0');
    expect(formatIdr(500), 'Rp 500');
    expect(formatIdr(150000), 'Rp 150.000');
    expect(formatIdr(12500000), 'Rp 12.500.000');
    expect(formatIdr(-75000), '-Rp 75.000');
  });

  test(
    'checkedAddIdr and checkedSubIdr reject signed 64-bit overflow/underflow',
    () {
      const maxInt = 9223372036854775807;
      const minInt = -9223372036854775807 - 1;
      expect(() => checkedAddIdr(maxInt, 1), throwsRangeError);
      expect(() => checkedAddIdr(minInt, -1), throwsRangeError);
      expect(() => checkedSubIdr(0, minInt), throwsRangeError);
    },
  );

  test('FinanceBalanceCalculator and FinanceReportCalculator distinguish cash flow from wallet balance and exclude transfers from income/expense', () {
    final now = DateTime.utc(2026, 11, 26);
    final nov1 = LocalDate(2026, 11, 1);
    final nov10 = LocalDate(2026, 11, 10);
    final nov26 = LocalDate(2026, 11, 26);

    final cash = FinanceWallet(
      id: 'w_cash',
      name: 'Cash',
      openingBalanceIdr: 500000,
      openingDate: nov1,
      createdAtUtc: now,
    );
    final bank = FinanceWallet(
      id: 'w_bank',
      name: 'Bank',
      openingBalanceIdr: 1000000,
      openingDate: nov1,
      createdAtUtc: now,
    );
    final salaryCat = FinanceCategory(
      id: 'c_inc',
      name: 'Salary',
      kind: FinanceCategoryKind.income,
      createdAtUtc: now,
    );
    final foodCat = FinanceCategory(
      id: 'c_exp',
      name: 'Food',
      kind: FinanceCategoryKind.expense,
      createdAtUtc: now,
    );

    final transactions = [
      FinanceTransaction(
        id: 't1',
        walletId: 'w_bank',
        categoryId: 'c_inc',
        type: FinanceTransactionType.income,
        amountIdr: 3000000,
        localDate: nov10,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
      FinanceTransaction(
        id: 't2',
        walletId: 'w_cash',
        categoryId: 'c_exp',
        type: FinanceTransactionType.expense,
        amountIdr: 250000,
        localDate: nov10,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
      // Deleted transaction is excluded
      FinanceTransaction(
        id: 't3',
        walletId: 'w_cash',
        categoryId: 'c_exp',
        type: FinanceTransactionType.expense,
        amountIdr: 999999,
        localDate: nov10,
        isDeleted: true,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
    ];

    final transfers = [
      FinanceTransfer(
        id: 'tr1',
        fromWalletId: 'w_bank',
        toWalletId: 'w_cash',
        amountIdr: 400000,
        localDate: nov10,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
    ];

    final cashBal = FinanceBalanceCalculator.calculateWalletBalance(
      wallet: cash,
      transactions: transactions,
      transfers: transfers,
    );
    final bankBal = FinanceBalanceCalculator.calculateWalletBalance(
      wallet: bank,
      transactions: transactions,
      transfers: transfers,
    );
    // Cash = 500,000 - 250,000 + 400,000 = 650,000
    expect(cashBal.currentBalanceIdr, 650000);
    // Bank = 1,000,000 + 3,000,000 - 400,000 = 3,600,000
    expect(bankBal.currentBalanceIdr, 3600000);

    final report = FinanceReportCalculator.buildReport(
      startInclusive: nov1,
      endInclusive: nov26,
      walletBalances: [cashBal, bankBal],
      categories: [salaryCat, foodCat],
      transactions: transactions,
      transfers: transfers,
    );
    // Transfers are strictly excluded from income/expense cash flow!
    expect(report.periodIncomeIdr, 3000000);
    expect(report.periodExpenseIdr, 250000);
    expect(report.periodNetCashFlowIdr, 2750000);
    expect(report.periodTransferVolumeIdr, 400000);
    expect(report.periodTransferCount, 1);
    // Total wallet balance = 650,000 + 3,600,000 = 4,250,000 (includes opening balances!)
    expect(report.totalRecordedWalletBalanceIdr, 4250000);
  });

  test('FinanceBudgetCalculator applies to explicit period expenses only and respects rollover toggle', () {
    final now = DateTime.utc(2026, 11, 26);
    final nov1 = LocalDate(2026, 11, 1);
    final nov30 = LocalDate(2026, 11, 30);

    final noRollover = FinanceBudget(
      id: 'b1',
      categoryId: 'c_food',
      periodStart: nov1,
      periodEndInclusive: nov30,
      limitIdr: 500000,
      rolloverEnabled: false,
      rolloverCarryIdr: 0,
      createdAtUtc: now,
      updatedAtUtc: now,
    );
    final withRollover = FinanceBudget(
      id: 'b2',
      categoryId: 'c_food',
      periodStart: nov1,
      periodEndInclusive: nov30,
      limitIdr: 500000,
      rolloverEnabled: true,
      rolloverCarryIdr: 150000,
      createdAtUtc: now,
      updatedAtUtc: now,
    );

    final txs = [
      FinanceTransaction(
        id: 'tx_in_period',
        walletId: 'w1',
        categoryId: 'c_food',
        type: FinanceTransactionType.expense,
        amountIdr: 550000,
        localDate: LocalDate(2026, 11, 15),
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
      // Out of period -> ignored
      FinanceTransaction(
        id: 'tx_out_period',
        walletId: 'w1',
        categoryId: 'c_food',
        type: FinanceTransactionType.expense,
        amountIdr: 200000,
        localDate: LocalDate(2026, 12, 1),
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
      // Income -> ignored even if same category ID passed artificially
      FinanceTransaction(
        id: 'tx_income',
        walletId: 'w1',
        categoryId: 'c_food',
        type: FinanceTransactionType.income,
        amountIdr: 900000,
        localDate: LocalDate(2026, 11, 15),
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
    ];

    final statusNoRollover = FinanceBudgetCalculator.evaluate(
      budget: noRollover,
      categoryName: 'Food',
      transactions: txs,
    );
    expect(statusNoRollover.spentIdr, 550000);
    expect(statusNoRollover.effectiveLimitIdr, 500000);
    expect(statusNoRollover.remainingIdr, -50000);
    expect(statusNoRollover.isOverBudget, isTrue);

    final statusWithRollover = FinanceBudgetCalculator.evaluate(
      budget: withRollover,
      categoryName: 'Food',
      transactions: txs,
    );
    expect(statusWithRollover.effectiveLimitIdr, 650000);
    expect(statusWithRollover.remainingIdr, 100000);
    expect(statusWithRollover.isOverBudget, isFalse);

    expect(
      () => FinanceBudget(
        id: 'b_bad',
        categoryId: 'c_food',
        periodStart: nov1,
        periodEndInclusive: nov30,
        limitIdr: 500000,
        rolloverEnabled: false,
        rolloverCarryIdr: 10000,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
      throwsArgumentError,
    );
  });
}
