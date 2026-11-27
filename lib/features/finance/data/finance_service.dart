import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../../habits/domain/habit_schedule.dart';
import '../domain/finance_models.dart';

/// Complete read-only Finance dashboard snapshot loaded inside one read transaction.
class FinanceDashboardSnapshot {
  FinanceDashboardSnapshot({
    required this.report,
    required List<WalletBalanceSummary> walletBalances,
    required List<FinanceCategory> categories,
    required List<FinanceTransaction> recentTransactions,
    required List<FinanceTransfer> recentTransfers,
    required List<BudgetPeriodStatus> budgetStatuses,
    required List<FinanceAuditRecord> auditTrail,
  }) : walletBalances = List.unmodifiable(walletBalances),
       categories = List.unmodifiable(categories),
       recentTransactions = List.unmodifiable(recentTransactions),
       recentTransfers = List.unmodifiable(recentTransfers),
       budgetStatuses = List.unmodifiable(budgetStatuses),
       auditTrail = List.unmodifiable(auditTrail);

  final FinancePeriodReport report;
  final List<WalletBalanceSummary> walletBalances;
  final List<FinanceCategory> categories;
  final List<FinanceTransaction> recentTransactions;
  final List<FinanceTransfer> recentTransfers;
  final List<BudgetPeriodStatus> budgetStatuses;
  final List<FinanceAuditRecord> auditTrail;
}

/// Transactional local-only Finance service (wallets, categories, income/expense,
/// atomic transfers, expense budgets, immutable audit snapshots and reports).
class FinanceService {
  const FinanceService(this._db, this._clock);

  final AppDatabase _db;
  final AppClock _clock;

  // --- Wallets ---

  Future<FinanceWallet> createWallet({
    required String id,
    required String auditId,
    required String name,
    required int openingBalanceIdr,
    required LocalDate openingDate,
    String? reason,
  }) => _db.transaction(() async {
    _requireId(id, 'id');
    _requireId(auditId, 'auditId');
    final trimmedName = _requireNonBlank(name, 'name');
    final now = _clock.now().toUtc();
    final ts = now.microsecondsSinceEpoch;
    final dateKey = _dateKey(openingDate);

    await _db.customStatement(
      '''
      INSERT INTO finance_wallets
        (id, name, opening_balance_idr, opening_date, is_archived, created_at_utc_us)
      VALUES (?, ?, ?, ?, 0, ?)
      ''',
      [id.trim(), trimmedName, openingBalanceIdr, dateKey, ts],
    );
    final row = await _readWalletRow(id.trim());
    await _writeAudit(
      auditId: auditId,
      entityType: FinanceAuditEntityType.wallet,
      entityId: id.trim(),
      operation: FinanceAuditOperation.create,
      previousValues: null,
      updatedValues: row.data,
      reason: reason,
      timestampUtcUs: ts,
    );
    return _mapWallet(row);
  });

  Future<FinanceWallet> updateWallet({
    required String walletId,
    required String auditId,
    required String name,
    required int openingBalanceIdr,
    required LocalDate openingDate,
    String? reason,
  }) => _db.transaction(() async {
    _requireId(walletId, 'walletId');
    _requireId(auditId, 'auditId');
    final trimmedName = _requireNonBlank(name, 'name');
    final before = await _readWalletRow(walletId.trim());
    final ts = _clock.now().toUtc().microsecondsSinceEpoch;
    await _db.customStatement(
      '''
      UPDATE finance_wallets
      SET name = ?, opening_balance_idr = ?, opening_date = ?
      WHERE id = ?
      ''',
      [trimmedName, openingBalanceIdr, _dateKey(openingDate), walletId.trim()],
    );
    final after = await _readWalletRow(walletId.trim());
    await _writeAudit(
      auditId: auditId,
      entityType: FinanceAuditEntityType.wallet,
      entityId: walletId.trim(),
      operation: FinanceAuditOperation.update,
      previousValues: before.data,
      updatedValues: after.data,
      reason: reason,
      timestampUtcUs: ts,
    );
    return _mapWallet(after);
  });

