import 'dart:convert';
import 'dart:io';

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

  static const schemaVersion = 1;
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
        },
      ),
    );
    return SqliteBbsStore._(database);
  }

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
      batch.delete(
        'bbs_messages',
        where: '$_boardWhere AND id = ?',
        whereArgs: [deviceKey, bbsKey, id],
      );
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
  Future<List<BbsMessage>> messages(
    String deviceKey,
    String bbsKey, {
    String? category,
  }) async {
    final rows = await database.query(
      'bbs_messages',
      where: category == null ? _boardWhere : '$_boardWhere AND category = ?',
      whereArgs: [deviceKey, bbsKey, ?category],
      orderBy: 'ts DESC, id DESC',
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
    return removed;
  });

  @override
  Future<void> close() => database.close();
}
