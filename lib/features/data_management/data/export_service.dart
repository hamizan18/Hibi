import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';
import '../../finance/data/finance_service.dart';
import '../../finance/domain/finance_models.dart';
import '../../gamification/data/gamification_service.dart';
import '../../growth/data/goal_service.dart';
import '../../growth/data/journal_service.dart';
import '../../growth/domain/goal_models.dart';
import '../../growth/domain/journal_models.dart';
import '../../habits/data/unified_habit_registry.dart';
import '../../habits/domain/habit_schedule.dart';

class CsvExportBundle {
  const CsvExportBundle({
    required this.habitsCsv,
    required this.financeTransactionsCsv,
    required this.journalCsv,
    required this.goalsCsv,
    required this.includedPrivate,
  });

  final String habitsCsv;
  final String financeTransactionsCsv;
  final String journalCsv;
  final String goalsCsv;
  final bool includedPrivate;
}

/// Private-by-default human-readable JSON, CSV and PDF exports.
///
/// Security & privacy rules (per SECURITY_PRIVACY.md & T-010):
/// - Excludes private and unclassified habits, private journal entries, and
///   private goals by default (`includePrivate = false`).
/// - Never exports PIN verifiers, biometric credentials, or security secrets.
/// - Always surfaces a clear warning that JSON, CSV and PDF exports are
///   unencrypted human-readable files.
class ExportService {
  const ExportService(this._db, this._clock);

  static const String unencryptedExportWarning =
      'Human-readable JSON, CSV and PDF exports are NOT encrypted. Store and '
      'share exported files carefully. Private records are excluded by default.';

  final AppDatabase _db;
  final AppClock _clock;

  Future<String> exportJson({
    required LocalDate asOfDate,
    bool includePrivate = false,
  }) async {
    final data = await _collectExportData(
      asOfDate: asOfDate,
      includePrivate: includePrivate,
    );
    final nowUtc = _clock.now().toUtc();
    final jsonMap = <String, Object?>{
      'format': 'hibi_export_json_v1',
      'exported_at_utc': nowUtc.toIso8601String(),
      'as_of_date': _dateKey(asOfDate),
      'included_private': includePrivate,
      'warning': unencryptedExportWarning,
      'habits': [
        for (final h in data.habits)
          {
            'habit_id': h.habitId,
            'name': h.name,
            'tracking_type': h.trackingType.name,
            'category': h.metadata?.category,
            'is_private': h.metadata?.isPrivate ?? true,
            'applicability': h.applicability.applicability.name,
          },
      ],
      'finance': {
        'currency': 'IDR',
        'total_recorded_wallet_balance_idr':
            data.finance.report.totalRecordedWalletBalanceIdr,
        'period_income_idr': data.finance.report.periodIncomeIdr,
        'period_expense_idr': data.finance.report.periodExpenseIdr,
        'period_net_cash_flow_idr': data.finance.report.periodNetCashFlowIdr,
        'wallets': [
          for (final w in data.finance.walletBalances)
            {
              'id': w.wallet.id,
              'name': w.wallet.name,
              'opening_balance_idr': w.wallet.openingBalanceIdr,
              'current_balance_idr': w.currentBalanceIdr,
            },
        ],
        'transactions': [
          for (final tx in data.finance.recentTransactions)
            {
              'id': tx.id,
              'local_date': _dateKey(tx.localDate),
              'type': tx.type.name,
              'amount_idr': tx.amountIdr,
              'wallet_id': tx.walletId,
              'category_id': tx.categoryId,
              'note': tx.note,
            },
        ],
      },
      'journal_entries': [
        for (final e in data.journals)
          {
            'id': e.id,
            'local_date': _dateKey(e.localDate),
            'title': e.title,
            'mood': e.mood?.storageKey,
            'reflection': e.reflectionText,
            'gratitude': e.gratitudeText,
            'tags': e.tags,
            'is_private': e.isPrivate,
          },
      ],
      'goals': [
        for (final g in data.goals)
          {
            'id': g.goal.id,
            'title': g.goal.title,
            'status': g.goal.status.storageKey,
            'total_units': g.totalUnits,
            'target_units': g.goal.targetUnits,
            'completed_milestones': g.completedMilestones,
            'total_milestones': g.totalMilestones,
            'is_private': g.goal.isPrivate,
          },
      ],
      'gamification': {
        'level': data.gamification.levelProgress.level,
        'total_xp': data.gamification.levelProgress.totalXp,
        'unlocked_valid_achievements': data.gamification.achievements
            .where((a) => a.isCurrentlyValid)
            .map((a) => a.definition.title)
            .toList(),
      },
    };

    await _recordExportHistory(
      operation: 'export_json',
      format: 'json',
      includedPrivate: includePrivate,
      note:
          'JSON export (${data.habits.length} habits, ${data.journals.length} journals)',
    );
    return const JsonEncoder.withIndent('  ').convert(jsonMap);
  }

