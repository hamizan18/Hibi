import '../../habits/domain/habit_schedule.dart';

const int _int64Max = 9223372036854775807;
const int _int64Min = -9223372036854775807 - 1;

/// Exact integer rupiah addition with signed 64-bit overflow protection.
int checkedAddIdr(int a, int b) {
  if (b > 0 && a > _int64Max - b) {
    throw RangeError('Integer IDR overflow: $a + $b');
  }
  if (b < 0 && a < _int64Min - b) {
    throw RangeError('Integer IDR underflow: $a + $b');
  }
  return a + b;
}

/// Exact integer rupiah subtraction with signed 64-bit overflow protection.
int checkedSubIdr(int a, int b) {
  if (b == _int64Min) {
    if (a >= 0) throw RangeError('Integer IDR overflow: $a - $b');
    return a - b;
  }
  return checkedAddIdr(a, -b);
}

/// Formats an integer IDR amount using Indonesian thousand separators without
/// converting through floating-point numbers.
String formatIdr(int amountIdr) {
  final negative = amountIdr < 0;
  final digits = negative
      ? (amountIdr == _int64Min
            ? '9223372036854775808'
            : (-amountIdr).toString())
      : amountIdr.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final remaining = digits.length - i;
    if (i > 0 && remaining % 3 == 0) {
      buffer.write('.');
    }
    buffer.write(digits[i]);
  }
  return '${negative ? '-' : ''}Rp $buffer';
}

enum FinanceCategoryKind { income, expense }

enum FinanceTransactionType { income, expense }

enum FinanceAuditEntityType { wallet, category, transaction, transfer, budget }

enum FinanceAuditOperation { create, update, archive, delete }

class FinanceWallet {
  FinanceWallet({
    required String id,
    required String name,
    required this.openingBalanceIdr,
    required this.openingDate,
    this.isArchived = false,
    required this.createdAtUtc,
  }) : id = id.trim(),
       name = name.trim() {
    if (this.id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'Must not be blank');
    }
    if (this.name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Must not be blank');
    }
  }

  final String id;
  final String name;
  final int openingBalanceIdr;
  final LocalDate openingDate;
  final bool isArchived;
  final DateTime createdAtUtc;
}

class FinanceCategory {
  FinanceCategory({
    required String id,
    required String name,
    required this.kind,
    this.isArchived = false,
    required this.createdAtUtc,
  }) : id = id.trim(),
       name = name.trim() {
    if (this.id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'Must not be blank');
    }
    if (this.name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Must not be blank');
    }
  }

  final String id;
  final String name;
  final FinanceCategoryKind kind;
  final bool isArchived;
  final DateTime createdAtUtc;
}

class FinanceTransaction {
  FinanceTransaction({
    required String id,
    required String walletId,
    required String categoryId,
    required this.type,
    required this.amountIdr,
    required this.localDate,
    this.note,
    this.isDeleted = false,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) : id = id.trim(),
       walletId = walletId.trim(),
       categoryId = categoryId.trim() {
    if (this.id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'Must not be blank');
    }
    if (this.walletId.isEmpty) {
      throw ArgumentError.value(walletId, 'walletId', 'Must not be blank');
    }
    if (this.categoryId.isEmpty) {
      throw ArgumentError.value(categoryId, 'categoryId', 'Must not be blank');
    }
    if (amountIdr <= 0) {
      throw RangeError.value(
        amountIdr,
        'amountIdr',
        'Must be positive integer IDR',
      );
    }
  }

  final String id;
  final String walletId;
  final String categoryId;
  final FinanceTransactionType type;
  final int amountIdr;
  final LocalDate localDate;
  final String? note;
  final bool isDeleted;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
}

class FinanceTransfer {
  FinanceTransfer({
    required String id,
    required String fromWalletId,
    required String toWalletId,
    required this.amountIdr,
    required this.localDate,
    this.note,
    this.isDeleted = false,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) : id = id.trim(),
       fromWalletId = fromWalletId.trim(),
       toWalletId = toWalletId.trim() {
    if (this.id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'Must not be blank');
    }
    if (this.fromWalletId.isEmpty) {
      throw ArgumentError.value(
        fromWalletId,
        'fromWalletId',
        'Must not be blank',
      );
    }
    if (this.toWalletId.isEmpty) {
      throw ArgumentError.value(toWalletId, 'toWalletId', 'Must not be blank');
    }
    if (this.fromWalletId == this.toWalletId) {
      throw ArgumentError('Transfer cannot target the same wallet');
    }
    if (amountIdr <= 0) {
      throw RangeError.value(
        amountIdr,
        'amountIdr',
        'Must be positive integer IDR',
      );
    }
  }