  Future<FinanceWallet> archiveWallet({
    required String walletId,
    required String auditId,
    String? reason,
  }) => _db.transaction(() async {
    _requireId(walletId, 'walletId');
    _requireId(auditId, 'auditId');
    final before = await _readWalletRow(walletId.trim());
    final ts = _clock.now().toUtc().microsecondsSinceEpoch;
    await _db.customStatement(
      'UPDATE finance_wallets SET is_archived = 1 WHERE id = ?',
      [walletId.trim()],
    );
    final after = await _readWalletRow(walletId.trim());
    await _writeAudit(
      auditId: auditId,
      entityType: FinanceAuditEntityType.wallet,
      entityId: walletId.trim(),
      operation: FinanceAuditOperation.archive,
      previousValues: before.data,
      updatedValues: after.data,
      reason: reason,
      timestampUtcUs: ts,
    );
    return _mapWallet(after);
  });

  // --- Categories ---

  Future<FinanceCategory> createCategory({
    required String id,
    required String auditId,
    required String name,
    required FinanceCategoryKind kind,
    String? reason,
  }) => _db.transaction(() async {
    _requireId(id, 'id');
    _requireId(auditId, 'auditId');
    final trimmedName = _requireNonBlank(name, 'name');
    final ts = _clock.now().toUtc().microsecondsSinceEpoch;
    await _db.customStatement(
      '''
      INSERT INTO finance_categories
        (id, name, kind, is_archived, created_at_utc_us)
      VALUES (?, ?, ?, 0, ?)
      ''',
      [id.trim(), trimmedName, kind.name, ts],
    );
    final row = await _readCategoryRow(id.trim());
    await _writeAudit(
      auditId: auditId,
      entityType: FinanceAuditEntityType.category,
      entityId: id.trim(),
      operation: FinanceAuditOperation.create,
      previousValues: null,
      updatedValues: row.data,
      reason: reason,
      timestampUtcUs: ts,
    );
    return _mapCategory(row);
  });

  // --- Income & Expense Transactions ---

  Future<FinanceTransaction> createTransaction({
    required String id,
    required String auditId,
    required String walletId,
    required String categoryId,
    required FinanceTransactionType type,
    required int amountIdr,
    required LocalDate localDate,
    String? note,
    String? reason,
  }) => _db.transaction(() async {
    _requireId(id, 'id');
    _requireId(auditId, 'auditId');
    _requireId(walletId, 'walletId');
    _requireId(categoryId, 'categoryId');
    if (amountIdr <= 0) {
      throw RangeError.value(amountIdr, 'amountIdr', 'Must be positive IDR');
    }
    final wallet = await _readWalletRow(walletId.trim());
    if (wallet.read<int>('is_archived') == 1) {
      throw StateError('Cannot create transaction on archived wallet');
    }
    final category = await _readCategoryRow(categoryId.trim());
    if (category.read<String>('kind') != type.name) {
      throw ArgumentError(
        'Category kind (${category.read<String>('kind')}) does not match transaction type (${type.name})',
      );
    }
    final ts = _clock.now().toUtc().microsecondsSinceEpoch;
    final cleanNote = _normalizeOptionalText(note);
    await _db.customStatement(
      '''
      INSERT INTO finance_transactions
        (id, wallet_id, category_id, type, amount_idr, local_date, note,
         is_deleted, created_at_utc_us, updated_at_utc_us)
      VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
      ''',
      [
        id.trim(),
        walletId.trim(),
        categoryId.trim(),
        type.name,
        amountIdr,
        _dateKey(localDate),
        cleanNote,
        ts,
        ts,
      ],
    );
    final row = await _readTransactionRow(id.trim());
    await _writeAudit(
      auditId: auditId,
      entityType: FinanceAuditEntityType.transaction,
      entityId: id.trim(),
      operation: FinanceAuditOperation.create,
      previousValues: null,
      updatedValues: row.data,
      reason: reason,
      timestampUtcUs: ts,
    );
    return _mapTransaction(row);
  });

