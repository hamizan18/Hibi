import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_clock.dart';

/// Preview of a validated, decrypted backup prior to full replacement restore.
class BackupPreview {
  const BackupPreview({
    required this.format,
    required this.schemaVersion,
    required this.createdAtUtc,
    required this.tableRowCounts,
    required this.totalRows,
    required this.payloadSha256Hex,
  });

  final String format;
  final int schemaVersion;
  final DateTime createdAtUtc;
  final Map<String, int> tableRowCounts;
  final int totalRows;
  final String payloadSha256Hex;
}

class RestoreOutcome {
  const RestoreOutcome({
    required this.restoredSchemaVersion,
    required this.restoredTotalRows,
    required this.preRestoreBackupEnvelope,
  });

  final int restoredSchemaVersion;
  final int restoredTotalRows;
  final String preRestoreBackupEnvelope;
}

class BackupHistoryRecord {
  const BackupHistoryRecord({
    required this.id,
    required this.operation,
    required this.format,
    required this.isEncrypted,
    required this.includedPrivate,
    this.fileName,
    this.summaryNote,
    required this.occurredAtUtc,
  });

  final String id;
  final String operation;
  final String format;
  final bool isEncrypted;
  final bool includedPrivate;
  final String? fileName;
  final String? summaryNote;
  final DateTime occurredAtUtc;
}

/// Passphrase-encrypted, integrity-checked, atomic backup and restore service.
///
/// Security properties (per SECURITY_PRIVACY.md):
/// - Uses vetted PBKDF2-HMAC-SHA256 (100,000 iterations, random 128-bit salt)
///   and authenticated AES-GCM-256 (random 96-bit nonce + 128-bit MAC).
/// - Never exports PIN verifiers, biometric credentials, or secure-storage keys.
/// - Validates envelope format, schema compatibility, SHA-256 payload digest,
///   table names, and SQLite `PRAGMA foreign_key_check` inside ONE atomic
///   transaction; invalid or tampered backups roll back cleanly without
///   partially overwriting existing data.
/// - Produces a recoverable pre-restore encrypted snapshot before replacing data.
class BackupRestoreService {
  const BackupRestoreService(this._db, this._clock);

  static const String envelopeFormat = 'hibi_backup_enc_v1';
  static const int minPassphraseLength = 8;
  static const int kdfIterations = 100000;

  /// Canonical ordered list of user tables exported in schema v17 backups.
  static const List<String> backupTables = [
    'app_settings',
    'habits',
    'habit_versions',
    'habit_counter_targets',
    'habit_version_audit',
    'habit_occurrences',
    'habit_counter_events',
    'habit_counter_event_audit',
    'habit_counter_resolutions',
    'habit_counter_recoveries',
    'habit_schedules',
    'habit_counter_correction_audit',
    'habit_version_metadata',
    'habit_checklist_items',
    'habit_checklist_occurrences',
    'habit_checklist_item_logs',
    'habit_checklist_item_recoveries',
    'habit_avoidance_targets',
    'habit_avoidance_occurrences',
    'habit_avoidance_incidents',
    'habit_avoidance_resolutions',
    'habit_typed_targets',
    'habit_version_scoring',
    'habit_typed_occurrences',
    'habit_duration_events',
    'habit_typed_logs',
    'habit_lifecycle_events',
    'habit_lifecycle_start_pauses',
    'finance_wallets',
    'finance_categories',
    'finance_transactions',
    'finance_transfers',
    'finance_budgets',
    'finance_audit',
    'journal_entries',
    'journal_entry_tags',
    'goals',
    'goal_status_history',
    'goal_milestones',
    'goal_habit_links',
    'goal_progress_entries',
    'focus_presets',
    'focus_sessions',
    'gamification_xp_ledger',
    'gamification_achievements',
    'gamification_achievement_history',
    'gamification_attributes',
    'gamification_habit_attributes',
    'habit_reminders',
  ];

  final AppDatabase _db;
  final AppClock _clock;

