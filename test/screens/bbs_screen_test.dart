import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/bbs_board.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/path_selection.dart';
import 'package:meshcore_open/screens/bbs_screen.dart';
import 'package:meshcore_open/services/bbs/bbs_protocol.dart';
import 'package:meshcore_open/services/bbs/bbs_sync_service.dart';
import 'package:meshcore_open/storage/bbs_store_io.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/theme/mesh_theme.dart';

import '../services/bbs/meshcore_gui_replies.dart';

const _selfKey =
    'ee5e04b332b386b6cce8355ccf27fffd3a98b7a7a5b9b3a550c039c6ebae38e4';
const _bbsKey =
    'a95db5b0ac159e4384ff55ef91c94a98dc563d66a88e7b027fcd5190c0f5bed5';

/// A radio that is not connected but knows its own key, so the screen shows
/// the stored board read-only and starts no sync.
class _OfflineConnector extends MeshCoreConnector {
  @override
  String get selfPublicKeyHex => _selfKey;
}

/// A connected radio that records the DM texts the app sends and never
/// answers, so a sync or post ends without reply.
class _SilentConnector extends _OfflineConnector {
  final List<String> sent = [];

  @override
  bool get isConnected => true;

  @override
  Future<PathSelection> preparePathForContactSend(Contact contact) async =>
      const PathSelection(pathBytes: [], hopCount: 0, useFlood: false);

  @override
  Future<void> sendFrame(
    Uint8List data, {
    String? channelSendQueueId,
    bool expectsGenericAck = false,
    bool waitForGenericAck = false,
  }) async {
    if (data.isNotEmpty && data[0] == cmdSendTxtMsg) {
      var end = data.length;
      while (end > 13 && data[end - 1] == 0) {
        end--;
      }
      sent.add(utf8.decode(data.sublist(13, end)));
    }
  }
}

Contact _contact() => Contact(
  publicKey: hexToPubKey(_bbsKey),
  name: 'NNO BBS',
  type: advTypeChat,
  pathLength: 1,
  path: Uint8List.fromList([0xa1]),
  lastSeen: DateTime(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _OfflineConnector connector;
  late SqliteBbsStore store;
  late BbsSyncService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    sqfliteFfiInit();
    connector = _OfflineConnector();
  });

  Future<void> open(
    WidgetTester tester, {
    bool withBoard = true,
    _OfflineConnector? radio,
  }) async {
    if (radio != null) connector = radio;
    await tester.runAsync(() async {
      store = await SqliteBbsStore.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfiNoIsolate,
      );
      if (withBoard) {
        final device = _selfKey.substring(0, 10);
        await store.saveCategories(
          device,
          _bbsKey,
          BbsProtocol.parseHelp(guiHelp.join('\n'))!,
        );
        for (final reply in [guiSync00, guiSync100]) {
          await store.applySync(
            device,
            _bbsKey,
            BbsProtocol.parseSync(reply.join('\n'))!,
            syncedAt: 1,
          );
        }
      }
    });
    service = BbsSyncService(connector, store)
      ..replyTimeout = const Duration(milliseconds: 10);
    addTearDown(() async {
      service.dispose();
      await tester.runAsync(store.close);
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MeshCoreConnector>.value(value: connector),
          ChangeNotifierProvider<BbsSyncService?>.value(value: service),
        ],
        child: MaterialApp(
          theme: MeshTheme.light(),
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: BbsScreen(contact: _contact()),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('one tab for all messages and one per category', (tester) async {
    await open(tester);
    expect(find.text('BBS · NNO BBS'), findsOneWidget);
    for (final tab in [
      'All',
      'ADDRESSES',
      'URGENT',
      'STATUS',
      'MEDICAL',
      'MISSING',
    ]) {
      expect(find.widgetWithText(Tab, tab), findsOneWidget);
    }
    // Newest first; the All tab names each message's category.
    expect(find.text('${'x' * 135} woord'), findsOneWidget);
    expect(find.text('Vermist bericht 12'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('${'x' * 135} woord')).dy,
      lessThan(tester.getTopLeft(find.text('Vermist bericht 12')).dy),
    );
    expect(find.text('STATUS'), findsWidgets);
  });

  testWidgets('a category tab shows its messages and retention', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.widgetWithText(Tab, 'URGENT'));
    await tester.pumpAndSettle();
    expect(find.text('Dijk Zwolle-Zuid lekt bij gemaal'), findsOneWidget);
    expect(find.text('Vermist bericht 12'), findsNothing);
    expect(find.text('Kept 90 days'), findsOneWidget);

    await tester.tap(find.widgetWithText(Tab, 'ADDRESSES'));
    await tester.pumpAndSettle();
    expect(find.text('Kept forever'), findsOneWidget);
    // Message 2 was deleted by the operator.
    expect(find.text('No messages'), findsOneWidget);
  });

  testWidgets('without a board and radio the screen offers a retry', (
    tester,
  ) async {
    await open(tester, withBoard: false);
    expect(find.text('No reply from the BBS'), findsOneWidget);
    final retry = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Retry'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(retry.onPressed, isNull);
  });

  testWidgets('bbsAvailable needs the sync service', (tester) async {
    late bool withService;
    late bool without;
    await tester.runAsync(() async {
      store = await SqliteBbsStore.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfiNoIsolate,
      );
    });
    service = BbsSyncService(connector, store);
    addTearDown(() async {
      service.dispose();
      await tester.runAsync(store.close);
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<BbsSyncService?>.value(
        value: service,
        child: Builder(
          builder: (context) {
            withService = bbsAvailable(context);
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          without = bbsAvailable(context);
          return const SizedBox();
        },
      ),
    );
    expect(withService, isTrue);
    expect(without, isFalse);
  });

  testWidgets('offline there is no Post button', (tester) async {
    await open(tester);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('Post sends !p in the category of the open tab', (tester) async {
    final radio = _SilentConnector();
    await open(tester, radio: radio);
    await tester.tap(find.widgetWithText(Tab, 'STATUS'));
    await tester.pumpAndSettle();
    radio.sent.clear();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('Post to the BBS'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DropdownButtonFormField<BbsCategory>),
        matching: find.text('STATUS'),
      ),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), 'Repeater Hattem\nonline');
    await tester.pump();
    // "!p S Repeater Hattem online" is 27 bytes.
    expect(find.text('27 / ${maxContactMessageBytes()}'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Post'));
    final noConfirmation = find.textContaining('No confirmation from the BBS');
    for (var i = 0; i < 20 && noConfirmation.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(radio.sent.first, '!p S Repeater Hattem online');
    expect(noConfirmation, findsOneWidget);
    // The sync that follows does not post again.
    await tester.pumpAndSettle();
    expect(radio.sent.where((t) => t.startsWith('!p')), hasLength(1));
    expect(radio.sent.skip(1), everyElement(startsWith('!x')));
  });
}