  Future<FinanceTransaction> updateTransaction({
    required String transactionId,
    required String auditId,
    required String walletId,
    required String categoryId,
    required FinanceTransactionType type,
    required int amountIdr,
    required LocalDate localDate,
    String? note,
    String? reason,
  }) => _db.transaction(() async {
    _requireId(transactionId, 'transactionId');
    _requireId(auditId, 'auditId');
    _requireId(walletId, 'walletId');
    _requireId(categoryId, 'categoryId');
    if (amountIdr <= 0) {
      throw RangeError.value(amountIdr, 'amountIdr', 'Must be positive IDR');
    }
    final before = await _readTransactionRow(transactionId.trim());
    if (before.read<int>('is_deleted') == 1) {
      throw StateError('Cannot update a deleted transaction');
    }
    await _readWalletRow(walletId.trim());
    final category = await _readCategoryRow(categoryId.trim());
    if (category.read<String>('kind') != type.name) {
      throw ArgumentError(
        'Category kind (${category.read<String>('kind')}) does not match transaction type (${type.name})',
      );
    }
    final ts = _clock.now().toUtc().microsecondsSinceEpoch;
    final cleanNote = _normalizeOptionalText(note);
    await _db.customStatement(
      '''
      UPDATE finance_transactions
      SET wallet_id = ?, category_id = ?, type = ?, amount_idr = ?,
          local_date = ?, note = ?, updated_at_utc_us = ?
      WHERE id = ?
      ''',
      [
        walletId.trim(),
        categoryId.trim(),
        type.name,
        amountIdr,
        _dateKey(localDate),
        cleanNote,
        ts,
        transactionId.trim(),
      ],
    );
    final after = await _readTransactionRow(transactionId.trim());
    await _writeAudit(
      auditId: auditId,
      entityType: FinanceAuditEntityType.transaction,
      entityId: transactionId.trim(),
      operation: FinanceAuditOperation.update,
      previousValues: before.data,
      updatedValues: after.data,
      reason: reason,
      timestampUtcUs: ts,
    );
    return _mapTransaction(after);
  });

  Future<void> deleteTransaction({
    required String transactionId,
    required String auditId,
    String? reason,
  }) => _db.transaction(() async {
    _requireId(transactionId, 'transactionId');
    _requireId(auditId, 'auditId');
    final before = await _readTransactionRow(transactionId.trim());
    if (before.read<int>('is_deleted') == 1) {
      throw StateError('Transaction is already deleted');
    }
    final ts = _clock.now().toUtc().microsecondsSinceEpoch;
    await _db.customStatement(
      '''
      UPDATE finance_transactions
      SET is_deleted = 1, updated_at_utc_us = ?
      WHERE id = ?
      ''',
      [ts, transactionId.trim()],
    );
    final after = await _readTransactionRow(transactionId.trim());
    await _writeAudit(
      auditId: auditId,
      entityType: FinanceAuditEntityType.transaction,
      entityId: transactionId.trim(),
      operation: FinanceAuditOperation.delete,
      previousValues: before.data,
      updatedValues: after.data,
      reason: reason,
      timestampUtcUs: ts,
    );
  });

  // --- Atomic Transfers ---

