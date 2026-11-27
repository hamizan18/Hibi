import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:hibi/core/services/app_clock.dart';
import 'package:hibi/features/finance/data/finance_service.dart';
import 'package:hibi/features/finance/domain/finance_models.dart';
import 'package:hibi/features/habits/domain/habit_schedule.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'test_schema_downgrade.dart';

class _Clock implements AppClock {
  DateTime current = DateTime(2026, 11, 26, 10);
  @override
  DateTime now() => current;
}

void main() {
  test('FinanceService enforces validation, SQLite constraints, atomic transfers, immutable audits and audited edits', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = _Clock();
    final service = FinanceService(db, clock);
    final nov26 = LocalDate(2026, 11, 26);

    await service.createWallet(
      id: 'w1',
      auditId: 'a_w1',
      name: 'Cash',
      openingBalanceIdr: 200000,
      openingDate: nov26,
    );
    await service.createWallet(
      id: 'w2',
      auditId: 'a_w2',
      name: 'Bank',
      openingBalanceIdr: 1000000,
      openingDate: nov26,
    );
    await service.createCategory(
      id: 'c_inc',
      auditId: 'a_c1',
      name: 'Salary',
      kind: FinanceCategoryKind.income,
    );
    await service.createCategory(
      id: 'c_exp',
      auditId: 'a_c2',
      name: 'Groceries',
      kind: FinanceCategoryKind.expense,
    );

    // Category kind mismatch rejected
    await expectLater(
      service.createTransaction(
        id: 'tx_bad',
        auditId: 'a_bad',
        walletId: 'w1',
        categoryId: 'c_inc',
        type: FinanceTransactionType.expense,
        amountIdr: 50000,
        localDate: nov26,
      ),
      throwsArgumentError,
    );

    // Same-wallet transfer rejected
    await expectLater(
      service.createTransfer(
        id: 'tr_bad',
        auditId: 'a_tr_bad',
        fromWalletId: 'w1',
        toWalletId: 'w1',
        amountIdr: 50000,
        localDate: nov26,
      ),
      throwsArgumentError,
    );

    // Budget on income category rejected
    await expectLater(
      service.createBudget(
        id: 'b_bad',
        auditId: 'a_b_bad',
        categoryId: 'c_inc',
        periodStart: LocalDate(2026, 11, 1),
        periodEndInclusive: LocalDate(2026, 11, 30),
        limitIdr: 500000,
      ),
      throwsArgumentError,
    );

    // Valid income, expense, transfer, budget and edit
    await service.createTransaction(
      id: 'tx_inc',
      auditId: 'a_tx1',
      walletId: 'w2',
      categoryId: 'c_inc',
      type: FinanceTransactionType.income,
      amountIdr: 2000000,
      localDate: nov26,
    );
    await service.createTransaction(
      id: 'tx_exp',
      auditId: 'a_tx2',
      walletId: 'w1',
      categoryId: 'c_exp',
      type: FinanceTransactionType.expense,
      amountIdr: 75000,
      localDate: nov26,
      note: 'Initial groceries',
    );
    await service.createTransfer(
      id: 'tr1',
      auditId: 'a_tr1',
      fromWalletId: 'w2',
      toWalletId: 'w1',
      amountIdr: 300000,
      localDate: nov26,
    );
    await service.createBudget(
      id: 'b1',
      auditId: 'a_b1',
      categoryId: 'c_exp',
      periodStart: LocalDate(2026, 11, 1),
      periodEndInclusive: LocalDate(2026, 11, 30),
      limitIdr: 200000,
    );

    // Audited edit: change expense from 75,000 to 125,000
    clock.current = DateTime(2026, 11, 26, 12);
    await service.updateTransaction(
      transactionId: 'tx_exp',
      auditId: 'a_tx2_edit',
      walletId: 'w1',
      categoryId: 'c_exp',
      type: FinanceTransactionType.expense,
      amountIdr: 125000,
      localDate: nov26,
      note: 'Corrected receipt',
      reason: 'Receipt typo',
    );

    final dash = await service.readDashboardSnapshot(
      startInclusive: LocalDate(2026, 11, 1),
      endInclusive: LocalDate(2026, 11, 30),
    );
    final cash = dash.walletBalances.firstWhere((w) => w.wallet.id == 'w1');
    final bank = dash.walletBalances.firstWhere((w) => w.wallet.id == 'w2');
    // Cash: 200,000 - 125,000 + 300,000 = 375,000
    expect(cash.currentBalanceIdr, 375000);
    // Bank: 1,000,000 + 2,000,000 - 300,000 = 2,700,000
    expect(bank.currentBalanceIdr, 2700000);
    expect(dash.report.periodIncomeIdr, 2000000);
    expect(dash.report.periodExpenseIdr, 125000);
    expect(dash.report.periodNetCashFlowIdr, 1875000);
    expect(dash.report.periodTransferVolumeIdr, 300000);
    expect(dash.budgetStatuses.single.spentIdr, 125000);
    expect(dash.budgetStatuses.single.remainingIdr, 75000);

    // Finance audit records are immutable in SQLite
    final txAudits = await service.readAuditTrail(
      entityType: FinanceAuditEntityType.transaction,
      entityId: 'tx_exp',
    );
    expect(txAudits.length, 2);
    expect(txAudits.last.operation, FinanceAuditOperation.update);
    expect(txAudits.last.previousValues!['amount_idr'], 75000);
    expect(txAudits.last.updatedValues['amount_idr'], 125000);
    await expectLater(
      db.customStatement("UPDATE finance_audit SET reason = 'tampered'"),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      db.customStatement('DELETE FROM finance_audit'),
      throwsA(isA<Exception>()),
    );
  });

  test('v13 to v14 migration preserves existing habits/settings, rolls back on failure, and survives disk reopen', () async {
    final dir = await Directory.systemTemp.createTemp('hibi_v14_mig_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(path.join(dir.path, 'hibi.sqlite'));

    final seed = AppDatabase(NativeDatabase(file));
    await seed.setSetting('theme', 'dark');
    await seed.customStatement("INSERT INTO habits VALUES ('h_existing', 1)");
    await seed.close();

    // Downgrade to v13
    final legacy = sqlite.sqlite3.open(file.path);
    dropV14Schema(legacy);
    legacy.execute('PRAGMA user_version = 13');
    legacy.close();

    // Upgrade v13 -> v14
    final migrated = AppDatabase(NativeDatabase(file));
    expect(await migrated.getSetting('theme'), 'dark');
    expect(
      (await migrated.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      14,
    );
    expect(
      (await migrated
              .customSelect("SELECT id FROM habits WHERE id = 'h_existing'")
              .getSingle())
          .read<String>('id'),
      'h_existing',
    );
    await FinanceService(migrated, _Clock()).createWallet(
      id: 'w_post',
      auditId: 'a_post',
      name: 'Savings',
      openingBalanceIdr: 500000,
      openingDate: LocalDate(2026, 11, 26),
    );
    await migrated.close();

    final reopened = AppDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    final wallets = await FinanceService(reopened, _Clock()).readWallets();
    expect(wallets.single.name, 'Savings');
    expect(wallets.single.openingBalanceIdr, 500000);

    // Rollback test on failed v13 -> v14 migration
    final failFile = File(path.join(dir.path, 'fail.sqlite'));
    final seedFail = AppDatabase(NativeDatabase(failFile));
    await seedFail.setSetting('theme', 'dark');
    await seedFail.close();
    final legacyFail = sqlite.sqlite3.open(failFile.path);
    dropV14Schema(legacyFail);
    legacyFail.execute('CREATE TABLE finance_wallets (sentinel TEXT)');
    legacyFail.execute("INSERT INTO finance_wallets VALUES ('keep')");
    legacyFail.execute('PRAGMA user_version = 13');
    legacyFail.close();

    final badMigrated = AppDatabase(NativeDatabase(failFile));
    await expectLater(
      badMigrated.getSetting('theme'),
      throwsA(isA<Exception>()),
    );
    await badMigrated.close();

    final unchanged = sqlite.sqlite3.open(failFile.path);
    expect(unchanged.select('PRAGMA user_version').single['user_version'], 13);
    expect(
      unchanged
          .select('SELECT sentinel FROM finance_wallets')
          .single['sentinel'],
      'keep',
    );
    unchanged.close();
  });
}
