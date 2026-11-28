import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../habits/domain/habit_schedule.dart';
import '../application/finance_providers.dart';
import '../data/finance_service.dart';
import '../domain/finance_models.dart';

/// Offline integer-IDR Finance view for Milestone 3.
/// Supports wallets with opening balances, income/expense categories,
/// transactions with auditable edits, atomic wallet transfers excluded from
/// cash flow, expense-only budgets, period reports and immutable audit inspection.
class FinanceView extends ConsumerStatefulWidget {
  const FinanceView({super.key, required this.asOfDate});

  final LocalDate asOfDate;

  @override
  ConsumerState<FinanceView> createState() => _FinanceViewState();
}

class _FinanceViewState extends ConsumerState<FinanceView> {
  final _random = Random.secure();
  late Future<FinanceDashboardSnapshot> _snapshotFuture;
  String? _error;
  bool _busy = false;

  // Inline form expansion flags
  bool _showWalletForm = false;
  bool _showCategoryForm = false;
  bool _showTxForm = false;
  bool _showTransferForm = false;
  bool _showBudgetForm = false;

  // Controllers
  final _walletName = TextEditingController();
  final _walletOpening = TextEditingController(text: '0');
  final _categoryName = TextEditingController();
  FinanceCategoryKind _categoryKind = FinanceCategoryKind.expense;

  FinanceTransactionType _txType = FinanceTransactionType.expense;
  String? _txWalletId;
  String? _txCategoryId;
  final _txAmount = TextEditingController();
  final _txNote = TextEditingController();

  String? _transferFromId;
  String? _transferToId;
  final _transferAmount = TextEditingController();
  final _transferNote = TextEditingController();

  String? _budgetCategoryId;
  final _budgetLimit = TextEditingController();
  bool _budgetRollover = false;

  String _id() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  String _formatDate(LocalDate d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  (LocalDate, LocalDate) _currentMonthRange() {
    final d = widget.asOfDate;
    return (LocalDate(d.year, d.month, 1), d);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant FinanceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asOfDate.compareTo(widget.asOfDate) != 0) {
      _load();
    }
  }