  Future<FinanceTransfer> createTransfer({
    required String id,
    required String auditId,
    required String fromWalletId,
    required String toWalletId,
    required int amountIdr,
    required LocalDate localDate,
    String? note,
    String? reason,
  }) => _db.transaction(() async {
    _requireId(id, 'id');
    _requireId(auditId, 'auditId');
    _requireId(fromWalletId, 'fromWalletId');
    _requireId(toWalletId, 'toWalletId');
    if (fromWalletId.trim() == toWalletId.trim()) {
      throw ArgumentError('Transfer cannot target the same wallet');
    }
    if (amountIdr <= 0) {
      throw RangeError.value(amountIdr, 'amountIdr', 'Must be positive IDR');
    }
    final fromWallet = await _readWalletRow(fromWalletId.trim());
    final toWallet = await _readWalletRow(toWalletId.trim());
    if (fromWallet.read<int>('is_archived') == 1 ||
        toWallet.read<int>('is_archived') == 1) {
      throw StateError('Cannot transfer using an archived wallet');
    }
    final ts = _clock.now().toUtc().microsecondsSinceEpoch;
    final cleanNote = _normalizeOptionalText(note);
    await _db.customStatement(
      '''
      INSERT INTO finance_transfers
        (id, from_wallet_id, to_wallet_id, amount_idr, local_date, note,
         is_deleted, created_at_utc_us, updated_at_utc_us)
      VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
      ''',
      [
        id.trim(),
        fromWalletId.trim(),
        toWalletId.trim(),
        amountIdr,
        _dateKey(localDate),
        cleanNote,
        ts,
        ts,
      ],
    );
    final row = await _readTransferRow(id.trim());
    await _writeAudit(
      auditId: auditId,
      entityType: FinanceAuditEntityType.transfer,
      entityId: id.trim(),
      operation: FinanceAuditOperation.create,
      previousValues: null,
      updatedValues: row.data,
      reason: reason,
      timestampUtcUs: ts,
    );
    return _mapTransfer(row);
  });

  Future<FinanceTransfer> updateTransfer({
    required String transferId,
    required String auditId,
    required String fromWalletId,
    required String toWalletId,
    required int amountIdr,
    required LocalDate localDate,
    String? note,
    String? reason,
  }) => _db.transaction(() async {
    _requireId(transferId, 'transferId');
    _requireId(auditId, 'auditId');
    _requireId(fromWalletId, 'fromWalletId');
    _requireId(toWalletId, 'toWalletId');
    if (fromWalletId.trim() == toWalletId.trim()) {
      throw ArgumentError('Transfer cannot target the same wallet');
    }
    if (amountIdr <= 0) {
      throw RangeError.value(amountIdr, 'amountIdr', 'Must be positive IDR');
    }
    final before = await _readTransferRow(transferId.trim());
    if (before.read<int>('is_deleted') == 1) {
      throw StateError('Cannot update a deleted transfer');
    }
    await _readWalletRow(fromWalletId.trim());
    await _readWalletRow(toWalletId.trim());
    final ts = _clock.now().toUtc().microsecondsSinceEpoch;
    final cleanNote = _normalizeOptionalText(note);
    await _db.customStatement(
      '''
      UPDATE finance_transfers
      SET from_wallet_id = ?, to_wallet_id = ?, amount_idr = ?,
          local_date = ?, note = ?, updated_at_utc_us = ?
      WHERE id = ?
      ''',
      [
        fromWalletId.trim(),
        toWalletId.trim(),
        amountIdr,
        _dateKey(localDate),
        cleanNote,
        ts,
        transferId.trim(),
      ],
    );
    final after = await _readTransferRow(transferId.trim());
    await _writeAudit(
      auditId: auditId,
      entityType: FinanceAuditEntityType.transfer,
      entityId: transferId.trim(),
      operation: FinanceAuditOperation.update,
      previousValues: before.data,
      updatedValues: after.data,
      reason: reason,
      timestampUtcUs: ts,
    );
    return _mapTransfer(after);
  });

