import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/bbs_board.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/review_mode/review_frames.dart';
import 'package:meshcore_open/review_mode/review_radio.dart';
import 'package:meshcore_open/review_mode/review_script.dart';
import 'package:meshcore_open/services/bbs/bbs_protocol.dart';
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
      ..['!h x'] = guiHelp
      ..['!x 0 0'] = guiSync00
      ..['!x 11 1'] = guiSync111;

    expect(await service.sync(bbs), BbsSyncResult.done);
    expect(radio.received, ['!h x', '!x 0 0', '!x 11 1']);

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
    expect(radio.received, ['!h x', '!h x', '!h x']);
    // One request: the same timestamp, so the BBS can tell a repeat.
    expect(radio.attempts.map((a) => a.$1), [0, 1, 2]);
    expect(radio.attempts.map((a) => a.$2).toSet(), hasLength(1));
  });

  test('a confirmed request is not sent again', () async {
    service.replyTimeout = const Duration(milliseconds: 50);
    expect(await service.sync(bbs), BbsSyncResult.noReply);
    expect(radio.received, ['!h x']);
  });

  test('confirmed requests are sent once each', () async {
    radio.replies
      ..['!h x'] = guiHelp
      ..['!x 0 0'] = guiSync00
      ..['!x 11 1'] = guiSync111;
    expect(await service.sync(bbs), BbsSyncResult.done);
    expect(radio.attempts.map((a) => a.$1), [0, 0, 0]);
  });

  test('a reply cut short is resumed from the last whole record', () async {
    service.replyTimeout = const Duration(milliseconds: 100);
    radio.replies
      ..['!h x'] = guiHelp
      ..['!x 0 0'] = guiSync00.take(2).toList()
      ..['!x 4 0'] = guiSync40;

    expect(await service.sync(bbs), BbsSyncResult.done);
    expect(radio.received, ['!h x', '!x 0 0', '!x 4 0']);
    final ids = (await store.messages(device, _bbsKeyHex)).map((m) => m.id);
    expect(ids.toSet(), {1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13});
    expect((await store.board(device, _bbsKeyHex))!.deletionSeq, 1);
  });

  test('resent parts are taken once and kept out of the chat', () async {
    final chatBefore = chatTexts();
    radio.replies
      ..['!h x'] = guiHelp
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
      ..['!h x'] = ['BBS\n!p ...\nA=ADDRESSES']
      ..['!x 0 0'] = guiSync131;
    expect(await service.sync(bbs), BbsSyncResult.done);
    expect(radio.received, ['!h x', '!x 0 0', '!h x']);
  });

  test('a second call during a sync returns the same sync', () async {
    radio.replies
      ..['!h x'] = guiHelp
      ..['!x 0 0'] = guiSync131;
    final first = service.sync(bbs);
    expect(service.isSyncing(_bbsKeyHex), isTrue);
    expect(identical(service.sync(bbs), first), isTrue);
    await first;
    expect(service.isSyncing(_bbsKeyHex), isFalse);
    expect(radio.received, ['!h x', '!x 0 0']);
  });

  group('compressed replies', () {
    setUp(() => service.compress = true);

    test('a compressed sync stores the same messages', () async {
      final chatBefore = chatTexts();
      radio.replies
        ..['!h x'] = guiHelp
        ..['!x 0 0 z'] = guiZ00
        ..['!x 11 1 z'] = guiZ111;

      expect(await service.sync(bbs), BbsSyncResult.done);
      expect(radio.received, ['!h x', '!x 0 0 z', '!x 11 1 z']);
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
          ..['!h x'] = guiHelp
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
        expect(radio.received, ['!h x', '!x 0 0 z', '!x 4 0 z']);
        final ids = (await store.messages(device, _bbsKeyHex)).map((m) => m.id);
        expect(ids.toSet(), {1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13});
        expect(stages, contains(BbsSyncStage.resuming));
        expect(stages, contains(BbsSyncStage.receiving));
      },
    );

    test('a BBS without compression is asked again without the flag', () async {
      radio.replies
        ..['!h x'] = guiHelp
        ..['!x 0 0 z'] = guiUsage
        ..['!x 0 0'] = guiSync00
        ..['!x 11 1'] = guiSync111
        ..['!x 13 1'] = guiSync131;

      expect(await service.sync(bbs), BbsSyncResult.done);
      expect(await service.sync(bbs), BbsSyncResult.done);
      expect(radio.received, [
        '!h x',
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
        ..['!h x'] = guiHelp
        ..['!x 0 0 z'] = guiZ40;
      expect(await service.sync(bbs), BbsSyncResult.noReply);
      expect(await store.messages(device, _bbsKeyHex), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(chatTexts(), chatBefore);
    });
  });

  test('an older plain reply is not used and stays out of the chat', () async {
    radio.replies
      ..['!h x'] = guiHelp
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
      ..['!h x'] = guiHelp
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
      ..['!h x'] = guiHelp
      ..['!x 0 0'] = [
        guiSync00[0],
        guiSync00[1],
        guiSync00[1], // again, with a new timestamp: ids 3-5 already seen
        ...guiSync00.skip(2),
      ]
      ..['!x 11 1'] = guiSync111;
    expect(await service.sync(bbs), BbsSyncResult.done);
    expect(radio.received, ['!h x', '!x 0 0', '!x 11 1']);
    final board = (await store.board(device, _bbsKeyHex))!;
    expect(board.lastId, 13);
    expect(board.deletionSeq, 1);
    expect(await store.messages(device, _bbsKeyHex), hasLength(12));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(chatTexts(), chatBefore);
  });

  test('the reply window covers two routed tries and one flood', () {
    // meshcore-gui 1.26.4: no minimum wait for a flood.
    expect(
      BbsSyncService.retryWindow(
        const Duration(seconds: 10),
        const Duration(seconds: 8),
        const BbsDeliverySettings(floodMinWait: Duration.zero),
      ),
      const Duration(seconds: 42),
    );
  });

  test('the reply window uses at least the flood minimum wait', () {
    // Defaults (meshcore-gui 1.26.5): (2 x 10 x 1.2 + max(9.6, 30)) x 1.25.
    expect(
      BbsSyncService.retryWindow(
        const Duration(seconds: 10),
        const Duration(seconds: 8),
      ),
      const Duration(milliseconds: 67500),
    );
  });

  test('the reply window follows the delivery settings of the BBS', () {
    // a=4, f=1, w=45 s, k=1.5: (1 x 10 x 1.5 + 3 x max(12, 45)) x 1.25.
    expect(
      BbsSyncService.retryWindow(
        const Duration(seconds: 10),
        const Duration(seconds: 8),
        const BbsDeliverySettings(
          attempts: 4,
          floodAfter: 1,
          floodMinWait: Duration(seconds: 45),
          waitFactor: 1.5,
        ),
      ),
      const Duration(milliseconds: 187500),
    );
  });

  test('left-over sync parts after a sync stay out of the chat', () async {
    radio.replies
      ..['!h x'] = guiHelp
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
      ..['!h x'] = guiHelp
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

  group('delivery settings', () {
    const help = [
      'BBS\n!p [cat] [text] | !r [cat] [1-5] | !s [cat] [query]\n'
          'X|a=4,f=1,w=45,k=1.5\nA=ADDRESSES U=URGENT S=STATUS '
          'ME=MEDICAL MI=MISSING',
    ];

    test('are stored from the !h x reply', () async {
      radio.replies
        ..['!h x'] = help
        ..['!x 0 0'] = guiSync131;
      expect(await service.sync(bbs), BbsSyncResult.done);
      final board = (await store.board(device, _bbsKeyHex))!;
      expect(
        board.delivery,
        const BbsDeliverySettings(
          attempts: 4,
          floodAfter: 1,
          floodMinWait: Duration(seconds: 45),
          waitFactor: 1.5,
          announced: true,
        ),
      );
      expect(board.categories, hasLength(5));
    });

    test('a BBS without the line gets the defaults, asked once', () async {
      radio.replies
        ..['!h x'] = guiHelp
        ..['!x 0 0'] = guiSync131
        ..['!x 0 1'] = guiSync131;
      expect(await service.sync(bbs), BbsSyncResult.done);
      expect(await service.sync(bbs), BbsSyncResult.done);
      expect(radio.received, ['!h x', '!x 0 0', '!x 0 1']);
      final board = (await store.board(device, _bbsKeyHex))!;
      expect(board.delivery, BbsDeliverySettings.defaults);
    });

    test('settings older than a day are asked again', () async {
      await store.saveCategories(device, _bbsKeyHex, const [
        BbsCategory('U', 'URGENT'),
      ]);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await store.saveDelivery(
        device,
        _bbsKeyHex,
        BbsDeliverySettings.defaults.checked(
          now - BbsSyncService.deliveryRefresh.inSeconds,
        ),
      );
      radio.replies
        ..['!h x'] = guiHelp
        ..['!x 0 0'] = guiSync131;
      expect(await service.sync(bbs), BbsSyncResult.done);
      expect(radio.received, ['!h x', '!x 0 0']);
      final checked = (await store.board(device, _bbsKeyHex))!.delivery!;
      expect(checked.checkedAt, greaterThanOrEqualTo(now));
    });

    test('a board without settings asks !h x again', () async {
      await store.saveCategories(device, _bbsKeyHex, const [
        BbsCategory('U', 'URGENT'),
      ]);
      radio.replies
        ..['!h x'] = guiHelp
        ..['!x 0 0'] = guiSync131;
      expect(await service.sync(bbs), BbsSyncResult.done);
      expect(radio.received, ['!h x', '!x 0 0']);
    });
  });

  group('parts after the request', () {
    Future<void> emit(List<String> dms, int timestamp) async {
      for (final dm in dms) {
        radio.emitForTest(
          ReviewFrames.contactMessage(
            senderPublicKey: hexToPubKey(_bbsKeyHex),
            text: dm,
            timestampSecs: timestamp++,
            pathLen: 1,
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    test('a late part of a broken-off reply is applied', () async {
      service.replyTimeout = const Duration(milliseconds: 100);
      final chatBefore = chatTexts();
      radio.replies
        ..['!h x'] = guiHelp
        ..['!x 0 0'] = guiSync00.take(1).toList();
      expect(await service.sync(bbs), BbsSyncResult.incomplete);
      // Record 1 may still continue on a `+1|` line: not whole yet.
      expect((await store.board(device, _bbsKeyHex))!.lastId, 0);

      await emit(guiSync00.skip(1).take(1).toList(), 1800001000);
      // Records 1, 3 and 4 are whole; 5 may still continue.
      expect((await store.board(device, _bbsKeyHex))!.lastId, 4);
      expect(chatTexts(), chatBefore);

      // The next request starts after the late records.
      radio.replies['!x 4 0'] = guiSync131;
      await service.sync(bbs);
      expect(radio.received.last, '!x 4 0');
    });

    test('a late compressed part after one part is applied', () async {
      service
        ..compress = true
        ..replyTimeout = const Duration(milliseconds: 100);
      final chatBefore = chatTexts();
      radio.replies
        ..['!h x'] = guiHelp
        ..['!x 0 0 z'] = guiZ00.take(1).toList();
      expect(await service.sync(bbs), BbsSyncResult.incomplete);
      await emit(guiZ00.skip(1).toList(), 1800006000);
      expect(chatTexts(), chatBefore);
      expect((await store.board(device, _bbsKeyHex))!.lastId, 11);
    });

    test(
      'one late compressed part, long after the window, is applied',
      () async {
        service
          ..compress = true
          ..replyTimeout = const Duration(milliseconds: 100);
        final chatBefore = chatTexts();
        radio.replies
          ..['!h x'] = guiHelp
          ..['!x 0 0 z'] = guiZ00.take(1).toList();
        expect(await service.sync(bbs), BbsSyncResult.incomplete);
        await Future<void>.delayed(const Duration(seconds: 2));
        await emit([guiZ00[1]], 1800006000);
        expect(chatTexts(), chatBefore);
        await Future<void>.delayed(const Duration(seconds: 2));
        await emit([guiZ00[2]], 1800006001);
        expect(chatTexts(), chatBefore);
        expect((await store.board(device, _bbsKeyHex))!.lastId, 11);
      },
    );

    test('a whole compressed reply after the request is applied', () async {
      service
        ..compress = true
        ..replyTimeout = const Duration(milliseconds: 100);
      final chatBefore = chatTexts();
      radio.replies['!h x'] = guiHelp;
      expect(await service.sync(bbs), BbsSyncResult.noReply);
      expect(radio.received.last, '!x 0 0 z');

      await emit(guiZ00, 1800002000);
      final board = (await store.board(device, _bbsKeyHex))!;
      expect(board.lastId, 11);
      expect(board.deletionSeq, 1);
      expect(chatTexts(), chatBefore);
    });

    test('a late copy of a part is taken once', () async {
      service.replyTimeout = const Duration(milliseconds: 100);
      final chatBefore = chatTexts();
      radio.replies['!h x'] = guiHelp;
      // Confirmed, but the reply only comes after the request ended.
      expect(await service.sync(bbs), BbsSyncResult.noReply);
      await emit(guiSync00.take(3).toList(), 1800003000);
      // `+6|…` would continue record 6 a second time without the dedup.
      await emit([guiSync00[3]], 1800003010);
      await emit([guiSync00[3]], 1800003010);
      await emit([guiSync00[4]], 1800003011);
      // Records up to 8 are whole; 9 may still continue.
      expect((await store.board(device, _bbsKeyHex))!.lastId, 8);
      final six = (await store.messages(
        device,
        _bbsKeyHex,
      )).firstWhere((m) => m.id == 6);
      expect('Lange melding'.allMatches(six.text), hasLength(6));
      expect(chatTexts(), chatBefore);
    });

    test('a new request ends the broken-off reply', () async {
      service.replyTimeout = const Duration(milliseconds: 100);
      radio.replies
        ..['!h x'] = guiHelp
        ..['!x 0 0'] = guiSync00.take(1).toList();
      expect(await service.sync(bbs), BbsSyncResult.incomplete);
      radio.replies['!x 0 0'] = <String>[];
      expect(await service.sync(bbs), BbsSyncResult.noReply);
      // A part of the first reply after the second request is not applied.
      await emit(guiSync00.skip(1).take(1).toList(), 1800005000);
      expect((await store.board(device, _bbsKeyHex))!.lastId, 0);
    });

    test('a lost !h x for due settings does not stop the sync', () async {
      service.replyTimeout = const Duration(milliseconds: 50);
      await store.saveCategories(
        device,
        _bbsKeyHex,
        BbsProtocol.parseHelp(guiHelp.join('\n'))!,
      );
      radio.replies['!x 0 0'] = guiSync131;
      expect(await service.sync(bbs), BbsSyncResult.done);
      expect(radio.received, ['!h x', '!x 0 0']);
    });

    test('sync data of a known BBS stays out of the chat later on', () async {
      radio.replies
        ..['!h x'] = guiHelp
        ..['!x 0 0'] = guiSync131;
      expect(await service.sync(bbs), BbsSyncResult.done);
      // A new service has no request history, only the stored board.
      service.dispose();
      service = BbsSyncService(connector, store);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final chatBefore = chatTexts();
      await emit([guiZ40.first, guiSync40.first], 1800004000);
      expect(chatTexts(), chatBefore);
      // A lone base64 part of an older compressed reply as well.
      await emit([guiZ00[1]], 1800004050);
      expect(chatTexts(), chatBefore);
      await emit(['Gewoon bericht van de operator'], 1800004100);
      expect(chatTexts(), contains('Gewoon bericht van de operator'));
    });
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
        ..['!h x'] = guiHelp
        ..['!x 0 0'] = guiSync131;
      final sync = service.sync(bbs);
      final outcome = await service.post(bbs, 'U', 'hoi');
      expect(outcome.result, BbsPostResult.failed);
      await sync;
      expect(radio.received, ['!h x', '!x 0 0']);
    });
  });
}
