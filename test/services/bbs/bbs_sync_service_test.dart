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

  /// DMs sent twice, as the BBS does after a lost ACK.
  final Set<String> resend = {};
  var _timestamp = 1800000000;

  @override
  void handle(Uint8List frame) {
    super.handle(frame);
    if (frame.isEmpty || frame[0] != cmdSendTxtMsg || frame.length < 13) {
      return;
    }
    if (pubKeyToHex(frame.sublist(7, 13)) != _bbsKeyHex.substring(0, 12)) {
      return;
    }
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
    radio.resend.clear();
    store = await SqliteBbsStore.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfiNoIsolate,
    );
    service = BbsSyncService(connector, store)
      ..replyTimeout = const Duration(milliseconds: 300);
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

  test('a silent BBS gives noReply after three requests', () async {
    service.replyTimeout = const Duration(milliseconds: 50);
    expect(await service.sync(bbs), BbsSyncResult.noReply);
    expect(radio.received, ['!h', '!h', '!h']);
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