  final String id;
  final String fromWalletId;
  final String toWalletId;
  final int amountIdr;
  final LocalDate localDate;
  final String? note;
  final bool isDeleted;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
}

class FinanceBudget {
  FinanceBudget({
    required String id,
    required String categoryId,
    required this.periodStart,
    required this.periodEndInclusive,
    required this.limitIdr,
    this.rolloverEnabled = false,
    this.rolloverCarryIdr = 0,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) : id = id.trim(),
       categoryId = categoryId.trim() {
    if (this.id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'Must not be blank');
    }
    if (this.categoryId.isEmpty) {
      throw ArgumentError.value(categoryId, 'categoryId', 'Must not be blank');
    }
    if (periodEndInclusive.compareTo(periodStart) < 0) {
      throw ArgumentError('periodEndInclusive must not precede periodStart');
    }
    if (limitIdr <= 0) {
      throw RangeError.value(
        limitIdr,
        'limitIdr',
        'Must be positive integer IDR',
      );
    }
    if (!rolloverEnabled && rolloverCarryIdr != 0) {
      throw ArgumentError(
        'rolloverCarryIdr must be 0 when rollover is disabled',
      );
    }
  }

  final String id;
  final String categoryId;
  final LocalDate periodStart;
  final LocalDate periodEndInclusive;
  final int limitIdr;
  final bool rolloverEnabled;
  final int rolloverCarryIdr;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;

  int get effectiveLimitIdr =>
      rolloverEnabled ? checkedAddIdr(limitIdr, rolloverCarryIdr) : limitIdr;
}

class FinanceAuditRecord {
  const FinanceAuditRecord({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.previousValues,
    required this.updatedValues,
    required this.reason,
    required this.occurredAtUtc,
  });

  final String id;
  final FinanceAuditEntityType entityType;
  final String entityId;
  final FinanceAuditOperation operation;
  final Map<String, Object?>? previousValues;
  final Map<String, Object?> updatedValues;
  final String? reason;
  final DateTime occurredAtUtc;
}

/// Deterministic wallet balance breakdown per BUSINESS_RULES.md:
/// Balance = opening + income - expense + incoming transfers - outgoing transfers.
class WalletBalanceSummary {
  const WalletBalanceSummary({
    required this.wallet,
    required this.openingBalanceIdr,
    required this.totalIncomeIdr,
    required this.totalExpenseIdr,
    required this.incomingTransfersIdr,
    required this.outgoingTransfersIdr,
    required this.currentBalanceIdr,
  });

  final FinanceWallet wallet;
  final int openingBalanceIdr;
  final int totalIncomeIdr;
  final int totalExpenseIdr;
  final int incomingTransfersIdr;
  final int outgoingTransfersIdr;
  final int currentBalanceIdr;
}

/// Pure calculator for wallet balances using exact integer rupiah arithmetic.
class FinanceBalanceCalculator {
  const FinanceBalanceCalculator._();

  static WalletBalanceSummary calculateWalletBalance({
    required FinanceWallet wallet,
    required Iterable<FinanceTransaction> transactions,
    required Iterable<FinanceTransfer> transfers,
    LocalDate? asOfInclusive,
  }) {
    var income = 0;
    var expense = 0;
    for (final tx in transactions) {
      if (tx.isDeleted || tx.walletId != wallet.id) continue;
      if (asOfInclusive != null && tx.localDate.compareTo(asOfInclusive) > 0) {
        continue;
      }
      if (tx.type == FinanceTransactionType.income) {
        income = checkedAddIdr(income, tx.amountIdr);
      } else {
        expense = checkedAddIdr(expense, tx.amountIdr);
      }
    }

    var incoming = 0;
    var outgoing = 0;
    for (final tr in transfers) {
      if (tr.isDeleted) continue;
      if (asOfInclusive != null && tr.localDate.compareTo(asOfInclusive) > 0) {
        continue;
      }
      if (tr.toWalletId == wallet.id) {
        incoming = checkedAddIdr(incoming, tr.amountIdr);
      }
      if (tr.fromWalletId == wallet.id) {
        outgoing = checkedAddIdr(outgoing, tr.amountIdr);
      }
    }

    var balance = wallet.openingBalanceIdr;
    balance = checkedAddIdr(balance, income);
    balance = checkedSubIdr(balance, expense);
    balance = checkedAddIdr(balance, incoming);
    balance = checkedSubIdr(balance, outgoing);

    return WalletBalanceSummary(
      wallet: wallet,
      openingBalanceIdr: wallet.openingBalanceIdr,
      totalIncomeIdr: income,
      totalExpenseIdr: expense,
      incomingTransfersIdr: incoming,
      outgoingTransfersIdr: outgoing,
      currentBalanceIdr: balance,
    );
  }
}

