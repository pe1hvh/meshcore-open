import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/review_mode/review_frames.dart';
import 'package:meshcore_open/review_mode/review_radio.dart';
import 'package:meshcore_open/review_mode/review_script.dart';
import 'package:meshcore_open/services/bbs/bbs_sync_service.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/bbs_store_io.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'meshcore_gui_compressed_replies.dart';
import 'meshcore_gui_replies.dart';

final _bbsKeyHex = ReviewScript.contacts.first.publicKeyHex;

/// A review radio whose first contact answers BBS commands with the DMs in
/// [replies]; a command without an entry gets no answer.
class _BbsRadio extends ReviewRadio {
  _BbsRadio()
    : super(
        scheduledMessageInterval: const Duration(hours: 1),
        ackDelay: const Duration(milliseconds: 5),
        replyDelay: const Duration(hours: 1),
      );

  final Map<String, List<String>> replies = {};
  final List<String> received = [];

  /// Attempt number and timestamp of every command in [received].
  final List<(int, int)> attempts = [];

  /// Leave sends to the BBS unconfirmed: no SENT and no ACK, as when the
  /// BBS node is out of reach.
  bool dropAcks = false;

  /// DMs sent twice, as the BBS does after a lost ACK.
  final Set<String> resend = {};
  var _timestamp = 1800000000;

  @override
  void handle(Uint8List frame) {
    final toBbs =
        frame.length >= 13 &&
        frame[0] == cmdSendTxtMsg &&
        pubKeyToHex(frame.sublist(7, 13)) == _bbsKeyHex.substring(0, 12);
    if (!toBbs || !dropAcks) super.handle(frame);
    if (!toBbs) return;
    attempts.add((frame[2], readUint32LE(frame, 3)));
    var end = frame.length;
    while (end > 13 && frame[end - 1] == 0) {
      end--;
    }
    final command = utf8.decode(frame.sublist(13, end));
    received.add(command);
    final dms = replies[command];
    if (dms == null) return;
    scheduleMicrotask(() {
      for (final dm in dms) {
        final timestamp = _timestamp++;
        for (var copy = 0; copy < (resend.contains(dm) ? 2 : 1); copy++) {
          emitForTest(
            ReviewFrames.contactMessage(
              senderPublicKey: hexToPubKey(_bbsKeyHex),
              text: dm,
              timestampSecs: timestamp,
              pathLen: 1,
            ),
          );
        }
      }
    });
  }
}