  Future<void> deleteTransfer({
    required String transferId,
    required String auditId,
    String? reason,
  }) => _db.transaction(() async {
    _requireId(transferId, 'transferId');
    _requireId(auditId, 'auditId');
    final before = await _readTransferRow(transferId.trim());
    if (before.read<int>('is_deleted') == 1) {
      throw StateError('Transfer is already deleted');
    }
    final ts = _clock.now().toUtc().microsecondsSinceEpoch;
    await _db.customStatement(
      '''
      UPDATE finance_transfers
      SET is_deleted = 1, updated_at_utc_us = ?
      WHERE id = ?
      ''',
      [ts, transferId.trim()],
    );
    final after = await _readTransferRow(transferId.trim());
    await _writeAudit(
      auditId: auditId,
      entityType: FinanceAuditEntityType.transfer,
      entityId: transferId.trim(),
      operation: FinanceAuditOperation.delete,
      previousValues: before.data,
      updatedValues: after.data,
      reason: reason,
      timestampUtcUs: ts,
    );
  });

  // --- Budgets (expense-only, explicit periods, optional rollover) ---

  Future<FinanceBudget> createBudget({
    required String id,
    required String auditId,
    required String categoryId,
    required LocalDate periodStart,
    required LocalDate periodEndInclusive,
    required int limitIdr,
    bool rolloverEnabled = false,
    int rolloverCarryIdr = 0,
    String? reason,
  }) => _db.transaction(() async {
    _requireId(id, 'id');
    _requireId(auditId, 'auditId');
    _requireId(categoryId, 'categoryId');
    if (periodEndInclusive.compareTo(periodStart) < 0) {
      throw ArgumentError('periodEndInclusive must not precede periodStart');
    }
    if (limitIdr <= 0) {
      throw RangeError.value(limitIdr, 'limitIdr', 'Must be positive IDR');
    }
    if (!rolloverEnabled && rolloverCarryIdr != 0) {
      throw ArgumentError(
        'rolloverCarryIdr must be 0 when rollover is disabled',
      );
    }
    final category = await _readCategoryRow(categoryId.trim());
    if (category.read<String>('kind') != 'expense') {
      throw ArgumentError('Budgets apply to expense categories only');
    }
    final ts = _clock.now().toUtc().microsecondsSinceEpoch;
    await _db.customStatement(
      '''
      INSERT INTO finance_budgets
        (id, category_id, period_start, period_end_inclusive, limit_idr,
         rollover_enabled, rollover_carry_idr, created_at_utc_us, updated_at_utc_us)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        id.trim(),
        categoryId.trim(),
        _dateKey(periodStart),
        _dateKey(periodEndInclusive),
        limitIdr,
        rolloverEnabled ? 1 : 0,
        rolloverEnabled ? rolloverCarryIdr : 0,
        ts,
        ts,
      ],
    );
    final row = await _readBudgetRow(id.trim());
    await _writeAudit(
      auditId: auditId,
      entityType: FinanceAuditEntityType.budget,
      entityId: id.trim(),
      operation: FinanceAuditOperation.create,
      previousValues: null,
      updatedValues: row.data,
      reason: reason,
      timestampUtcUs: ts,
    );
    return _mapBudget(row);
  });

  Future<FinanceBudget> updateBudget({
    required String budgetId,
    required String auditId,
    required int limitIdr,
    required bool rolloverEnabled,
    int rolloverCarryIdr = 0,
    String? reason,
  }) => _db.transaction(() async {
    _requireId(budgetId, 'budgetId');
    _requireId(auditId, 'auditId');
    if (limitIdr <= 0) {
      throw RangeError.value(limitIdr, 'limitIdr', 'Must be positive IDR');
    }
    if (!rolloverEnabled && rolloverCarryIdr != 0) {
      throw ArgumentError(
        'rolloverCarryIdr must be 0 when rollover is disabled',
      );
    }
    final before = await _readBudgetRow(budgetId.trim());
    final ts = _clock.now().toUtc().microsecondsSinceEpoch;
    await _db.customStatement(
      '''
      UPDATE finance_budgets
      SET limit_idr = ?, rollover_enabled = ?, rollover_carry_idr = ?, updated_at_utc_us = ?
      WHERE id = ?
      ''',
      [
        limitIdr,
        rolloverEnabled ? 1 : 0,
        rolloverEnabled ? rolloverCarryIdr : 0,
        ts,
        budgetId.trim(),
      ],
    );
    final after = await _readBudgetRow(budgetId.trim());
    await _writeAudit(
      auditId: auditId,
      entityType: FinanceAuditEntityType.budget,
      entityId: budgetId.trim(),
      operation: FinanceAuditOperation.update,
      previousValues: before.data,
      updatedValues: after.data,
      reason: reason,
      timestampUtcUs: ts,
    );
    return _mapBudget(after);
  });

  // --- Read-Only Queries & Reports ---

  Future<List<FinanceWallet>> readWallets({
    bool includeArchived = false,
  }) async {
    final sql = includeArchived
        ? 'SELECT * FROM finance_wallets ORDER BY created_at_utc_us ASC, id ASC'
        : 'SELECT * FROM finance_wallets WHERE is_archived = 0 ORDER BY created_at_utc_us ASC, id ASC';
    final rows = await _db.customSelect(sql).get();
    return List.unmodifiable([for (final r in rows) _mapWallet(r)]);
  }

  Future<List<FinanceCategory>> readCategories({
    bool includeArchived = false,
  }) async {
    final sql = includeArchived
        ? 'SELECT * FROM finance_categories ORDER BY kind ASC, name ASC, id ASC'
        : 'SELECT * FROM finance_categories WHERE is_archived = 0 ORDER BY kind ASC, name ASC, id ASC';
    final rows = await _db.customSelect(sql).get();
    return List.unmodifiable([for (final r in rows) _mapCategory(r)]);
  }

  Future<List<FinanceTransaction>> readTransactions({
    bool includeDeleted = false,
  }) async {
    final sql = includeDeleted
        ? 'SELECT * FROM finance_transactions ORDER BY local_date DESC, created_at_utc_us DESC, id DESC'
        : 'SELECT * FROM finance_transactions WHERE is_deleted = 0 ORDER BY local_date DESC, created_at_utc_us DESC, id DESC';
    final rows = await _db.customSelect(sql).get();
    return List.unmodifiable([for (final r in rows) _mapTransaction(r)]);
  }

  Future<List<FinanceTransfer>> readTransfers({
    bool includeDeleted = false,
  }) async {
    final sql = includeDeleted
        ? 'SELECT * FROM finance_transfers ORDER BY local_date DESC, created_at_utc_us DESC, id DESC'
        : 'SELECT * FROM finance_transfers WHERE is_deleted = 0 ORDER BY local_date DESC, created_at_utc_us DESC, id DESC';
    final rows = await _db.customSelect(sql).get();
    return List.unmodifiable([for (final r in rows) _mapTransfer(r)]);
  }

  Future<List<FinanceBudget>> readBudgets() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM finance_budgets ORDER BY period_start DESC, id ASC',
        )
        .get();
    return List.unmodifiable([for (final r in rows) _mapBudget(r)]);
  }

  Future<List<FinanceAuditRecord>> readAuditTrail({
    FinanceAuditEntityType? entityType,
    String? entityId,
  }) async {
    final where = <String>[];
    final vars = <Variable<Object>>[];
    if (entityType != null) {
      where.add('entity_type = ?');
      vars.add(Variable<String>(entityType.name));
    }
    if (entityId != null) {
      where.add('entity_id = ?');
      vars.add(Variable<String>(entityId));
    }
    final whereClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final rows = await _db
        .customSelect(
          'SELECT * FROM finance_audit $whereClause ORDER BY occurred_at_utc_us ASC, id ASC',
          variables: vars,
        )
        .get();
    return List.unmodifiable([
      for (final row in rows)
        FinanceAuditRecord(
          id: row.read<String>('id'),
          entityType: FinanceAuditEntityType.values.byName(
            row.read<String>('entity_type'),
          ),
          entityId: row.read<String>('entity_id'),
          operation: FinanceAuditOperation.values.byName(
            row.read<String>('operation'),
          ),
          previousValues: _decodeJson(
            row.readNullable<String>('previous_values'),
          ),
          updatedValues: _decodeJson(row.read<String>('updated_values'))!,
          reason: row.readNullable<String>('reason'),
          occurredAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            row.read<int>('occurred_at_utc_us'),
            isUtc: true,
          ),
        ),
    ]);
  }

  Future<FinanceDashboardSnapshot> readDashboardSnapshot({
    required LocalDate startInclusive,
    required LocalDate endInclusive,
    LocalDate? balanceAsOfInclusive,
  }) => _db.transaction(() async {
    final wallets = await readWallets(includeArchived: true);
    final categories = await readCategories(includeArchived: true);
    final transactions = await readTransactions(includeDeleted: false);
    final transfers = await readTransfers(includeDeleted: false);
    final budgets = await readBudgets();
    final audits = await readAuditTrail();

    final walletBalances = [
      for (final w in wallets)
        FinanceBalanceCalculator.calculateWalletBalance(
          wallet: w,
          transactions: transactions,
          transfers: transfers,
          asOfInclusive: balanceAsOfInclusive,
        ),
    ];

    final categoryById = {for (final c in categories) c.id: c};
    final budgetStatuses = [
      for (final b in budgets)
        FinanceBudgetCalculator.evaluate(
          budget: b,
          categoryName: categoryById[b.categoryId]?.name ?? b.categoryId,
          transactions: transactions,
        ),
    ];

    final report = FinanceReportCalculator.buildReport(
      startInclusive: startInclusive,
      endInclusive: endInclusive,
      walletBalances: walletBalances,
      categories: categories,
      transactions: transactions,
      transfers: transfers,
    );

    return FinanceDashboardSnapshot(
      report: report,
      walletBalances: walletBalances,
      categories: categories,
      recentTransactions: transactions,
      recentTransfers: transfers,
      budgetStatuses: budgetStatuses,
      auditTrail: audits,
    );
  });

  // --- Internal helpers ---

  Future<QueryRow> _readWalletRow(String id) async {
    final row = await _db
        .customSelect(
          'SELECT * FROM finance_wallets WHERE id = ?',
          variables: [Variable<String>(id)],
        )
        .getSingleOrNull();
    if (row == null) throw StateError('Wallet does not exist: $id');
    return row;
  }

  Future<QueryRow> _readCategoryRow(String id) async {
    final row = await _db
        .customSelect(
          'SELECT * FROM finance_categories WHERE id = ?',
          variables: [Variable<String>(id)],
        )
        .getSingleOrNull();
    if (row == null) throw StateError('Category does not exist: $id');
    return row;
  }

  Future<QueryRow> _readTransactionRow(String id) async {
    final row = await _db
        .customSelect(
          'SELECT * FROM finance_transactions WHERE id = ?',
          variables: [Variable<String>(id)],
        )
        .getSingleOrNull();
    if (row == null) throw StateError('Transaction does not exist: $id');
    return row;
  }

  Future<QueryRow> _readTransferRow(String id) async {
    final row = await _db
        .customSelect(
          'SELECT * FROM finance_transfers WHERE id = ?',
          variables: [Variable<String>(id)],
        )
        .getSingleOrNull();
    if (row == null) throw StateError('Transfer does not exist: $id');
    return row;
  }

  Future<QueryRow> _readBudgetRow(String id) async {
    final row = await _db
        .customSelect(
          'SELECT * FROM finance_budgets WHERE id = ?',
          variables: [Variable<String>(id)],
        )
        .getSingleOrNull();
    if (row == null) throw StateError('Budget does not exist: $id');
    return row;
  }

  Future<void> _writeAudit({
    required String auditId,
    required FinanceAuditEntityType entityType,
    required String entityId,
    required FinanceAuditOperation operation,
    required Map<String, Object?>? previousValues,
    required Map<String, Object?> updatedValues,
    required String? reason,
    required int timestampUtcUs,
  }) => _db.customStatement(
    '''
    INSERT INTO finance_audit
      (id, entity_type, entity_id, operation, previous_values, updated_values,
       reason, occurred_at_utc_us)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    [
      auditId.trim(),
      entityType.name,
      entityId,
      operation.name,
      previousValues == null ? null : jsonEncode(previousValues),
      jsonEncode(updatedValues),
      _normalizeOptionalText(reason),
      timestampUtcUs,
    ],
  );
}

FinanceWallet _mapWallet(QueryRow r) => FinanceWallet(
  id: r.read<String>('id'),
  name: r.read<String>('name'),
  openingBalanceIdr: r.read<int>('opening_balance_idr'),
  openingDate: _parseDate(r.read<String>('opening_date')),
  isArchived: r.read<int>('is_archived') == 1,
  createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
    r.read<int>('created_at_utc_us'),
    isUtc: true,
  ),
);

FinanceCategory _mapCategory(QueryRow r) => FinanceCategory(
  id: r.read<String>('id'),
  name: r.read<String>('name'),
  kind: FinanceCategoryKind.values.byName(r.read<String>('kind')),
  isArchived: r.read<int>('is_archived') == 1,
  createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
    r.read<int>('created_at_utc_us'),
    isUtc: true,
  ),
);

