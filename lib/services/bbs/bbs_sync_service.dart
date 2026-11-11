import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../connector/meshcore_connector.dart';
import '../../connector/meshcore_protocol.dart';
import '../../models/bbs_board.dart';
import '../../models/contact.dart';
import '../../models/message.dart';
import '../../storage/bbs_store.dart';
import '../../utils/app_logger.dart';
import 'bbs_protocol.dart';

enum BbsSyncResult {
  /// All new messages are in the local copy.
  done,

  /// A reply stayed incomplete; the next sync resumes from the cursors.
  incomplete,

  /// The BBS did not answer: not on its whitelist, or out of reach.
  noReply,

  /// The radio is not connected or a reply could not be read.
  failed,
}

enum _ReplyKind { help, sync }

/// Collects the DMs of one reply. The BBS sends the next DM only after the
/// ACK of the previous one, so parts arrive in order.
class _PendingReply {
  _PendingReply(this.kind);

  final _ReplyKind kind;
  final List<String> chunks = [];

  /// `timestamp|text` of every accepted DM; a part the BBS resends after a
  /// lost ACK keeps its timestamp.
  final Set<String> seen = {};
  Completer<String?>? _waiter;
  Timer? _timer;
  Duration _partTimeout = Duration.zero;
  bool _complete = false;

  String get text => chunks.join('\n');

  bool accepts(String chunk) {
    if (kind == _ReplyKind.help) {
      return chunks.isNotEmpty || chunk.split('\n').first.trim() == 'BBS';
    }
    if (chunks.isEmpty) {
      return chunk.startsWith('${BbsProtocol.syncHeaderTag}|') ||
          chunk.startsWith('Usage: !x');
    }
    return chunk.split('\n').every(_syncLine.hasMatch);
  }

  static final RegExp _syncLine = RegExp(r'^(?:[0-9+\-]|R\|)');

  void add(String chunk) {
    chunks.add(chunk);
    _complete = _isComplete();
    if (_complete) {
      _finish(text);
    } else {
      _arm(_partTimeout);
    }
  }

  bool _isComplete() {
    if (kind == _ReplyKind.help) {
      return BbsProtocol.parseHelp(text)?.isNotEmpty ?? false;
    }
    try {
      return BbsProtocol.parseSync(text)?.isComplete ?? true;
    } on FormatException {
      return true;
    }
  }

  /// The reply, possibly partial, or `null` when nothing arrived within
  /// [first]; after the first part each next part may take [part].
  Future<String?> wait(Duration first, Duration part) {
    _partTimeout = part;
    if (_complete) return Future.value(text);
    final waiter = _waiter = Completer<String?>();
    _arm(chunks.isEmpty ? first : part);
    return waiter.future;
  }

  void _arm(Duration timeout) {
    _timer?.cancel();
    _timer = Timer(timeout, () => _finish(chunks.isEmpty ? null : text));
  }

  void _finish(String? value) {
    _timer?.cancel();
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete(value);
  }

  void cancel() => _finish(null);
}

/// Keeps the local copy of meshcore-gui BBS boards up to date with `!h`
/// and `!x` over DM. Replies are taken from the connector before they reach
/// the chat, so they cost no unread count or notification.
class BbsSyncService extends ChangeNotifier {
  BbsSyncService(this._connector, this._store) {
    _connector.addContactMessageInterceptor(_claim);
  }

  final MeshCoreConnector _connector;
  final BbsStore _store;

  /// Requests per command before the BBS counts as not answering.
  static const int maxAttempts = 3;

  /// Wait for a next part, in multiples of the first-reply timeout: the BBS
  /// resends a part up to three times before it gives up.
  static const int partTimeoutFactor = 3;

  /// `!x` requests per sync, a guard against a BBS that keeps resetting.
  static const int maxRounds = 100;

  /// Replaces the path-based reply timeout in tests.
  @visibleForTesting
  Duration? replyTimeout;

  final Map<String, _PendingReply> _pending = {};
  final Map<String, Set<String>> _lastSeen = {};
  final Map<String, Future<BbsSyncResult>> _running = {};
  final Map<String, BbsSyncResult> _lastResult = {};

  BbsStore get store => _store;

  /// Storage scope of the connected radio (first 10 hex chars of its public
  /// key); `null` before the radio reported it.
  String? get deviceKey {
    final self = _connector.selfPublicKeyHex;
    return self.length >= 10 ? self.substring(0, 10) : null;
  }

  bool isSyncing(String bbsKey) => _running.containsKey(bbsKey);

  BbsSyncResult? lastResult(String bbsKey) => _lastResult[bbsKey];

  /// Fetches new messages from [bbs]. Categories are fetched with `!h` when
  /// [refreshCategories] is set, when none are known yet, or when the BBS
  /// reports a category the app does not know. A second call while a sync
  /// of the same BBS runs returns that sync.
  Future<BbsSyncResult> sync(Contact bbs, {bool refreshCategories = false}) {
    final key = bbs.publicKeyHex;
    final running = _running[key];
    if (running != null) return running;
    final future = _sync(bbs, refreshCategories)
        .then((result) => _lastResult[key] = result)
        .whenComplete(() {
          _running.remove(key);
          notifyListeners();
        });
    _running[key] = future;
    notifyListeners();
    return future;
  }

