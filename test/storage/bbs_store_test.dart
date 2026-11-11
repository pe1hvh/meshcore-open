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
        'X1|$epoch|1|0|0|0|2\nR|*:90\n2|1762850060|A||PE1HVH|Noodpost',
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
    const posted = 1762850000;

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
}