FinanceTransaction _mapTransaction(QueryRow r) => FinanceTransaction(
  id: r.read<String>('id'),
  walletId: r.read<String>('wallet_id'),
  categoryId: r.read<String>('category_id'),
  type: FinanceTransactionType.values.byName(r.read<String>('type')),
  amountIdr: r.read<int>('amount_idr'),
  localDate: _parseDate(r.read<String>('local_date')),
  note: r.readNullable<String>('note'),
  isDeleted: r.read<int>('is_deleted') == 1,
  createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
    r.read<int>('created_at_utc_us'),
    isUtc: true,
  ),
  updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
    r.read<int>('updated_at_utc_us'),
    isUtc: true,
  ),
);

FinanceTransfer _mapTransfer(QueryRow r) => FinanceTransfer(
  id: r.read<String>('id'),
  fromWalletId: r.read<String>('from_wallet_id'),
  toWalletId: r.read<String>('to_wallet_id'),
  amountIdr: r.read<int>('amount_idr'),
  localDate: _parseDate(r.read<String>('local_date')),
  note: r.readNullable<String>('note'),
  isDeleted: r.read<int>('is_deleted') == 1,
  createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
    r.read<int>('created_at_utc_us'),
    isUtc: true,
  ),
  updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
    r.read<int>('updated_at_utc_us'),
    isUtc: true,
  ),
);