/// Deterministic status for an expense-only budget over an explicit period.
class BudgetPeriodStatus {
  const BudgetPeriodStatus({
    required this.budget,
    required this.categoryName,
    required this.effectiveLimitIdr,
    required this.spentIdr,
    required this.remainingIdr,
    required this.expenseTransactionCount,
  });

  final FinanceBudget budget;
  final String categoryName;
  final int effectiveLimitIdr;
  final int spentIdr;
  final int remainingIdr;
  final int expenseTransactionCount;

  bool get isOverBudget => spentIdr > effectiveLimitIdr;
}

/// Pure calculator for expense-only budgets. Transfers and income are never counted.
class FinanceBudgetCalculator {
  const FinanceBudgetCalculator._();

  static BudgetPeriodStatus evaluate({
    required FinanceBudget budget,
    required String categoryName,
    required Iterable<FinanceTransaction> transactions,
  }) {
    var spent = 0;
    var count = 0;
    for (final tx in transactions) {
      if (tx.isDeleted) continue;
      if (tx.type != FinanceTransactionType.expense) continue;
      if (tx.categoryId != budget.categoryId) continue;
      if (tx.localDate.compareTo(budget.periodStart) < 0 ||
          tx.localDate.compareTo(budget.periodEndInclusive) > 0) {
        continue;
      }
      spent = checkedAddIdr(spent, tx.amountIdr);
      count += 1;
    }
    final effectiveLimit = budget.effectiveLimitIdr;
    final remaining = checkedSubIdr(effectiveLimit, spent);
    return BudgetPeriodStatus(
      budget: budget,
      categoryName: categoryName,
      effectiveLimitIdr: effectiveLimit,
      spentIdr: spent,
      remainingIdr: remaining,
      expenseTransactionCount: count,
    );
  }
}

class CategoryCashFlowRow {
  const CategoryCashFlowRow({
    required this.categoryId,
    required this.categoryName,
    required this.kind,
    required this.totalIdr,
    required this.transactionCount,
  });

  final String categoryId;
  final String categoryName;
  final FinanceCategoryKind kind;
  final int totalIdr;
  final int transactionCount;
}

/// Period finance report explicitly distinguishing cash flow (income - expense,
/// excluding transfers and opening balances) from total recorded wallet balances.
class FinancePeriodReport {
  FinancePeriodReport({
    required this.startInclusive,
    required this.endInclusive,
    required this.periodIncomeIdr,
    required this.periodExpenseIdr,
    required this.periodNetCashFlowIdr,
    required this.periodTransferVolumeIdr,
    required this.periodTransferCount,
    required this.totalRecordedWalletBalanceIdr,
    required this.activeWalletCount,
    required this.archivedWalletCount,
    required List<CategoryCashFlowRow> incomeByCategory,
    required List<CategoryCashFlowRow> expenseByCategory,
  }) : incomeByCategory = List.unmodifiable(incomeByCategory),
       expenseByCategory = List.unmodifiable(expenseByCategory);

  static const String recordedScopeNotice =
      'Recorded accounts only: cash flow counts income minus expense and excludes transfers and opening balances; total balance reflects recorded local wallets only.';

  final LocalDate startInclusive;
  final LocalDate endInclusive;
  final int periodIncomeIdr;
  final int periodExpenseIdr;
  final int periodNetCashFlowIdr;
  final int periodTransferVolumeIdr;
  final int periodTransferCount;
  final int totalRecordedWalletBalanceIdr;
  final int activeWalletCount;
  final int archivedWalletCount;
  final List<CategoryCashFlowRow> incomeByCategory;
  final List<CategoryCashFlowRow> expenseByCategory;