  Future<CsvExportBundle> exportCsvBundle({
    required LocalDate asOfDate,
    bool includePrivate = false,
  }) async {
    final data = await _collectExportData(
      asOfDate: asOfDate,
      includePrivate: includePrivate,
    );

    final habitsBuf = StringBuffer()
      ..writeln(
        'habit_id,name,tracking_type,category,is_private,applicability',
      );
    for (final h in data.habits) {
      habitsBuf.writeln(
        _csvRow([
          h.habitId,
          h.name ?? '',
          h.trackingType.name,
          h.metadata?.category ?? '',
          '${h.metadata?.isPrivate ?? true}',
          h.applicability.applicability.name,
        ]),
      );
    }

    final txBuf = StringBuffer()
      ..writeln('id,local_date,type,amount_idr,wallet_id,category_id,note');
    for (final tx in data.finance.recentTransactions) {
      txBuf.writeln(
        _csvRow([
          tx.id,
          _dateKey(tx.localDate),
          tx.type.name,
          '${tx.amountIdr}',
          tx.walletId,
          tx.categoryId,
          tx.note ?? '',
        ]),
      );
    }

    final journalBuf = StringBuffer()
      ..writeln(
        'id,local_date,title,mood,reflection,gratitude,tags,is_private',
      );
    for (final e in data.journals) {
      journalBuf.writeln(
        _csvRow([
          e.id,
          _dateKey(e.localDate),
          e.title ?? '',
          e.mood?.label ?? '',
          e.reflectionText ?? '',
          e.gratitudeText ?? '',
          e.tags.join(';'),
          '${e.isPrivate}',
        ]),
      );
    }

    final goalsBuf = StringBuffer()
      ..writeln(
        'id,title,status,total_units,target_units,completed_milestones,total_milestones,is_private',
      );
    for (final g in data.goals) {
      goalsBuf.writeln(
        _csvRow([
          g.goal.id,
          g.goal.title,
          g.goal.status.label,
          '${g.totalUnits}',
          '${g.goal.targetUnits ?? ''}',
          '${g.completedMilestones}',
          '${g.totalMilestones}',
          '${g.goal.isPrivate}',
        ]),
      );
    }

    await _recordExportHistory(
      operation: 'export_csv',
      format: 'csv',
      includedPrivate: includePrivate,
      note:
          'CSV bundle export (${data.habits.length} habits, ${data.finance.recentTransactions.length} transactions)',
    );

    return CsvExportBundle(
      habitsCsv: habitsBuf.toString(),
      financeTransactionsCsv: txBuf.toString(),
      journalCsv: journalBuf.toString(),
      goalsCsv: goalsBuf.toString(),
      includedPrivate: includePrivate,
    );
  }

  /// Generates an unencrypted PDF with the bundled Japanese font.
  /// Private records are excluded by default.
  Future<Uint8List> exportPdfBytes({
    required LocalDate asOfDate,
    bool includePrivate = false,
  }) async {
    final data = await _collectExportData(
      asOfDate: asOfDate,
      includePrivate: includePrivate,
    );

    final font = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSansJP.ttf'),
    );
    final theme = pw.ThemeData.withFont(base: font, bold: font);
    final headerDate = japaneseDate(
      DateTime(asOfDate.year, asOfDate.month, asOfDate.day),
    );
    final headerTitle = 'Hibi (日々) Personal Summary ($headerDate)';

