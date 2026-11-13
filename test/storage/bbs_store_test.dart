import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/bbs/bbs_protocol.dart';
import 'package:meshcore_open/storage/bbs_store_io.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../services/bbs/meshcore_gui_replies.dart';

const device = '0123456789';
final bbs = 'ab' * 32;
const day = 86400;

final epoch = guiSync00.first.split('|')[1];

BbsSyncReply sync(List<String> dms) => BbsProtocol.parseSync(dms.join('\n'))!;

void main() {
  late SqliteBbsStore store;

  setUp(() async {
    sqfliteFfiInit();
    store = await SqliteBbsStore.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfiNoIsolate,
    );
    await store.saveCategories(
      device,
      bbs,
      BbsProtocol.parseHelp(guiHelp.join('\n'))!,
    );
  });

  tearDown(() => store.close());

  test('a full sync stores messages and advances both cursors', () async {
    expect(
      await store.applySync(device, bbs, sync(guiSync00), syncedAt: 1),
      isTrue,
    );
    expect(
      await store.applySync(device, bbs, sync(guiSync100), syncedAt: 2),
      isTrue,
    );

    final board = (await store.board(device, bbs))!;
    expect(board.epoch, epoch);
    expect(board.lastId, 13);
    expect(board.deletionSeq, 1);
    expect(board.lastSync, 2);
    expect(board.retentionDaysFor('ADDRESSES'), 0);
    expect(board.retentionDaysFor('STATUS'), 30);

    final all = await store.messages(device, bbs);
    expect(all.map((m) => m.id), [13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 1]);
    final missing = await store.messages(device, bbs, category: 'MISSING');
    expect(missing.map((m) => m.id), [12, 11, 10, 9, 8, 7]);
    expect(
      (await store.messages(device, bbs, category: 'OLD')).single.text,
      'Bericht in vervallen categorie',
    );
  });

  test('a repeated record is stored once', () async {
    await store.applySync(device, bbs, sync(guiSync00), syncedAt: 1);
    await store.applySync(device, bbs, sync(guiSync00), syncedAt: 2);
    expect(await store.messages(device, bbs), hasLength(10));
  });

  test('operator deletions remove a stored message', () async {
    await store.applySync(
      device,
      bbs,
      BbsProtocol.parseSync(
        'X1|$epoch|1|0|0|0|2\nR|*:90\n2|4102444860|A||PE1HVH|Noodpost',
      )!,
      syncedAt: 1,
    );
    expect(await store.messages(device, bbs), hasLength(1));
    final reply = BbsProtocol.parseSync('X1|$epoch|0|0|1|1|2\nR|*:90\n-2')!;
    await store.applySync(device, bbs, reply, syncedAt: 3);
    expect(await store.messages(device, bbs), isEmpty);
    expect((await store.board(device, bbs))!.deletionSeq, 1);
  });

  test('a cut-off reply keeps the deletion cursor and last sync', () async {
    await store.applySync(
      device,
      bbs,
      sync(guiSync00.take(2).toList()),
      syncedAt: 5,
    );
    final board = (await store.board(device, bbs))!;
    expect(board.lastId, 4);
    expect(board.deletionSeq, 0);
    expect(board.lastSync, isNull);
  });

  test('a new epoch discards the local copy', () async {
    await store.applySync(device, bbs, sync(guiSync00), syncedAt: 1);
    final restarted = BbsProtocol.parseSync(
      'X1|1800000000|1|0|0|0|2\nR|*:90\n1|1800000000|U||PE1HVH|Nieuw',
    )!;
    expect(await store.applySync(device, bbs, restarted, syncedAt: 2), isFalse);

    final board = (await store.board(device, bbs))!;
    expect(board.epoch, '1800000000');
    expect(board.lastId, 0);
    expect(board.deletionSeq, 0);
    expect(board.categories, isNotEmpty);
    expect(await store.messages(device, bbs), isEmpty);
  });

  test('purge follows the retention per category', () async {
    await store.applySync(device, bbs, sync(guiSync00), syncedAt: 1);
    await store.applySync(device, bbs, sync(guiSync100), syncedAt: 1);
    const posted = 4102444800;

    expect(await store.purgeExpired(device, bbs, now: posted + 29 * day), 0);
    // STATUS (30 days) goes first; ADDRESSES (0) is kept forever.
    expect(await store.purgeExpired(device, bbs, now: posted + 31 * day), 3);
    final purged = await store.purgeExpired(
      device,
      bbs,
      now: posted + 999 * day,
    );
    expect(purged, 9);
    // Message 2 (ADDRESSES) was deleted by the operator, so nothing is left.
    expect(await store.messages(device, bbs), isEmpty);
  });

  test('ADDRESSES survives every purge', () async {
    await store.applySync(
      device,
      bbs,
      BbsProtocol.parseSync(
        'X1|1|1|0|0|0|2\nR|*:90,A:0\n1|1000|A||PE1HVH|Wijkcentrum',
      )!,
      syncedAt: 1,
    );
    expect(await store.purgeExpired(device, bbs, now: 1000 + 9999 * day), 0);
    expect(await store.messages(device, bbs), hasLength(1));
  });

  test('boards are separated per radio and per BBS node', () async {
    await store.applySync(device, bbs, sync(guiSync00), syncedAt: 1);
    expect(await store.messages('9999999999', bbs), isEmpty);
    expect(await store.messages(device, 'cd' * 32), isEmpty);
    expect(await store.board('9999999999', bbs), isNull);
  });

  group('post paths', () {
    Future<void> savePath(int id) => store.savePostPath(
      device,
      bbs,
      id,
      pathLength: 2,
      pathHashWidth: 1,
      pathBytes: const [0x1a, 0x2b],
    );

    test('a path saved before the sync is joined to its message', () async {
      await savePath(5);
      await store.applySync(device, bbs, sync(guiSync00), syncedAt: 1);
      final messages = await store.messages(device, bbs);
      final own = messages.singleWhere((m) => m.id == 5);
      expect(own.hasPath, isTrue);
      expect(own.pathLength, 2);
      expect(own.pathHashWidth, 1);
      expect(own.pathBytes, [0x1a, 0x2b]);
      expect(messages.where((m) => m.hasPath), hasLength(1));
    });

    test('a flood post keeps its path length without bytes', () async {
      await store.savePostPath(
        device,
        bbs,
        5,
        pathLength: -1,
        pathHashWidth: 1,
        pathBytes: const [],
      );
      await store.applySync(device, bbs, sync(guiSync00), syncedAt: 1);
      final own = (await store.messages(
        device,
        bbs,
      )).singleWhere((m) => m.id == 5);
      expect(own.pathLength, -1);
      expect(own.pathBytes, isEmpty);
    });

    test('a resynced record keeps its path', () async {
      await savePath(5);
      await store.applySync(device, bbs, sync(guiSync00), syncedAt: 1);
      await store.applySync(device, bbs, sync(guiSync00), syncedAt: 2);
      final own = (await store.messages(
        device,
        bbs,
      )).singleWhere((m) => m.id == 5);
      expect(own.hasPath, isTrue);
    });

    test('an operator deletion removes the path', () async {
      await savePath(2);
      await store.applySync(
        device,
        bbs,
        BbsProtocol.parseSync('X1|$epoch|0|0|1|1|2\nR|*:90\n-2')!,
        syncedAt: 1,
      );
      await store.applySync(
        device,
        bbs,
        BbsProtocol.parseSync(
          'X1|$epoch|1|0|0|0|2\nR|*:90\n2|4102444860|A||PE1HVH|Terug',
        )!,
        syncedAt: 2,
      );
      expect((await store.messages(device, bbs)).single.hasPath, isFalse);
    });

    test('a new epoch discards the paths', () async {
      await store.applySync(device, bbs, sync(guiSync00), syncedAt: 1);
      await savePath(1);
      final restarted = BbsProtocol.parseSync(
        'X1|1800000000|1|0|0|0|2\nR|*:90\n1|1800000000|U||PE1HVH|Nieuw',
      )!;
      await store.applySync(device, bbs, restarted, syncedAt: 2);
      await store.applySync(device, bbs, restarted, syncedAt: 3);
      expect((await store.messages(device, bbs)).single.hasPath, isFalse);
    });

    test(
      'purge drops paths of purged messages but keeps waiting ones',
      () async {
        await store.applySync(device, bbs, sync(guiSync00), syncedAt: 1);
        await store.applySync(device, bbs, sync(guiSync100), syncedAt: 1);
        for (final id in [3, 14]) {
          await savePath(id);
        }
        await store.purgeExpired(device, bbs, now: 4102444800 + 999 * day);
        // Message 14 is not synced yet, so its path must survive.
        await store.applySync(
          device,
          bbs,
          BbsProtocol.parseSync(
            'X1|$epoch|1|0|0|1|2\nR|*:90\n14|4102444860|U||PE1HVH|Later',
          )!,
          syncedAt: 2,
        );
        final rows = await store.database.query('bbs_paths');
        expect(rows.map((r) => r['id']), [14]);
        expect((await store.messages(device, bbs)).single.hasPath, isTrue);
      },
    );
  });

  test('a version 1 database gets the paths table', () async {
    final path = '${Directory.systemTemp.createTempSync().path}/bbs_v1.db';
    final v1 = await databaseFactoryFfiNoIsolate.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) => db.execute(
          'CREATE TABLE bbs_messages (device_key TEXT, bbs_key TEXT, '
          'id INTEGER, ts INTEGER, category TEXT, sender TEXT, text TEXT, '
          'read INTEGER NOT NULL DEFAULT 0)',
        ),
      ),
    );
    await v1.close();
    final upgraded = await SqliteBbsStore.open(
      path,
      factory: databaseFactoryFfiNoIsolate,
    );
    await upgraded.savePostPath(
      device,
      bbs,
      1,
      pathLength: 0,
      pathHashWidth: 1,
      pathBytes: const [],
    );
    expect(await upgraded.database.query('bbs_paths'), hasLength(1));
    await upgraded.close();
  });
}