FinanceBudget _mapBudget(QueryRow r) => FinanceBudget(
  id: r.read<String>('id'),
  categoryId: r.read<String>('category_id'),
  periodStart: _parseDate(r.read<String>('period_start')),
  periodEndInclusive: _parseDate(r.read<String>('period_end_inclusive')),
  limitIdr: r.read<int>('limit_idr'),
  rolloverEnabled: r.read<int>('rollover_enabled') == 1,
  rolloverCarryIdr: r.read<int>('rollover_carry_idr'),
  createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
    r.read<int>('created_at_utc_us'),
    isUtc: true,
  ),
  updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
    r.read<int>('updated_at_utc_us'),
    isUtc: true,
  ),
);

void _requireId(String value, String field) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, field, 'Must not be blank');
  }
}

String _requireNonBlank(String value, String field) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(value, field, 'Must not be blank');
  }
  return trimmed;
}

String? _normalizeOptionalText(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

LocalDate _parseDate(String value) => LocalDate(
  int.parse(value.substring(0, 4)),
  int.parse(value.substring(5, 7)),
  int.parse(value.substring(8, 10)),
);

Map<String, Object?>? _decodeJson(String? raw) {
  if (raw == null) return null;
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  return Map<String, Object?>.unmodifiable(decoded);
}