  @override
  void dispose() {
    for (final c in [
      _walletName,
      _walletOpening,
      _categoryName,
      _txAmount,
      _txNote,
      _transferAmount,
      _transferNote,
      _budgetLimit,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _load() {
    final (start, end) = _currentMonthRange();
    _snapshotFuture = ref
        .read(financeServiceProvider)
        .readDashboardSnapshot(
          startInclusive: start,
          endInclusive: end,
          balanceAsOfInclusive: end,
        );
  }

  void _reload() => setState(_load);

  int? _parseSignedIdr(String text) {
    final trimmed = text.trim().replaceAll('.', '');
    if (!RegExp(r'^-?[0-9]+$').hasMatch(trimmed)) return null;
    return int.tryParse(trimmed);
  }

  int? _parsePositiveIdr(String text) {
    final value = _parseSignedIdr(text);
    return value != null && value > 0 ? value : null;
  }

  Future<void> _submitWallet() async {
    final name = _walletName.text.trim();
    final opening = _parseSignedIdr(_walletOpening.text);
    if (name.isEmpty || opening == null) {
      setState(
        () => _error =
            'Enter a nonblank wallet name and integer IDR opening balance.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(financeServiceProvider)
          .createWallet(
            id: _id(),
            auditId: _id(),
            name: name,
            openingBalanceIdr: opening,
            openingDate: widget.asOfDate,
          );
      if (!mounted) return;
      _walletName.clear();
      _walletOpening.text = '0';
      _showWalletForm = false;
      _reload();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not create wallet: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitCategory() async {
    final name = _categoryName.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a nonblank category name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(financeServiceProvider)
          .createCategory(
            id: _id(),
            auditId: _id(),
            name: name,
            kind: _categoryKind,
          );
      if (!mounted) return;
      _categoryName.clear();
      _showCategoryForm = false;
      _reload();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not create category: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitTransaction(
    List<WalletBalanceSummary> activeWallets,
    List<FinanceCategory> matchingCategories,
  ) async {
    final walletId = activeWallets.any((w) => w.wallet.id == _txWalletId)
        ? _txWalletId
        : (activeWallets.isNotEmpty ? activeWallets.first.wallet.id : null);
    final categoryId = matchingCategories.any((c) => c.id == _txCategoryId)
        ? _txCategoryId
        : (matchingCategories.isNotEmpty ? matchingCategories.first.id : null);
    final amount = _parsePositiveIdr(_txAmount.text);
    if (walletId == null || categoryId == null || amount == null) {
      setState(
        () => _error = 'Select a wallet, matching category and positive integer IDR amount.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(financeServiceProvider)
          .createTransaction(
            id: _id(),
            auditId: _id(),
            walletId: walletId,
            categoryId: categoryId,
            type: _txType,
            amountIdr: amount,
            localDate: widget.asOfDate,
            note: _txNote.text,
          );
      if (!mounted) return;
      _txAmount.clear();
      _txNote.clear();
      _showTxForm = false;
      _reload();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not save transaction: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editTransactionDialog(FinanceTransaction tx) async {
    final result =
        await showDialog<({String amount, String note, String reason})>(
          context: context,
          builder: (context) => _EditTransactionDialog(
            initialAmount: '${tx.amountIdr}',
            initialNote: tx.note ?? '',
          ),
        );
    if (!mounted || result == null) return;
    final updatedAmount = _parsePositiveIdr(result.amount);
    if (updatedAmount == null) {
      setState(() => _error = 'Updated amount must be a positive integer IDR.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(financeServiceProvider)
          .updateTransaction(
            transactionId: tx.id,
            auditId: _id(),
            walletId: tx.walletId,
            categoryId: tx.categoryId,
            type: tx.type,
            amountIdr: updatedAmount,
            localDate: tx.localDate,
            note: result.note,
            reason: result.reason,
          );
      if (!mounted) return;
      _reload();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not update transaction: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitTransfer(List<WalletBalanceSummary> activeWallets) async {
    final fromId = activeWallets.any((w) => w.wallet.id == _transferFromId)
        ? _transferFromId
        : (activeWallets.isNotEmpty ? activeWallets.first.wallet.id : null);
    final toId = activeWallets.any((w) => w.wallet.id == _transferToId)
        ? _transferToId
        : (activeWallets.length > 1 ? activeWallets[1].wallet.id : fromId);
    final amount = _parsePositiveIdr(_transferAmount.text);
    if (fromId == null || toId == null || amount == null) {
      setState(
        () => _error = 'Select two wallets and a positive integer IDR amount.',
      );
      return;
    }
    if (fromId == toId) {
      setState(() => _error = 'Transfer cannot target the same wallet.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(financeServiceProvider)
          .createTransfer(
            id: _id(),
            auditId: _id(),
            fromWalletId: fromId,
            toWalletId: toId,
            amountIdr: amount,
            localDate: widget.asOfDate,
            note: _transferNote.text,
          );
      if (!mounted) return;
      _transferAmount.clear();
      _transferNote.clear();
      _showTransferForm = false;
      _reload();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not save transfer: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitBudget(List<FinanceCategory> expenseCategories) async {
    final categoryId = expenseCategories.any((c) => c.id == _budgetCategoryId)
        ? _budgetCategoryId
        : (expenseCategories.isNotEmpty ? expenseCategories.first.id : null);
    final limit = _parsePositiveIdr(_budgetLimit.text);
    if (categoryId == null || limit == null) {
      setState(
        () => _error = 'Select an expense category and enter a positive integer IDR budget limit.',
      );
      return;
    }
    final (start, _) = _currentMonthRange();
    final lastDay = DateTime.utc(
      widget.asOfDate.year,
      widget.asOfDate.month + 1,
      0,
    ).day;
    final end = LocalDate(widget.asOfDate.year, widget.asOfDate.month, lastDay);

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(financeServiceProvider)
          .createBudget(
            id: _id(),
            auditId: _id(),
            categoryId: categoryId,
            periodStart: start,
            periodEndInclusive: end,
            limitIdr: limit,
            rolloverEnabled: _budgetRollover,
          );
      if (!mounted) return;
      _budgetLimit.clear();
      _budgetRollover = false;
      _showBudgetForm = false;
      _reload();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not save budget: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openAuditSheet(List<FinanceAuditRecord> audits) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.8,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Finance Audit Trail (${audits.length})',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  if (audits.isEmpty)
                    const Text('No finance audit entries yet.')
                  else
                    for (final a in audits)
                      Text(
                        '• [${a.entityType.name}:${a.operation.name}] id=${a.entityId}'
                        '${a.reason == null ? '' : ' (${a.reason})'}',
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FinanceDashboardSnapshot>(
      future: _snapshotFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done &&
            !snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('Loading finances…'),
          );
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Could not load finance data.'),
              TextButton(onPressed: _reload, child: const Text('Try again')),
            ],
          );
        }
        final data = snapshot.data!;
        final activeWallets = data.walletBalances
            .where((w) => !w.wallet.isArchived)
            .toList();
        final activeCategories = data.categories
            .where((c) => !c.isArchived)
            .toList();
        final expenseCategories = activeCategories
            .where((c) => c.kind == FinanceCategoryKind.expense)
            .toList();
        final matchingTxCategories = activeCategories
            .where((c) => c.kind.name == _txType.name)
            .toList();
        final walletNames = {
          for (final w in data.walletBalances) w.wallet.id: w.wallet.name,
        };
        final categoryNames = {for (final c in data.categories) c.id: c.name};

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            _buildSummaryCard(context, data),
            const SizedBox(height: 16),
            _buildWalletsCard(context, activeWallets),
            const SizedBox(height: 16),
            _buildCategoriesCard(context, activeCategories),
            const SizedBox(height: 16),
            _buildTransactionsCard(
              context,
              data.recentTransactions,
              activeWallets,
              matchingTxCategories,
              walletNames,
              categoryNames,
            ),
            const SizedBox(height: 16),
            _buildTransfersCard(
              context,
              data.recentTransfers,
              activeWallets,
              walletNames,
            ),
            const SizedBox(height: 16),
            _buildBudgetsCard(context, data.budgetStatuses, expenseCategories),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => _openAuditSheet(data.auditTrail),
              child: Text(
                'View finance audit trail (${data.auditTrail.length})',
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSummaryCard(
    BuildContext context,
    FinanceDashboardSnapshot data,
  ) {
    final r = data.report;
    return Card(
      key: const Key('finance-summary-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Balances vs Cash Flow (${_formatDate(r.startInclusive)} to ${_formatDate(r.endInclusive)})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Total recorded wallet balance: ${formatIdr(r.totalRecordedWalletBalanceIdr)}',
            ),
            Text('Period income: ${formatIdr(r.periodIncomeIdr)}'),
            Text('Period expense: ${formatIdr(r.periodExpenseIdr)}'),
            Text('Period net cash flow: ${formatIdr(r.periodNetCashFlowIdr)}'),
            Text(
              'Period transfers (excluded from income/expense): '
              '${formatIdr(r.periodTransferVolumeIdr)} (${r.periodTransferCount} transfers)',
            ),
            const SizedBox(height: 8),
            Text(r.scopeNotice, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _buildWalletsCard(
    BuildContext context,
    List<WalletBalanceSummary> activeWallets,
  ) {
    return Card(
      key: const Key('finance-wallets-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Wallets (IDR)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (activeWallets.isEmpty)
              const Text('No wallets recorded yet.')
            else
              for (final w in activeWallets)
                Text(
                  '• ${w.wallet.name}: ${formatIdr(w.currentBalanceIdr)} '
                  '(opening ${formatIdr(w.openingBalanceIdr)})',
                ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => setState(() => _showWalletForm = !_showWalletForm),
              child: Text(_showWalletForm ? 'Cancel wallet' : 'Add wallet'),
            ),
            if (_showWalletForm) ...[
              TextField(
                controller: _walletName,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'Wallet name'),
              ),
              TextField(
                controller: _walletOpening,
                enabled: !_busy,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Opening balance (integer IDR)',
                ),
              ),
              ElevatedButton(
                key: const Key('finance-save-wallet'),
                onPressed: _busy ? null : _submitWallet,
                child: const Text('Save wallet'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCategoriesCard(
    BuildContext context,
    List<FinanceCategory> categories,
  ) {
    return Card(
      key: const Key('finance-categories-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Categories', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (categories.isEmpty)
              const Text('No categories recorded yet.')
            else
              for (final c in categories) Text('• ${c.name} (${c.kind.name})'),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () =>
                        setState(() => _showCategoryForm = !_showCategoryForm),
              child: Text(
                _showCategoryForm ? 'Cancel category' : 'Add category',
              ),
            ),
            if (_showCategoryForm) ...[
              TextField(
                controller: _categoryName,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'Category name'),
              ),
              DropdownButtonFormField<FinanceCategoryKind>(
                initialValue: _categoryKind,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Category kind'),
                items: const [
                  DropdownMenuItem(
                    value: FinanceCategoryKind.expense,
                    child: Text('Expense'),
                  ),
                  DropdownMenuItem(
                    value: FinanceCategoryKind.income,
                    child: Text('Income'),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _categoryKind = v!),
              ),
              ElevatedButton(
                key: const Key('finance-save-category'),
                onPressed: _busy ? null : _submitCategory,
                child: const Text('Save category'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionsCard(
    BuildContext context,
    List<FinanceTransaction> transactions,
    List<WalletBalanceSummary> activeWallets,
    List<FinanceCategory> matchingCategories,
    Map<String, String> walletNames,
    Map<String, String> categoryNames,
  ) {
    final validWallet = activeWallets.any((w) => w.wallet.id == _txWalletId)
        ? _txWalletId
        : (activeWallets.isNotEmpty ? activeWallets.first.wallet.id : null);
    final validCat = matchingCategories.any((c) => c.id == _txCategoryId)
        ? _txCategoryId
        : (matchingCategories.isNotEmpty ? matchingCategories.first.id : null);

    return Card(
      key: const Key('finance-transactions-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Income & Expense Transactions',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (transactions.isEmpty)
              const Text('No income or expense transactions yet.')
            else
              for (final tx in transactions)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '• ${_formatDate(tx.localDate)} [${tx.type.name}] '
                        '${formatIdr(tx.amountIdr)} — '
                        '${categoryNames[tx.categoryId] ?? tx.categoryId} '
                        '(${walletNames[tx.walletId] ?? tx.walletId})'
                        '${tx.note == null ? '' : ' · ${tx.note}'}',
                      ),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _editTransactionDialog(tx),
                      child: const Text('Edit'),
                    ),
                  ],
                ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy || activeWallets.isEmpty
                  ? null
                  : () => setState(() => _showTxForm = !_showTxForm),
              child: Text(
                _showTxForm ? 'Cancel transaction' : 'Add transaction',
              ),
            ),
            if (_showTxForm && activeWallets.isNotEmpty) ...[
              DropdownButtonFormField<FinanceTransactionType>(
                initialValue: _txType,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Transaction type',
                ),
                items: const [
                  DropdownMenuItem(
                    value: FinanceTransactionType.expense,
                    child: Text('Expense'),
                  ),
                  DropdownMenuItem(
                    value: FinanceTransactionType.income,
                    child: Text('Income'),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                        _txType = v!;
                        _txCategoryId = null;
                      }),
              ),
              DropdownButtonFormField<String?>(
                key: ValueKey(('tx_wallet', validWallet)),
                initialValue: validWallet,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Wallet'),
                items: [
                  for (final w in activeWallets)
                    DropdownMenuItem(
                      value: w.wallet.id,
                      child: Text(
                        w.wallet.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _txWalletId = v),
              ),
              if (matchingCategories.isEmpty)
                Text('Create an ${_txType.name} category first.')
              else
                DropdownButtonFormField<String?>(
                  key: ValueKey(('tx_cat', _txType, validCat)),
                  initialValue: validCat,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    for (final c in matchingCategories)
                      DropdownMenuItem(
                        value: c.id,
                        child: Text(c.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _txCategoryId = v),
                ),
              TextField(
                controller: _txAmount,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Amount (IDR)'),
              ),
              TextField(
                controller: _txNote,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
              ElevatedButton(
                key: const Key('finance-save-tx'),
                onPressed: _busy || matchingCategories.isEmpty
                    ? null
                    : () =>
                          _submitTransaction(activeWallets, matchingCategories),
                child: const Text('Save transaction'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTransfersCard(
    BuildContext context,
    List<FinanceTransfer> transfers,
    List<WalletBalanceSummary> activeWallets,
    Map<String, String> walletNames,
  ) {
    final validFrom = activeWallets.any((w) => w.wallet.id == _transferFromId)
        ? _transferFromId
        : (activeWallets.isNotEmpty ? activeWallets.first.wallet.id : null);
    final validTo = activeWallets.any((w) => w.wallet.id == _transferToId)
        ? _transferToId
        : (activeWallets.length > 1 ? activeWallets[1].wallet.id : validFrom);

    return Card(
      key: const Key('finance-transfers-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Atomic Wallet Transfers',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (transfers.isEmpty)
              const Text('No wallet transfers recorded yet.')
            else
              for (final tr in transfers)
                Text(
                  '• ${_formatDate(tr.localDate)}: ${formatIdr(tr.amountIdr)} '
                  '(${walletNames[tr.fromWalletId] ?? tr.fromWalletId} -> '
                  '${walletNames[tr.toWalletId] ?? tr.toWalletId})',
                ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy || activeWallets.length < 2
                  ? null
                  : () =>
                        setState(() => _showTransferForm = !_showTransferForm),
              child: Text(
                _showTransferForm ? 'Cancel transfer' : 'Add transfer',
              ),
            ),
            if (_showTransferForm && activeWallets.length >= 2) ...[
              DropdownButtonFormField<String?>(
                key: ValueKey(('tr_from', validFrom)),
                initialValue: validFrom,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'From wallet'),
                items: [
                  for (final w in activeWallets)
                    DropdownMenuItem(
                      value: w.wallet.id,
                      child: Text(
                        w.wallet.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _transferFromId = v),
              ),
              DropdownButtonFormField<String?>(
                key: ValueKey(('tr_to', validTo)),
                initialValue: validTo,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'To wallet'),
                items: [
                  for (final w in activeWallets)
                    DropdownMenuItem(
                      value: w.wallet.id,
                      child: Text(
                        w.wallet.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _transferToId = v),
              ),
              TextField(
                controller: _transferAmount,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Transfer amount (IDR)',
                ),
              ),
              TextField(
                controller: _transferNote,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Transfer note (optional)',
                ),
              ),
              ElevatedButton(
                key: const Key('finance-save-transfer'),
                onPressed: _busy ? null : () => _submitTransfer(activeWallets),
                child: const Text('Save transfer'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBudgetsCard(
    BuildContext context,
    List<BudgetPeriodStatus> budgets,
    List<FinanceCategory> expenseCategories,
  ) {
    final validCat = expenseCategories.any((c) => c.id == _budgetCategoryId)
        ? _budgetCategoryId
        : (expenseCategories.isNotEmpty ? expenseCategories.first.id : null);

    return Card(
      key: const Key('finance-budgets-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Expense Budgets',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (budgets.isEmpty)
              const Text('No expense budgets configured yet.')
            else
              for (final b in budgets)
                Text(
                  '• ${b.categoryName} (${_formatDate(b.budget.periodStart)} to '
                  '${_formatDate(b.budget.periodEndInclusive)}): '
                  'spent ${formatIdr(b.spentIdr)} / ${formatIdr(b.effectiveLimitIdr)} '
                  '(remaining ${formatIdr(b.remainingIdr)})'
                  '${b.isOverBudget ? ' [OVER BUDGET]' : ''}'
                  '${b.budget.rolloverEnabled ? ' [rollover enabled]' : ''}',
                ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy || expenseCategories.isEmpty
                  ? null
                  : () => setState(() => _showBudgetForm = !_showBudgetForm),
              child: Text(_showBudgetForm ? 'Cancel budget' : 'Add budget'),
            ),
            if (_showBudgetForm && expenseCategories.isNotEmpty) ...[
              DropdownButtonFormField<String?>(
                key: ValueKey(('budget_cat', validCat)),
                initialValue: validCat,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Expense category',
                ),
                items: [
                  for (final c in expenseCategories)
                    DropdownMenuItem(
                      value: c.id,
                      child: Text(c.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _budgetCategoryId = v),
              ),
              TextField(
                controller: _budgetLimit,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Budget limit (IDR)',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Enable rollover'),
                value: _budgetRollover,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _budgetRollover = v),
              ),
              ElevatedButton(
                key: const Key('finance-save-budget'),
                onPressed: _busy
                    ? null
                    : () => _submitBudget(expenseCategories),
                child: const Text('Save budget'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EditTransactionDialog extends StatefulWidget {
  const _EditTransactionDialog({
    required this.initialAmount,
    required this.initialNote,
  });

  final String initialAmount;
  final String initialNote;

  @override
  State<_EditTransactionDialog> createState() => _EditTransactionDialogState();
}

class _EditTransactionDialogState extends State<_EditTransactionDialog> {
  late final TextEditingController _amountCtrl;
  late final TextEditingController _noteCtrl;
  late final TextEditingController _reasonCtrl;

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController(text: widget.initialAmount);
    _noteCtrl = TextEditingController(text: widget.initialNote);
    _reasonCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Edit transaction (audited)'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _amountCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Updated amount (IDR)',
            ),
          ),
          TextField(
            controller: _noteCtrl,
            decoration: const InputDecoration(labelText: 'Updated note'),
          ),
          TextField(
            controller: _reasonCtrl,
            decoration: const InputDecoration(
              labelText: 'Edit reason (optional)',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, (
          amount: _amountCtrl.text,
          note: _noteCtrl.text,
          reason: _reasonCtrl.text,
        )),
        child: const Text('Save edit'),
      ),
    ],
  );
}
