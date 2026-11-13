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

enum BbsPostResult {
  /// The BBS stored the message; [BbsPostOutcome.id] holds its id.
  posted,

  /// The BBS answered with an error; [BbsPostOutcome.reply] holds its text.
  rejected,

  /// No confirmation: the message may or may not have been stored.
  noReply,

  /// The radio is not connected, or a sync of this BBS is running.
  failed,
}

class BbsPostOutcome {
  const BbsPostOutcome(this.result, {this.id, this.reply});

  final BbsPostResult result;
  final int? id;
  final String? reply;
}

enum _ReplyKind { help, sync, post }

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
    if (kind == _ReplyKind.post) {
      return chunks.isEmpty && _postReply.hasMatch(chunk);
    }
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
  static final RegExp _postReply = RegExp(
    r'^(?:Posted #|Usage: !p|Unknown category)',
  );

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
    if (kind == _ReplyKind.post) return true;
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
  final Set<String> _posting = {};

  BbsStore get store => _store;

  /// Storage scope of the connected radio (first 10 hex chars of its public
  /// key); `null` before the radio reported it.
  String? get deviceKey {
    final self = _connector.selfPublicKeyHex;
    return self.length >= 10 ? self.substring(0, 10) : null;
  }

  bool isSyncing(String bbsKey) => _running.containsKey(bbsKey);

  bool isPosting(String bbsKey) => _posting.contains(bbsKey);

  /// Posts [text] in the category with [abbreviation] with `!p`. Sent once:
  /// `!p` is not idempotent, so a lost confirmation must not lead to a
  /// second copy. Line breaks are sent as spaces, as the BBS shows them.
  Future<BbsPostOutcome> post(
    Contact bbs,
    String abbreviation,
    String text,
  ) async {
    final key = bbs.publicKeyHex;
    if (isSyncing(key) || isPosting(key)) {
      return const BbsPostOutcome(BbsPostResult.failed);
    }
    _posting.add(key);
    notifyListeners();
    try {
      final reply = await _request(
        bbs,
        BbsProtocol.postCommand(abbreviation, postText(text)),
        _ReplyKind.post,
        attempts: 1,
      );
      if (reply == null) return const BbsPostOutcome(BbsPostResult.noReply);
      final id = BbsProtocol.parsePostedId(reply);
      if (id == null) {
        return BbsPostOutcome(BbsPostResult.rejected, reply: reply);
      }
      await _savePostPath(key, id, bbs);
      return BbsPostOutcome(BbsPostResult.posted, id: id, reply: reply);
    } on RadioNotConnectedException {
      return const BbsPostOutcome(BbsPostResult.failed);
    } on Exception catch (error) {
      appLogger.warn('BBS post failed: $error', tag: 'BBS');
      return const BbsPostOutcome(BbsPostResult.failed);
    } finally {
      _posting.remove(key);
      notifyListeners();
    }
  }

  /// Links message [id] to the route the `!p` took: the route the radio now
  /// holds for the BBS node, as a DM in the chat stores it. Read after the
  /// reply, so a route learned from the path return of this `!p` counts. A
  /// failure only costs the route, not the post.
  Future<void> _savePostPath(String bbsKey, int id, Contact fallback) async {
    final device = deviceKey;
    if (device == null) return;
    final contact = _connector.contacts.firstWhere(
      (c) => c.publicKeyHex == bbsKey,
      orElse: () => fallback,
    );
    final flood = contact.pathLength < 0;
    try {
      await _store.savePostPath(
        device,
        bbsKey,
        id,
        pathLength: flood ? -1 : contact.pathLength,
        pathHashWidth: contact.pathHashWidth,
        pathBytes: flood ? const <int>[] : contact.path,
      );
    } on Exception catch (error) {
      appLogger.warn('BBS post path not stored: $error', tag: 'BBS');
    }
  }

  /// [text] as `!p` sends it: one line, trimmed.
  static String postText(String text) =>
      text.split(RegExp(r'[\r\n]+')).map((l) => l.trim()).join(' ').trim();

  BbsSyncResult? lastResult(String bbsKey) => _lastResult[bbsKey];

  /// Fetches new messages from [bbs]. Categories are fetched with `!h` when
  /// [refreshCategories] is set, when none are known yet, or when the BBS
  /// reports a category the app does not know. A second call while a sync
  /// of the same BBS runs returns that sync.
  Future<BbsSyncResult> sync(Contact bbs, {bool refreshCategories = false}) {
    final key = bbs.publicKeyHex;
    final running = _running[key];
    if (running != null) return running;
    if (isPosting(key)) return Future.value(BbsSyncResult.failed);
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

  /// Sends [command] up to [attempts] times and returns the reply text
  /// (all parts joined with `\n`, possibly partial), or `null` when no part
  /// arrived.
  Future<String?> _request(
    Contact bbs,
    String command,
    _ReplyKind kind, {
    int attempts = maxAttempts,
  }) async {
    final key = bbs.publicKeyHex;
    final pending = _PendingReply(kind);
    _pending[key] = pending;
    try {
      for (var attempt = 0; attempt < attempts; attempt++) {
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