  String get scopeNotice => recordedScopeNotice;
}

/// Pure calculator for period cash flow vs wallet balance reports.
class FinanceReportCalculator {
  const FinanceReportCalculator._();

  static FinancePeriodReport buildReport({
    required LocalDate startInclusive,
    required LocalDate endInclusive,
    required Iterable<WalletBalanceSummary> walletBalances,
    required Iterable<FinanceCategory> categories,
    required Iterable<FinanceTransaction> transactions,
    required Iterable<FinanceTransfer> transfers,
  }) {
    if (endInclusive.compareTo(startInclusive) < 0) {
      throw ArgumentError('endInclusive must not precede startInclusive');
    }

    final categoryById = {for (final c in categories) c.id: c};
    var periodIncome = 0;
    var periodExpense = 0;
    final incomeTotals = <String, ({int sum, int count})>{};
    final expenseTotals = <String, ({int sum, int count})>{};

    for (final tx in transactions) {
      if (tx.isDeleted) continue;
      if (tx.localDate.compareTo(startInclusive) < 0 ||
          tx.localDate.compareTo(endInclusive) > 0) {
        continue;
      }
      if (tx.type == FinanceTransactionType.income) {
        periodIncome = checkedAddIdr(periodIncome, tx.amountIdr);
        final prev = incomeTotals[tx.categoryId] ?? (sum: 0, count: 0);
        incomeTotals[tx.categoryId] = (
          sum: checkedAddIdr(prev.sum, tx.amountIdr),
          count: prev.count + 1,
        );
      } else {
        periodExpense = checkedAddIdr(periodExpense, tx.amountIdr);
        final prev = expenseTotals[tx.categoryId] ?? (sum: 0, count: 0);
        expenseTotals[tx.categoryId] = (
          sum: checkedAddIdr(prev.sum, tx.amountIdr),
          count: prev.count + 1,
        );
      }
    }

    var transferVolume = 0;
    var transferCount = 0;
    for (final tr in transfers) {
      if (tr.isDeleted) continue;
      if (tr.localDate.compareTo(startInclusive) < 0 ||
          tr.localDate.compareTo(endInclusive) > 0) {
        continue;
      }
      transferVolume = checkedAddIdr(transferVolume, tr.amountIdr);
      transferCount += 1;
    }

    var totalBalance = 0;
    var activeWallets = 0;
    var archivedWallets = 0;
    for (final wb in walletBalances) {
      if (wb.wallet.isArchived) {
        archivedWallets += 1;
      } else {
        activeWallets += 1;
        totalBalance = checkedAddIdr(totalBalance, wb.currentBalanceIdr);
      }
    }

    final incomeRows = [
      for (final e in incomeTotals.entries)
        CategoryCashFlowRow(
          categoryId: e.key,
          categoryName: categoryById[e.key]?.name ?? e.key,
          kind: FinanceCategoryKind.income,
          totalIdr: e.value.sum,
          transactionCount: e.value.count,
        ),
    ]..sort((a, b) => b.totalIdr.compareTo(a.totalIdr));

    final expenseRows = [
      for (final e in expenseTotals.entries)
        CategoryCashFlowRow(
          categoryId: e.key,
          categoryName: categoryById[e.key]?.name ?? e.key,
          kind: FinanceCategoryKind.expense,
          totalIdr: e.value.sum,
          transactionCount: e.value.count,
        ),
    ]..sort((a, b) => b.totalIdr.compareTo(a.totalIdr));

    return FinancePeriodReport(
      startInclusive: startInclusive,
      endInclusive: endInclusive,
      periodIncomeIdr: periodIncome,
      periodExpenseIdr: periodExpense,
      periodNetCashFlowIdr: checkedSubIdr(periodIncome, periodExpense),
      periodTransferVolumeIdr: transferVolume,
      periodTransferCount: transferCount,
      totalRecordedWalletBalanceIdr: totalBalance,
      activeWalletCount: activeWallets,
      archivedWalletCount: archivedWallets,
      incomeByCategory: incomeRows,
      expenseByCategory: expenseRows,
    );
  }
}