  Future<BbsSyncResult> _sync(Contact bbs, bool refreshCategories) async {
    final device = deviceKey;
    if (device == null) return BbsSyncResult.failed;
    final key = bbs.publicKeyHex;
    try {
      var board = await _store.board(device, key) ?? const BbsBoard();
      if (refreshCategories || board.categories.isEmpty) {
        if (!await _fetchCategories(bbs, device)) return BbsSyncResult.noReply;
      }
      var categoriesChecked = false;
      for (var round = 0; round < maxRounds; round++) {
        board = await _store.board(device, key) ?? const BbsBoard();
        final text = await _request(
          bbs,
          BbsProtocol.syncCommand(board.lastId, board.deletionSeq),
          _ReplyKind.sync,
        );
        if (text == null) return BbsSyncResult.noReply;
        final reply = BbsProtocol.parseSync(text);
        if (reply == null) {
          appLogger.warn('BBS sync refused: $text', tag: 'BBS');
          return BbsSyncResult.failed;
        }
        if (!categoriesChecked && _hasUnknownCategory(board, reply)) {
          categoriesChecked = true;
          if (!await _fetchCategories(bbs, device)) {
            return BbsSyncResult.noReply;
          }
        }
        final sameEpoch = await _store.applySync(
          device,
          key,
          reply,
          syncedAt: _nowSeconds,
        );
        if (!sameEpoch) continue;
        if (!reply.isComplete) {
          if (reply.records.isEmpty) return BbsSyncResult.incomplete;
          continue;
        }
        if (!reply.more) {
          await _store.purgeExpired(device, key, now: _nowSeconds);
          return BbsSyncResult.done;
        }
      }
      return BbsSyncResult.incomplete;
    } on FormatException catch (error) {
      appLogger.warn('BBS reply unreadable: $error', tag: 'BBS');
      return BbsSyncResult.failed;
    } on RadioNotConnectedException {
      return BbsSyncResult.failed;
    } on Exception catch (error) {
      appLogger.warn('BBS sync failed: $error', tag: 'BBS');
      return BbsSyncResult.failed;
    }
  }

  Future<bool> _fetchCategories(Contact bbs, String device) async {
    final text = await _request(bbs, BbsProtocol.helpCommand, _ReplyKind.help);
    final categories = text == null ? null : BbsProtocol.parseHelp(text);
    if (categories == null) return false;
    await _store.saveCategories(device, bbs.publicKeyHex, categories);
    return true;
  }

  static bool _hasUnknownCategory(BbsBoard board, BbsSyncReply reply) {
    final known = {for (final c in board.categories) c.abbreviation};
    return reply.retention.keys.any(
      (abbreviation) =>
          abbreviation != BbsBoard.otherCategories &&
          !known.contains(abbreviation),
    );
  }

  /// Sends [command] up to [maxAttempts] times and returns the reply text
  /// (all parts joined with `\n`, possibly partial), or `null` when no part
  /// arrived.
  Future<String?> _request(Contact bbs, String command, _ReplyKind kind) async {
    final key = bbs.publicKeyHex;
    final pending = _PendingReply(kind);
    _pending[key] = pending;
    try {
      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        final timeout = await _send(bbs, command, attempt);
        final reply = await pending.wait(timeout, timeout * partTimeoutFactor);
        if (reply != null) return reply;
      }
      return null;
    } finally {
      pending.cancel();
      if (identical(_pending[key], pending)) _pending.remove(key);
      _lastSeen[key] = pending.seen;
    }
  }

  Future<Duration> _send(Contact bbs, String command, int attempt) async {
    final selection = await _connector.preparePathForContactSend(bbs);
    await _connector.sendFrame(
      buildSendTextMsgFrame(
        bbs.publicKey,
        command,
        attempt: attempt,
        timestampSeconds: _nowSeconds,
      ),
    );
    return replyTimeout ??
        Duration(
          milliseconds: _connector.calculateTimeout(
            pathLength: selection.useFlood ? -1 : selection.hopCount,
            messageBytes: maxFrameSize,
            contactKey: bbs.publicKeyHex,
          ),
        );
  }

  /// Takes the DMs of a reply in progress, and late copies of parts that
  /// were already taken, away from the chat.
  bool _claim(Message message) {
    if (message.isCli) return false;
    final key = message.senderKeyHex;
    final id = '${message.timestamp.millisecondsSinceEpoch}|${message.text}';
    final pending = _pending[key];
    if (pending == null) return _lastSeen[key]?.contains(id) ?? false;
    if (pending.seen.contains(id)) return true;
    if (!pending.accepts(message.text)) return false;
    pending.seen.add(id);
    pending.add(message.text);
    return true;
  }

  static int get _nowSeconds => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  @override
  void dispose() {
    _connector.removeContactMessageInterceptor(_claim);
    for (final pending in _pending.values) {
      pending.cancel();
    }
    _pending.clear();
    super.dispose();
  }
}