  /// Creates an encrypted JSON backup envelope protected by [passphrase].
  Future<String> createEncryptedBackup({
    required String passphrase,
    String? fileName,
    bool recordHistory = true,
  }) async {
    _validatePassphrase(passphrase);
    final payloadMap = await _snapshotDatabasePayload();
    final plaintextJson = jsonEncode(payloadMap);
    final envelope = await _encryptPayload(
      plaintextJson: plaintextJson,
      passphrase: passphrase,
      schemaVersion: _db.schemaVersion,
    );

    if (recordHistory) {
      final nowUs = _clock.now().toUtc().microsecondsSinceEpoch;
      final countRow = await _db
          .customSelect('SELECT COUNT(*) AS c FROM backup_history')
          .getSingle();
      final seq = countRow.read<int>('c') + 1;
      final tables = payloadMap['tables'] as Map<String, dynamic>;
      final totalRows = tables.values.fold<int>(
        0,
        (sum, list) => sum + (list as List).length,
      );
      await _db.customStatement(
        '''
        INSERT INTO backup_history (
          id, operation, format, is_encrypted, included_private,
          file_name, summary_note, occurred_at_utc_us
        )
        VALUES (?, 'backup', ?, 1, 1, ?, ?, ?)
        ''',
        [
          'bk_${seq}_$nowUs',
          envelopeFormat,
          fileName,
          'Encrypted backup created ($totalRows rows, schema v${_db.schemaVersion})',
          nowUs,
        ],
      );
    }
    return envelope;
  }

  /// Decrypts and validates a backup envelope without modifying the database.
  Future<BackupPreview> previewBackup({
    required String encryptedEnvelope,
    required String passphrase,
  }) async {
    final decoded = await _decryptAndValidatePayload(
      encryptedEnvelope: encryptedEnvelope,
      passphrase: passphrase,
    );
    final tables = decoded.tables;
    final counts = <String, int>{
      for (final entry in tables.entries) entry.key: entry.value.length,
    };
    final total = counts.values.fold<int>(0, (s, c) => s + c);
    return BackupPreview(
      format: envelopeFormat,
      schemaVersion: decoded.schemaVersion,
      createdAtUtc: decoded.createdAtUtc,
      tableRowCounts: Map<String, int>.unmodifiable(counts),
      totalRows: total,
      payloadSha256Hex: decoded.sha256Hex,
    );
  }

