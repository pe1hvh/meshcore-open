import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import '../models/bbs_board.dart';
import '../models/bbs_message.dart';
import '../services/bbs/bbs_protocol.dart';
import 'bbs_store.dart';

Future<BbsStore?> createBbsStore() async {
  final directory = await getApplicationSupportDirectory();
  final desktop = Platform.isLinux || Platform.isWindows;
  if (desktop) ffi.sqfliteFfiInit();
  return SqliteBbsStore.open(
    '${directory.path}${Platform.pathSeparator}bbs_v1.db',
    factory: desktop ? ffi.databaseFactoryFfi : sqlite.databaseFactory,
  );
}

class SqliteBbsStore extends BbsStore {
  SqliteBbsStore._(this.database);

  static const schemaVersion = 2;
  static const _boardWhere = 'device_key = ? AND bbs_key = ?';
  final sqlite.Database database;

  static Future<SqliteBbsStore> open(
    String path, {
    required sqlite.DatabaseFactory factory,
  }) async {
    final database = await factory.openDatabase(
      path,
      options: sqlite.OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE bbs_boards ('
            'device_key TEXT NOT NULL, bbs_key TEXT NOT NULL, '
            "epoch TEXT NOT NULL DEFAULT '', "
            "categories TEXT NOT NULL DEFAULT '[]', "
            "retention TEXT NOT NULL DEFAULT '{}', "
            'last_id INTEGER NOT NULL DEFAULT 0, '
            'del_seq INTEGER NOT NULL DEFAULT 0, '
            'last_sync INTEGER, '
            'PRIMARY KEY (device_key, bbs_key))',
          );
          await db.execute(
            'CREATE TABLE bbs_messages ('
            'device_key TEXT NOT NULL, bbs_key TEXT NOT NULL, '
            'id INTEGER NOT NULL, ts INTEGER NOT NULL, '
            'category TEXT NOT NULL, sender TEXT NOT NULL, '
            'text TEXT NOT NULL, read INTEGER NOT NULL DEFAULT 0, '
            'PRIMARY KEY (device_key, bbs_key, id))',
          );
          await db.execute(
            'CREATE INDEX idx_bbs_cat '
            'ON bbs_messages(device_key, bbs_key, category, ts)',
          );
          await _createPaths(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) await _createPaths(db);
        },
      ),
    );
    return SqliteBbsStore._(database);
  }

  /// Version 2: routes of this radio's own posts.
  static Future<void> _createPaths(sqlite.Database db) => db.execute(
    'CREATE TABLE bbs_paths ('
    'device_key TEXT NOT NULL, bbs_key TEXT NOT NULL, '
    'id INTEGER NOT NULL, path_len INTEGER NOT NULL, '
    'hash_width INTEGER NOT NULL, path BLOB NOT NULL, '
    'PRIMARY KEY (device_key, bbs_key, id))',
  );

  @override
  Future<BbsBoard?> board(String deviceKey, String bbsKey) =>
      _board(database, deviceKey, bbsKey);

  static Future<BbsBoard?> _board(
    sqlite.DatabaseExecutor db,
    String deviceKey,
    String bbsKey,
  ) async {
    final rows = await db.query(
      'bbs_boards',
      where: _boardWhere,
      whereArgs: [deviceKey, bbsKey],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return BbsBoard(
      epoch: row['epoch'] as String,
      categories: [
        for (final item in jsonDecode(row['categories'] as String) as List)
          BbsCategory.fromJson(item as Map<String, dynamic>),
      ],
      retention: (jsonDecode(row['retention'] as String) as Map).map(
        (key, value) => MapEntry(key as String, value as int),
      ),
      lastId: row['last_id'] as int,
      deletionSeq: row['del_seq'] as int,
      lastSync: row['last_sync'] as int?,
    );
  }

  static Future<void> _ensureBoard(
    sqlite.DatabaseExecutor db,
    String deviceKey,
    String bbsKey,
  ) => db.insert('bbs_boards', {
    'device_key': deviceKey,
    'bbs_key': bbsKey,
  }, conflictAlgorithm: sqlite.ConflictAlgorithm.ignore);

  @override
  Future<void> saveCategories(
    String deviceKey,
    String bbsKey,
    List<BbsCategory> categories,
  ) => database.transaction((txn) async {
    await _ensureBoard(txn, deviceKey, bbsKey);
    await txn.update(
      'bbs_boards',
      {
        'categories': jsonEncode([for (final c in categories) c.toJson()]),
      },
      where: _boardWhere,
      whereArgs: [deviceKey, bbsKey],
    );
  });

  @override
  Future<bool> applySync(
    String deviceKey,
    String bbsKey,
    BbsSyncReply reply, {
    required int syncedAt,
  }) => database.transaction((txn) async {
    await _ensureBoard(txn, deviceKey, bbsKey);
    final board = (await _board(txn, deviceKey, bbsKey))!;
    final boardArgs = [deviceKey, bbsKey];

    if (board.epoch.isNotEmpty && board.epoch != reply.epoch) {
      await txn.delete(
        'bbs_messages',
        where: _boardWhere,
        whereArgs: boardArgs,
      );
      await txn.delete('bbs_paths', where: _boardWhere, whereArgs: boardArgs);
      await txn.update(
        'bbs_boards',
        {
          'epoch': reply.epoch,
          'retention': jsonEncode(reply.retention),
          'last_id': 0,
          'del_seq': 0,
          'last_sync': null,
        },
        where: _boardWhere,
        whereArgs: boardArgs,
      );
      return false;
    }

    final batch = txn.batch();
    var lastId = board.lastId;
    for (final message in reply.messagesFor(board)) {
      // Older Android SQLite lacks upsert; the update keeps the read flag.
      final values = {
        'ts': message.timestamp,
        'category': message.category,
        'sender': message.sender,
        'text': message.text,
      };
      batch.update(
        'bbs_messages',
        values,
        where: '$_boardWhere AND id = ?',
        whereArgs: [deviceKey, bbsKey, message.id],
      );
      batch.insert('bbs_messages', {
        'device_key': deviceKey,
        'bbs_key': bbsKey,
        'id': message.id,
        ...values,
      }, conflictAlgorithm: sqlite.ConflictAlgorithm.ignore);
      if (message.id > lastId) lastId = message.id;
    }
    for (final id in reply.deletedIds) {
      for (final table in const ['bbs_messages', 'bbs_paths']) {
        batch.delete(
          table,
          where: '$_boardWhere AND id = ?',
          whereArgs: [deviceKey, bbsKey, id],
        );
      }
    }
    batch.update(
      'bbs_boards',
      {
        'epoch': reply.epoch,
        'retention': jsonEncode(reply.retention),
        'last_id': lastId,
        if (reply.isComplete && reply.deletionSeq > board.deletionSeq)
          'del_seq': reply.deletionSeq,
        if (reply.isComplete) 'last_sync': syncedAt,
      },
      where: _boardWhere,
      whereArgs: boardArgs,
    );
    await batch.commit(noResult: true);
    return true;
  });

  @override
  Future<void> savePostPath(
    String deviceKey,
    String bbsKey,
    int id, {
    required int pathLength,
    required int pathHashWidth,
    required List<int> pathBytes,
  }) => database.insert('bbs_paths', {
    'device_key': deviceKey,
    'bbs_key': bbsKey,
    'id': id,
    'path_len': pathLength,
    'hash_width': pathHashWidth,
    'path': Uint8List.fromList(pathBytes),
  }, conflictAlgorithm: sqlite.ConflictAlgorithm.replace);

  @override
  Future<List<BbsMessage>> messages(
    String deviceKey,
    String bbsKey, {
    String? category,
  }) async {
    final rows = await database.rawQuery(
      'SELECT m.*, p.path_len, p.hash_width, p.path FROM bbs_messages m '
      'LEFT JOIN bbs_paths p ON p.device_key = m.device_key '
      'AND p.bbs_key = m.bbs_key AND p.id = m.id '
      'WHERE m.device_key = ? AND m.bbs_key = ?'
      '${category == null ? '' : ' AND m.category = ?'} '
      'ORDER BY m.ts DESC, m.id DESC',
      [deviceKey, bbsKey, ?category],
    );
    return [
      for (final row in rows)
        BbsMessage(
          id: row['id'] as int,
          timestamp: row['ts'] as int,
          category: row['category'] as String,
          sender: row['sender'] as String,
          text: row['text'] as String,
          read: row['read'] == 1,
          pathLength: row['path_len'] as int?,
          pathHashWidth: row['hash_width'] as int?,
          pathBytes: row['path'] == null
              ? null
              : Uint8List.fromList(row['path'] as List<int>),
        ),
    ];
  }

  @override
  Future<int> purgeExpired(
    String deviceKey,
    String bbsKey, {
    required int now,
  }) => database.transaction((txn) async {
    final board = await _board(txn, deviceKey, bbsKey);
    if (board == null) return 0;
    final categories = await txn.query(
      'bbs_messages',
      columns: ['category'],
      distinct: true,
      where: _boardWhere,
      whereArgs: [deviceKey, bbsKey],
    );
    var removed = 0;
    for (final row in categories) {
      final category = row['category'] as String;
      final days = board.retentionDaysFor(category);
      if (days == 0) continue;
      removed += await txn.delete(
        'bbs_messages',
        where: '$_boardWhere AND category = ? AND ts < ?',
        whereArgs: [deviceKey, bbsKey, category, now - days * 86400],
      );
    }
    // Routes of messages that are gone; a route above the last synced id
    // waits for its message.
    await txn.delete(
      'bbs_paths',
      where:
          '$_boardWhere AND id <= ? AND id NOT IN '
          '(SELECT id FROM bbs_messages WHERE $_boardWhere)',
      whereArgs: [deviceKey, bbsKey, board.lastId, deviceKey, bbsKey],
    );
    return removed;
  });

  @override
  Future<void> close() => database.close();
}