Future<void> _waitFor(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for condition');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MeshCoreConnector connector;
  late MessageRetryService retryService;
  late _BbsRadio radio;
  late SqliteBbsStore store;
  late BbsSyncService service;
  late Contact bbs;
  final device = ReviewRadio.storagePrefix;

  // The connector listens to the notification service singleton once, so
  // one connector serves every test in this file.
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    sqfliteFfiInit();
    connector = MeshCoreConnector();
    retryService = MessageRetryService();
    connector.initialize(
      retryService: retryService,
      pathHistoryService: PathHistoryService(StorageService()),
    );
    radio = _BbsRadio();
    connector.reviewRadioFactoryForTest = () => radio;
    await connector.connectReview();
    await _waitFor(
      () => connector.contacts.any((c) => c.publicKeyHex == _bbsKeyHex),
    );
    bbs = connector.contacts.firstWhere((c) => c.publicKeyHex == _bbsKeyHex);
  });

  tearDownAll(() async {
    await connector.disconnect();
    connector.dispose();
    retryService.dispose();
  });

  setUp(() async {
    radio.replies.clear();
    radio.received.clear();
    radio.attempts.clear();
    radio.resend.clear();
    radio.dropAcks = false;
    store = await SqliteBbsStore.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfiNoIsolate,
    );
    service = BbsSyncService(connector, store)
      ..replyTimeout = const Duration(milliseconds: 300)
      ..compress = false;
  });

  tearDown(() async {
    service.dispose();
    await store.close();
  });

  List<String> chatTexts() =>
      connector.getMessages(bbs).map((m) => m.text).toList();

  test('first sync fetches categories and all messages', () async {
    final chatBefore = chatTexts();
    radio.replies
      ..['!h'] = guiHelp
      ..['!x 0 0'] = guiSync00
      ..['!x 11 1'] = guiSync111;

    expect(await service.sync(bbs), BbsSyncResult.done);
    expect(radio.received, ['!h', '!x 0 0', '!x 11 1']);

    final board = (await store.board(device, _bbsKeyHex))!;
    expect(board.categories.map((c) => c.name), [
      'ADDRESSES',
      'URGENT',
      'STATUS',
      'MEDICAL',
      'MISSING',
    ]);
    expect(board.lastId, 13);
    expect(board.deletionSeq, 1);
    final messages = await store.messages(device, _bbsKeyHex);
    expect(messages, hasLength(12));
    expect(messages.first.text, '${'x' * 135} woord');
    expect(chatTexts(), chatBefore);
    expect(service.lastResult(_bbsKeyHex), BbsSyncResult.done);
  });

  test('an unreachable BBS gives noReply after three attempts', () async {
    service.replyTimeout = const Duration(milliseconds: 50);
    radio.dropAcks = true;
    expect(await service.sync(bbs), BbsSyncResult.noReply);
    expect(radio.received, ['!h', '!h', '!h']);
    // One request: the same timestamp, so the BBS can tell a repeat.
    expect(radio.attempts.map((a) => a.$1), [0, 1, 2]);
    expect(radio.attempts.map((a) => a.$2).toSet(), hasLength(1));
  });

  test('a confirmed request is not sent again', () async {
    service.replyTimeout = const Duration(milliseconds: 50);
    expect(await service.sync(bbs), BbsSyncResult.noReply);
    expect(radio.received, ['!h']);
  });

  test('confirmed requests are sent once each', () async {
    radio.replies
      ..['!h'] = guiHelp
      ..['!x 0 0'] = guiSync00
      ..['!x 11 1'] = guiSync111;
    expect(await service.sync(bbs), BbsSyncResult.done);
    expect(radio.attempts.map((a) => a.$1), [0, 0, 0]);
  });

  test('a reply cut short is resumed from the last whole record', () async {
    service.replyTimeout = const Duration(milliseconds: 100);
    radio.replies
      ..['!h'] = guiHelp
      ..['!x 0 0'] = guiSync00.take(2).toList()
      ..['!x 4 0'] = guiSync40;

    expect(await service.sync(bbs), BbsSyncResult.done);
    expect(radio.received, ['!h', '!x 0 0', '!x 4 0']);
    final ids = (await store.messages(device, _bbsKeyHex)).map((m) => m.id);
    expect(ids.toSet(), {1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13});
    expect((await store.board(device, _bbsKeyHex))!.deletionSeq, 1);
  });

  test('resent parts are taken once and kept out of the chat', () async {
    final chatBefore = chatTexts();
    radio.replies
      ..['!h'] = guiHelp
      ..['!x 0 0'] = guiSync131;
    radio.resend.addAll([guiHelp.first, guiSync131.first]);

    expect(await service.sync(bbs), BbsSyncResult.done);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(chatTexts(), chatBefore);
  });

  test('other DMs from the BBS node still reach the chat', () async {
    radio.emitForTest(
      ReviewFrames.contactMessage(
        senderPublicKey: hexToPubKey(_bbsKeyHex),
        text: 'Hallo van de operator',
        timestampSecs: 1800000500,
        pathLen: 1,
      ),
    );
    await _waitFor(() => chatTexts().contains('Hallo van de operator'));
  });

  test('categories are fetched again for an unknown abbreviation', () async {
    radio.replies
      ..['!h'] = ['BBS\n!p ...\nA=ADDRESSES']
      ..['!x 0 0'] = guiSync131;
    expect(await service.sync(bbs), BbsSyncResult.done);
    expect(radio.received, ['!h', '!x 0 0', '!h']);
  });

  test('a second call during a sync returns the same sync', () async {
    radio.replies
      ..['!h'] = guiHelp
      ..['!x 0 0'] = guiSync131;
    final first = service.sync(bbs);
    expect(service.isSyncing(_bbsKeyHex), isTrue);
    expect(identical(service.sync(bbs), first), isTrue);
    await first;
    expect(service.isSyncing(_bbsKeyHex), isFalse);
    expect(radio.received, ['!h', '!x 0 0']);
  });

  group('compressed replies', () {
    setUp(() => service.compress = true);

    test('a compressed sync stores the same messages', () async {
      final chatBefore = chatTexts();
      radio.replies
        ..['!h'] = guiHelp
        ..['!x 0 0 z'] = guiZ00
        ..['!x 11 1 z'] = guiZ111;

      expect(await service.sync(bbs), BbsSyncResult.done);
      expect(radio.received, ['!h', '!x 0 0 z', '!x 11 1 z']);
      final board = (await store.board(device, _bbsKeyHex))!;
      expect(board.lastId, 13);
      expect(board.deletionSeq, 1);
      final messages = await store.messages(device, _bbsKeyHex);
      expect(messages, hasLength(12));
      expect(messages.first.text, '${'x' * 135} woord');
      expect(chatTexts(), chatBefore);
    });

    test(
      'a broken compressed reply resumes after the last whole record',
      () async {
        service.replyTimeout = const Duration(milliseconds: 100);
        radio.replies
          ..['!h'] = guiHelp
          ..['!x 0 0 z'] = guiZ00.take(2).toList()
          ..['!x 4 0 z'] = guiZ40;
        final stages = <BbsSyncStage>[];
        void listener() {
          final stage = service.progress(_bbsKeyHex)?.stage;
          if (stage != null && (stages.isEmpty || stages.last != stage)) {
            stages.add(stage);
          }
        }

        service.addListener(listener);
        expect(await service.sync(bbs), BbsSyncResult.done);
        service.removeListener(listener);
        expect(radio.received, ['!h', '!x 0 0 z', '!x 4 0 z']);
        final ids = (await store.messages(device, _bbsKeyHex)).map((m) => m.id);
        expect(ids.toSet(), {1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13});
        expect(stages, contains(BbsSyncStage.resuming));
        expect(stages, contains(BbsSyncStage.receiving));
      },
    );

    test('a BBS without compression is asked again without the flag', () async {
      radio.replies
        ..['!h'] = guiHelp
        ..['!x 0 0 z'] = guiUsage
        ..['!x 0 0'] = guiSync00
        ..['!x 11 1'] = guiSync111
        ..['!x 13 1'] = guiSync131;

      expect(await service.sync(bbs), BbsSyncResult.done);
      expect(await service.sync(bbs), BbsSyncResult.done);
      expect(radio.received, [
        '!h',
        '!x 0 0 z',
        '!x 0 0',
        '!x 11 1',
        '!x 13 1',
      ]);
      expect(await store.messages(device, _bbsKeyHex), hasLength(12));
    });

    test('a compressed reply to another request is not used', () async {
      service.replyTimeout = const Duration(milliseconds: 50);
      final chatBefore = chatTexts();
      radio.replies
        ..['!h'] = guiHelp
        ..['!x 0 0 z'] = guiZ40;
      expect(await service.sync(bbs), BbsSyncResult.noReply);
      expect(await store.messages(device, _bbsKeyHex), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(chatTexts(), chatBefore);
    });
  });

  test('an older plain reply is not used and stays out of the chat', () async {
    radio.replies
      ..['!h'] = guiHelp
      ..['!x 0 0'] = guiSync00
      ..['!x 11 1'] = guiSync111;
    expect(await service.sync(bbs), BbsSyncResult.done);
    final chatBefore = chatTexts();

    service.replyTimeout = const Duration(milliseconds: 50);
    radio.replies['!x 13 1'] = guiSync00;
    expect(await service.sync(bbs), BbsSyncResult.noReply);
    final board = (await store.board(device, _bbsKeyHex))!;
    expect(board.lastId, 13);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(chatTexts(), chatBefore);
  });

  test('a BBS that confirms but never answers gives noReply', () async {
    radio.replies
      ..['!h'] = guiHelp
      ..['!x 0 0'] = guiSync131;
    expect(await service.sync(bbs), BbsSyncResult.done);
    service.replyTimeout = const Duration(milliseconds: 50);
    radio.replies.clear();
    expect(await service.sync(bbs), BbsSyncResult.noReply);
    expect(radio.received.last, '!x 0 1');
  });

  test('a stray part of an older reply is not taken into the reply', () async {
    final chatBefore = chatTexts();
    radio.replies
      ..['!h'] = guiHelp
      ..['!x 0 0'] = [
        guiSync00[0],
        guiSync00[1],
        guiSync00[1], // again, with a new timestamp: ids 3-5 already seen
        ...guiSync00.skip(2),
      ]
      ..['!x 11 1'] = guiSync111;
    expect(await service.sync(bbs), BbsSyncResult.done);
    expect(radio.received, ['!h', '!x 0 0', '!x 11 1']);
    final board = (await store.board(device, _bbsKeyHex))!;
    expect(board.lastId, 13);
    expect(board.deletionSeq, 1);
    expect(await store.messages(device, _bbsKeyHex), hasLength(12));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(chatTexts(), chatBefore);
  });

  test('the reply window covers two routed tries and one flood', () {
    expect(
      BbsSyncService.retryWindow(
        const Duration(seconds: 10),
        const Duration(seconds: 8),
      ),
      const Duration(seconds: 42),
    );
  });

  test('left-over sync parts after a sync stay out of the chat', () async {
    radio.replies
      ..['!h'] = guiHelp
      ..['!x 0 0'] = guiSync131;
    expect(await service.sync(bbs), BbsSyncResult.done);
    final chatBefore = chatTexts();
    radio.emitForTest(
      ReviewFrames.contactMessage(
        senderPublicKey: hexToPubKey(_bbsKeyHex),
        text: guiSync40[3],
        timestampSecs: 1800000600,
        pathLen: 1,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(chatTexts(), chatBefore);
  });

  test('messages are stored while the reply arrives', () async {
    radio.replies
      ..['!h'] = guiHelp
      ..['!x 0 0'] = guiSync00
      ..['!x 11 1'] = guiSync111;
    final revisions = <int>{};
    final totals = <int>{};
    void listener() {
      revisions.add(service.revision(_bbsKeyHex));
      final progress = service.progress(_bbsKeyHex);
      if (progress?.stage == BbsSyncStage.receiving) {
        totals.add(progress!.total);
      }
    }

    service.addListener(listener);
    expect(await service.sync(bbs), BbsSyncResult.done);
    service.removeListener(listener);
    // More than one store step within the first reply of 6 parts.
    expect(revisions.length, greaterThan(2));
    expect(totals, contains(10));
  });

  group('post', () {
    test('a confirmed post returns its id and stays out of the chat', () async {
      final chatBefore = chatTexts();
      radio.replies['!p U Dijk lekt'] = ['Posted #14 [URGENT]: Dijk lekt'];
      final outcome = await service.post(bbs, 'U', 'Dijk lekt');
      expect(outcome.result, BbsPostResult.posted);
      expect(outcome.id, 14);
      expect(radio.received, ['!p U Dijk lekt']);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(chatTexts(), chatBefore);
    });

    test('a confirmed post stores the route to the BBS node', () async {
      radio.replies['!p U Pad'] = ['Posted #15 [URGENT]: Pad'];
      final outcome = await service.post(bbs, 'U', 'Pad');
      expect(outcome.id, 15);
      final rows = await store.database.query('bbs_paths');
      expect(rows, hasLength(1));
      final row = rows.single;
      final contact = connector.contacts.firstWhere(
        (c) => c.publicKeyHex == _bbsKeyHex,
      );
      expect(row['id'], 15);
      expect(row['path_len'], contact.pathLength < 0 ? -1 : contact.pathLength);
      expect(row['hash_width'], contact.pathHashWidth);
    });

    test('a rejected post stores no route', () async {
      radio.replies['!p X nee'] = ["Unknown category 'X'. Valid: U=URGENT"];
      await service.post(bbs, 'X', 'nee');
      expect(await store.database.query('bbs_paths'), isEmpty);
    });

    test('an error reply is passed on', () async {
      const reply = "Unknown category 'X'. Valid: U=URGENT";
      radio.replies['!p X hoi'] = [reply];
      final outcome = await service.post(bbs, 'X', 'hoi');
      expect(outcome.result, BbsPostResult.rejected);
      expect(outcome.reply, reply);
    });

    test('without confirmation the post is not sent again', () async {
      service.replyTimeout = const Duration(milliseconds: 50);
      final outcome = await service.post(bbs, 'U', 'hoi');
      expect(outcome.result, BbsPostResult.noReply);
      expect(radio.received, ['!p U hoi']);
    });

    test('line breaks are sent as spaces', () async {
      radio.replies['!p U regel 1 regel 2'] = ['Posted #3 [URGENT]: x'];
      final outcome = await service.post(bbs, 'U', ' regel 1\n\nregel 2 \n');
      expect(outcome.result, BbsPostResult.posted);
      expect(radio.received, ['!p U regel 1 regel 2']);
    });

    test('no post while a sync runs', () async {
      radio.replies
        ..['!h'] = guiHelp
        ..['!x 0 0'] = guiSync131;
      final sync = service.sync(bbs);
      final outcome = await service.post(bbs, 'U', 'hoi');
      expect(outcome.result, BbsPostResult.failed);
      await sync;
      expect(radio.received, ['!h', '!x 0 0']);
    });
  });
}
