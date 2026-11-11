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
import 'package:meshcore_open/models/contact.dart';
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

  Future<void> open(WidgetTester tester, {bool withBoard = true}) async {
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
    service = BbsSyncService(connector, store);
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
}