  /// Atomically replaces all local database content from a validated encrypted
  /// backup after creating a recoverable pre-restore encrypted snapshot.
  ///
  /// Any invalid payload, schema mismatch, foreign-key violation, or write
  /// error rolls back the SQLite transaction completely so existing data is
  /// never partially overwritten.
  Future<RestoreOutcome> restoreFromBackup({
    required String encryptedEnvelope,
    required String passphrase,
    required bool confirmFullReplace,
    String? preRestorePassphrase,
    String? fileName,
  }) async {
    if (!confirmFullReplace) {
      throw StateError('Explicit full-replace confirmation is required');
    }
    final decoded = await _decryptAndValidatePayload(
      encryptedEnvelope: encryptedEnvelope,
      passphrase: passphrase,
    );

    // Create a recoverable encrypted pre-restore snapshot BEFORE touching data.
    final preRestoreEnvelope = await createEncryptedBackup(
      passphrase: preRestorePassphrase ?? passphrase,
      recordHistory: false,
    );

    var restoredTotalRows = 0;

    await _db.transaction(() async {
      final triggerRows = await _db
          .customSelect(
            "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND sql IS NOT NULL",
          )
          .get();
      final savedTriggers = [
        for (final row in triggerRows)
          (name: row.read<String>('name'), sql: row.read<String>('sql')),
      ];

      for (final t in savedTriggers) {
        await _db.customStatement('DROP TRIGGER "${t.name}"');
      }

      try {
        await _db.customStatement('PRAGMA foreign_keys = OFF');
        try {
          // Clear all managed user tables in reverse dependency order.
          for (final table in backupTables.reversed) {
            await _db.customStatement('DELETE FROM "$table"');
          }

          // Insert validated rows table-by-table.
          for (final table in backupTables) {
            final rows =
                decoded.tables[table] ?? const <Map<String, dynamic>>[];
            if (rows.isEmpty) continue;
            final colInfo = await _db
                .customSelect('PRAGMA table_info("$table")')
                .get();
            final validColumns = {
              for (final c in colInfo) c.read<String>('name'),
            };

            for (final row in rows) {
              final cols = row.keys.toList();
              if (cols.isEmpty) {
                throw FormatException('Empty row in backup table "$table"');
              }
              for (final col in cols) {
                if (!validColumns.contains(col)) {
                  throw FormatException(
                    'Unknown column "$col" in backup table "$table"',
                  );
                }
              }
              final colList = cols.map((c) => '"$c"').join(', ');
              final placeholders = List.filled(cols.length, '?').join(', ');
              final values = [for (final col in cols) row[col]];
              await _db.customStatement(
                'INSERT INTO "$table" ($colList) VALUES ($placeholders)',
                values,
              );
              restoredTotalRows++;
            }
          }
        } finally {
          await _db.customStatement('PRAGMA foreign_keys = ON');
        }

        // Verify relational integrity across the entire restored database!
        final fkErrors = await _db
            .customSelect('PRAGMA foreign_key_check')
            .get();
        if (fkErrors.isNotEmpty) {
          throw FormatException(
            'Backup failed foreign-key integrity check (${fkErrors.length} violation(s))',
          );
        }
      } finally {
        for (final t in savedTriggers) {
          await _db.customStatement(t.sql);
        }
      }

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
        VALUES (?, 'restore', ?, 1, 1, ?, ?, ?)
        ''',
        [
          'rst_${seq}_$nowUs',
          envelopeFormat,
          fileName,
          'Atomic restore completed ($restoredTotalRows rows, schema v${decoded.schemaVersion})',
          nowUs,
        ],
      );
    });

    return RestoreOutcome(
      restoredSchemaVersion: decoded.schemaVersion,
      restoredTotalRows: restoredTotalRows,
      preRestoreBackupEnvelope: preRestoreEnvelope,
    );
  }

  Future<List<BackupHistoryRecord>> readHistory({int limit = 30}) async {
    final rows = await _db
        .customSelect(
          '''
          SELECT id, operation, format, is_encrypted, included_private,
                 file_name, summary_note, occurred_at_utc_us
          FROM backup_history
          ORDER BY occurred_at_utc_us DESC, id DESC
          LIMIT ?
          ''',
          variables: [Variable<int>(limit)],
        )
        .get();
    return [
      for (final row in rows)
        BackupHistoryRecord(
          id: row.read<String>('id'),
          operation: row.read<String>('operation'),
          format: row.read<String>('format'),
          isEncrypted: row.read<int>('is_encrypted') == 1,
          includedPrivate: row.read<int>('included_private') == 1,
          fileName: row.readNullable<String>('file_name'),
          summaryNote: row.readNullable<String>('summary_note'),
          occurredAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            row.read<int>('occurred_at_utc_us'),
            isUtc: true,
          ),
        ),
    ];
  }

  Future<Map<String, Object?>> _snapshotDatabasePayload() =>
      _db.transaction(() async {
        final tablesMap = <String, List<Map<String, Object?>>>{};
        for (final table in backupTables) {
          final rows = await _db.customSelect('SELECT * FROM "$table"').get();
          final list = <Map<String, Object?>>[];
          for (final row in rows) {
            if (table == 'app_settings') {
              final key = row.data['key'] as String? ?? '';
              // Defense in depth: never export any security/PIN/biometric keys.
              if (key.contains('pin') ||
                  key.contains('secret') ||
                  key.contains('biometric')) {
                continue;
              }
            }
            list.add(Map<String, Object?>.from(row.data));
          }
          tablesMap[table] = list;
        }
        final canonicalTablesJson = jsonEncode(tablesMap);
        final digest = await Sha256().hash(utf8.encode(canonicalTablesJson));
        final shaHex = _bytesToHex(digest.bytes);
        return {
          'format': envelopeFormat,
          'schema_version': _db.schemaVersion,
          'created_at_utc': _clock.now().toUtc().toIso8601String(),
          'tables_sha256': shaHex,
          'tables': tablesMap,
        };
      });

  Future<String> _encryptPayload({
    required String plaintextJson,
    required String passphrase,
    required int schemaVersion,
  }) async {
    final rng = Random.secure();
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));
    final nonce = List<int>.generate(12, (_) => rng.nextInt(256));

    final key = await _deriveBackupKey(passphrase, salt, kdfIterations);
    final cipher = AesGcm.with256bits();
    final secretBox = await cipher.encrypt(
      utf8.encode(plaintextJson),
      secretKey: key,
      nonce: nonce,
    );

    return jsonEncode({
      'format': envelopeFormat,
      'schema_version': schemaVersion,
      'kdf': 'pbkdf2_hmac_sha256',
      'iterations': kdfIterations,
      'salt_b64': base64Encode(salt),
      'cipher': 'aes_gcm_256',
      'nonce_b64': base64Encode(secretBox.nonce),
      'mac_b64': base64Encode(secretBox.mac.bytes),
      'ciphertext_b64': base64Encode(secretBox.cipherText),
    });
  }

  Future<_DecodedBackupPayload> _decryptAndValidatePayload({
    required String encryptedEnvelope,
    required String passphrase,
  }) async {
    if (passphrase.isEmpty) {
      throw const FormatException('Backup passphrase is required');
    }
    late final Map<String, dynamic> env;
    try {
      env = jsonDecode(encryptedEnvelope) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Invalid backup file: not valid JSON');
    }

    if (env['format'] != envelopeFormat) {
      throw FormatException('Unsupported backup format: ${env['format']}');
    }
    if (env['kdf'] != 'pbkdf2_hmac_sha256' || env['cipher'] != 'aes_gcm_256') {
      throw const FormatException('Unsupported backup encryption parameters');
    }
    final envSchema = env['schema_version'];
    if (envSchema is! int || envSchema < 1 || envSchema > _db.schemaVersion) {
      throw FormatException('Incompatible backup schema version: $envSchema');
    }

    late final List<int> salt;
    late final List<int> nonce;
    late final List<int> macBytes;
    late final List<int> cipherText;
    late final int iterations;
    try {
      iterations = env['iterations'] as int;
      if (iterations < 10000) {
        throw const FormatException('Invalid KDF iteration count');
      }
      salt = base64Decode(env['salt_b64'] as String);
      nonce = base64Decode(env['nonce_b64'] as String);
      macBytes = base64Decode(env['mac_b64'] as String);
      cipherText = base64Decode(env['ciphertext_b64'] as String);
    } catch (_) {
      throw const FormatException('Corrupted backup encryption envelope');
    }

    final key = await _deriveBackupKey(passphrase, salt, iterations);
    final cipher = AesGcm.with256bits();
    late final List<int> clearBytes;
    try {
      clearBytes = await cipher.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes)),
        secretKey: key,
      );
    } catch (_) {
      throw const FormatException(
        'Unable to decrypt backup: wrong passphrase or tampered file',
      );
    }

    late final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(utf8.decode(clearBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Decrypted backup payload is corrupted');
    }

    if (payload['format'] != envelopeFormat) {
      throw const FormatException('Mismatched inner backup format');
    }
    final innerSchema = payload['schema_version'];
    if (innerSchema is! int || innerSchema != envSchema) {
      throw const FormatException('Mismatched backup schema version');
    }
    final createdRaw = payload['created_at_utc'];
    if (createdRaw is! String) {
      throw const FormatException('Missing backup timestamp');
    }
    final createdAtUtc = DateTime.parse(createdRaw).toUtc();

    final rawTables = payload['tables'];
    if (rawTables is! Map<String, dynamic>) {
      throw const FormatException('Missing backup tables object');
    }
    final expectedSha = payload['tables_sha256'];
    final actualDigest = await Sha256().hash(
      utf8.encode(jsonEncode(rawTables)),
    );
    final actualSha = _bytesToHex(actualDigest.bytes);
    if (expectedSha != actualSha) {
      throw const FormatException('Backup integrity checksum mismatch');
    }

    final allowed = backupTables.toSet();
    final parsedTables = <String, List<Map<String, dynamic>>>{};
    for (final entry in rawTables.entries) {
      if (!allowed.contains(entry.key)) {
        throw FormatException('Unexpected table in backup: ${entry.key}');
      }
      final rawList = entry.value;
      if (rawList is! List) {
        throw FormatException('Invalid row list for table ${entry.key}');
      }
      parsedTables[entry.key] = [
        for (final item in rawList)
          if (item is Map<String, dynamic>)
            item
          else
            throw FormatException('Invalid row object in table ${entry.key}'),
      ];
    }

    return _DecodedBackupPayload(
      schemaVersion: innerSchema,
      createdAtUtc: createdAtUtc,
      sha256Hex: actualSha,
      tables: parsedTables,
    );
  }

  Future<SecretKey> _deriveBackupKey(
    String passphrase,
    List<int> salt,
    int iterations,
  ) {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    return pbkdf2.deriveKeyFromPassword(password: passphrase, nonce: salt);
  }

  void _validatePassphrase(String passphrase) {
    if (passphrase.length < minPassphraseLength) {
      throw ArgumentError(
        'Backup passphrase must be at least $minPassphraseLength characters',
      );
    }
  }
}

class _DecodedBackupPayload {
  const _DecodedBackupPayload({
    required this.schemaVersion,
    required this.createdAtUtc,
    required this.sha256Hex,
    required this.tables,
  });

  final int schemaVersion;
  final DateTime createdAtUtc;
  final String sha256Hex;
  final Map<String, List<Map<String, dynamic>>> tables;
}

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
