import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibi/core/database/app_database.dart';
import 'package:path/path.dart' as path;

void main() {
  test('settings can be inserted, updated and deleted in memory', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    expect(await database.getSetting('theme'), isNull);
    await database.setSetting('theme', 'light');
    expect(await database.getSetting('theme'), 'light');
    await database.setSetting('theme', 'dark');
    expect(await database.getSetting('theme'), 'dark');
    await database.deleteSetting('theme');
    expect(await database.getSetting('theme'), isNull);
  });

  test('schema version and foreign key enforcement are enabled', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    final version = await database
        .customSelect('PRAGMA user_version')
        .getSingle();
    expect(version.read<int>('user_version'), 9);
    final foreignKeys = await database
        .customSelect('PRAGMA foreign_keys')
        .getSingle();
    expect(foreignKeys.read<int>('foreign_keys'), 1);

    await database.customStatement(
      'CREATE TABLE parent (id INTEGER PRIMARY KEY)',
    );
    await database.customStatement(
      'CREATE TABLE child (parent_id INTEGER REFERENCES parent(id))',
    );
    await expectLater(
      database.customStatement('INSERT INTO child (parent_id) VALUES (1)'),
      throwsA(isA<Exception>()),
    );
  });

  test('settings survive closing and reopening a disk database', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hibi_database_test_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File(path.join(directory.path, 'test.sqlite'));

    final first = AppDatabase(NativeDatabase(file));
    try {
      await first.setSetting('language', 'en');
    } finally {
      await first.close();
    }

    final reopened = AppDatabase(NativeDatabase(file));
    try {
      expect(await reopened.getSetting('language'), 'en');
      final foreignKeys = await reopened
          .customSelect('PRAGMA foreign_keys')
          .getSingle();
      expect(foreignKeys.read<int>('foreign_keys'), 1);
    } finally {
      await reopened.close();
    }
  });
}