    final doc = pw.Document(
      title: 'Hibi Report ${_dateKey(asOfDate)}',
      author: 'Hibi Local Export',
      theme: theme,
    );
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          pw.Header(level: 0, child: pw.Text(headerTitle)),
          pw.Text(
            'Scope: ${includePrivate ? 'Includes private records (explicitly requested)' : 'Public records only (private excluded by default)'}',
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            unencryptedExportWarning,
            style: const pw.TextStyle(fontSize: 9),
          ),
          pw.SizedBox(height: 16),
          pw.Header(level: 1, child: pw.Text('Habits (${data.habits.length})')),
          if (data.habits.isEmpty)
            pw.Text('No habits in export scope.')
          else
            for (final h in data.habits)
              pw.Bullet(
                text:
                    '${h.name ?? h.habitId} [${h.trackingType.name}] - ${h.applicability.applicability.name}',
              ),
          pw.SizedBox(height: 12),
          pw.Header(level: 1, child: pw.Text('Finance (IDR)')),
          pw.Text(
            'Total recorded wallet balance: ${formatIdr(data.finance.report.totalRecordedWalletBalanceIdr)}',
          ),
          pw.Text(
            'Month income: ${formatIdr(data.finance.report.periodIncomeIdr)} | '
            'Expense: ${formatIdr(data.finance.report.periodExpenseIdr)} | '
            'Net cash flow: ${formatIdr(data.finance.report.periodNetCashFlowIdr)}',
          ),
          pw.SizedBox(height: 12),
          pw.Header(
            level: 1,
            child: pw.Text(
              'Growth & Rewards (Level ${data.gamification.levelProgress.level}, '
              '${data.gamification.levelProgress.totalXp} XP)',
            ),
          ),
          pw.Text(
            'Journal entries in scope: ${data.journals.length} | Goals in scope: ${data.goals.length}',
          ),
          for (final g in data.goals)
            pw.Bullet(
              text:
                  '${g.goal.title} (${g.goal.status.label}) - '
                  'Progress: ${g.totalUnits} units, Milestones: ${g.completedMilestones}/${g.totalMilestones}',
            ),
        ],
      ),
    );

    final bytes = await doc.save();
    await _recordExportHistory(
      operation: 'export_pdf',
      format: 'pdf',
      includedPrivate: includePrivate,
      note: 'PDF summary report (${bytes.length} bytes)',
    );
    return bytes;
  }

  Future<_CollectedExportData> _collectExportData({
    required LocalDate asOfDate,
    required bool includePrivate,
  }) async {
    final allHabits = await UnifiedHabitRegistryReader(_db)
        .readAll(asOfDate: asOfDate);
    final visibleHabits = includePrivate
        ? allHabits
        : allHabits
              .where((h) => h.metadata != null && !h.metadata!.isPrivate)
              .toList();

    final monthStart = LocalDate(asOfDate.year, asOfDate.month, 1);
    final financeSnapshot = await FinanceService(
      _db,
      _clock,
    ).readDashboardSnapshot(startInclusive: monthStart, endInclusive: asOfDate);
    final journals = await JournalService(
      _db,
      _clock,
    ).readEntries(includePrivate: includePrivate);
    final goals = await GoalService(
      _db,
      _clock,
    ).readAllGoalSummaries(includePrivate: includePrivate);
    final gamification = await GamificationService(_db, _clock).readSnapshot();

    return _CollectedExportData(
      habits: visibleHabits,
      finance: financeSnapshot,
      journals: journals,
      goals: goals,
      gamification: gamification,
    );
  }

  Future<void> _recordExportHistory({
    required String operation,
    required String format,
    required bool includedPrivate,
    required String note,
  }) async {
    final nowUs = _clock.now().toUtc().microsecondsSinceEpoch;
    final countRow = await _db
        .customSelect('SELECT COUNT(*) AS c FROM backup_history')
        .getSingle();
    final seq = countRow.read<int>('c') + 1;
    await _db.customStatement(
      '''
      INSERT INTO backup_history (
        id, operation, format, is_encrypted, included_private,
        file_name, summary_note, occurred_at_utc_us
      )
      VALUES (?, ?, ?, 0, ?, NULL, ?, ?)
      ''',
      [
        'exp_${format}_${seq}_$nowUs',
        operation,
        format,
        includedPrivate ? 1 : 0,
        note,
        nowUs,
      ],
    );
  }
}

class _CollectedExportData {
  const _CollectedExportData({
    required this.habits,
    required this.finance,
    required this.journals,
    required this.goals,
    required this.gamification,
  });

  final List<UnifiedHabitSummary> habits;
  final FinanceDashboardSnapshot finance;
  final List<JournalEntry> journals;
  final List<GoalProgressSummary> goals;
  final GamificationSnapshot gamification;
}

String _csvRow(List<String> fields) => fields.map(_csvEscape).join(',');

String _csvEscape(String raw) {
  if (raw.contains(',') ||
      raw.contains('"') ||
      raw.contains('\n') ||
      raw.contains('\r')) {
    return '"${raw.replaceAll('"', '""')}"';
  }
  return raw;
}

String _dateKey(LocalDate date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
