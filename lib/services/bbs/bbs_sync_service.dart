import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../connector/meshcore_connector.dart';
import '../../connector/meshcore_protocol.dart';
import '../../models/bbs_board.dart';
import '../../models/contact.dart';
import '../../models/message.dart';
import '../../storage/bbs_store.dart';
import '../../utils/app_logger.dart';
import '../message_retry_service.dart';
import 'bbs_inflate.dart';
import 'bbs_protocol.dart';

enum BbsSyncResult {
  /// All new messages are in the local copy.
  done,

  /// A reply stayed incomplete; the next sync resumes from the cursors.
  incomplete,

  /// The BBS did not answer: its node did not confirm the request (out of
  /// reach), or confirmed it but sent no reply (not on its whitelist, or
  /// meshcore-gui not running).
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

/// Where a running request to a BBS is, for the progress line on screen.
enum BbsSyncStage {
  /// Sent; neither an ACK from the BBS node nor a reply yet.
  requestSent,

  /// The BBS node confirmed the request; no reply part yet.
  waiting,

  /// Reply parts of a `!x` arrive; see [BbsSyncProgress.received].
  receiving,

  /// A reply broke off; a new `!x` from the last whole message is sent.
  resuming,
}

/// Progress of the request to one BBS that runs now.
class BbsSyncProgress {
  const BbsSyncProgress(this.stage, {this.received = 0, this.total = 0});

  final BbsSyncStage stage;

  /// Messages stored by this sync so far.
  final int received;

  /// [received] before the running `!x` plus the messages its reply
  /// announces; 0 while unknown.
  final int total;
}

enum _ReplyKind { help, sync, post }

/// Collects the DMs of one reply. The BBS sends the next DM only after the
/// ACK of the previous one, so parts arrive in order.
class _PendingReply {
  _PendingReply(
    this.kind, {
    this.sinceId = 0,
    this.sinceDeletion = 0,
    this.knownEpoch = '',
  });

  final _ReplyKind kind;

  /// Cursors of the `!x` this reply answers, and the epoch of the local
  /// copy: a reply to an older request is recognised with them.
  final int sinceId;
  final int sinceDeletion;
  final String knownEpoch;

  final List<String> chunks = [];

  /// `timestamp|text` of every accepted DM; a part the BBS resends after a
  /// lost ACK keeps its timestamp.
  final Set<String> seen = {};

  /// The first part started with [BbsProtocol.compressedTag].
  bool compressed = false;

  /// The BBS node confirmed the request, or a reply part arrived.
  bool arrived = false;

  final Completer<void> _arrival = Completer<void>();
  Completer<String?>? _waiter;
  Timer? _timer;
  Duration _partTimeout = Duration.zero;
  bool _complete = false;

  /// All parts of the reply arrived.
  bool get isComplete => _complete;

  String get text => chunks.join('\n');

  /// The reply text to parse: inflated for a compressed reply (whole lines
  /// only), as received otherwise.
  String get syncText {
    if (!compressed) return text;
    try {
      return BbsProtocol.inflateSync(text) ?? '';
    } on FormatException {
      return '';
    }
  }

  bool accepts(String chunk) {
    if (kind == _ReplyKind.post) {
      return chunks.isEmpty && _postReply.hasMatch(chunk);
    }
    if (kind == _ReplyKind.help) {
      return chunks.isNotEmpty || chunk.split('\n').first.trim() == 'BBS';
    }
    if (chunks.isEmpty) {
      if (chunk.startsWith('Usage: !x')) return true;
      if (chunk.startsWith('${BbsProtocol.syncHeaderTag}|')) {
        return !_isOlderPlainReply(chunk);
      }
      if (chunk.startsWith(BbsProtocol.compressedTag)) {
        return _answersThisRequest(chunk);
      }
      return false;
    }
    if (compressed) {
      if (!BbsProtocol.isCompressedPart(chunk)) return false;
      try {
        BbsProtocol.inflateSync('$text\n$chunk');
        return true;
      } on FormatException {
        return false;
      }
    }
    return _continuesPlain(chunk);
  }

  static final RegExp _postReply = RegExp(
    r'^(?:Posted #|Usage: !p|Unknown category)',
  );

  /// A plain `X1` reply to an older request: same epoch as the local copy
  /// and a first record that the app already has. `X1` does not repeat the
  /// cursor of the request, so this is the only sign.
  bool _isOlderPlainReply(String chunk) {
    final lines = chunk.split('\n');
    final header = lines.first.split('|');
    if (knownEpoch.isEmpty || header.length < 2 || header[1] != knownEpoch) {
      return false;
    }
    for (final line in lines.skip(1)) {
      if (line.isEmpty || !_isDigit(line.codeUnitAt(0))) continue;
      final id = int.tryParse(line.substring(0, line.indexOf('|')));
      return id != null && id <= sinceId;
    }
    return false;
  }

  /// A compressed first part whose `X2` header repeats the cursors of this
  /// request. A header that is not whole yet cannot be checked and counts
  /// as this request.
  bool _answersThisRequest(String chunk) {
    final String? inner;
    try {
      inner = BbsProtocol.inflateSync(chunk);
    } on FormatException {
      return false;
    }
    if (inner == null) return false;
    if (inner.isEmpty) return true;
    final header = inner.split('\n').first.split('|');
    if (header.first != BbsProtocol.syncEchoHeaderTag || header.length != 9) {
      return false;
    }
    return header[7] == '$sinceId' && header[8] == '$sinceDeletion';
  }

  static bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

  /// Whether [reply] answers this request: always for `X1`, which does not
  /// repeat the cursors; for `X2` the repeated cursors must be ours.
  bool matches(BbsSyncReply reply) =>
      (reply.requestSinceId ?? sinceId) == sinceId &&
      (reply.requestSinceDeletion ?? sinceDeletion) == sinceDeletion;

  /// Highest record id and last record id seen in the parts of a plain
  /// reply, to check that a next part continues it.
  int _highestId = -1;
  int _lastRecordId = -1;
  bool _inDeletions = false;

  /// Whether [chunk] continues the plain reply so far: records in rising
  /// id order, `+` lines only for the record just before, `R|` lines only
  /// before the records, `-` lines last. A part of an older reply that
  /// still arrives breaks this order and is not taken.
  bool _continuesPlain(String chunk, {bool commit = false}) {
    var highest = _highestId;
    var last = _lastRecordId;
    var inDeletions = _inDeletions;
    for (final line in chunk.split('\n')) {
      if (line.isEmpty) continue;
      if (line.startsWith('R|')) {
        if (highest >= 0 || inDeletions) return false;
      } else if (line.startsWith('-')) {
        inDeletions = true;
      } else if (line.startsWith('+')) {
        final id = int.tryParse(line.substring(1, _bar(line)));
        if (inDeletions || id == null || id != last) return false;
      } else if (_isDigit(line.codeUnitAt(0))) {
        final id = int.tryParse(line.substring(0, _bar(line)));
        if (inDeletions || id == null || id <= highest) return false;
        highest = last = id;
      } else {
        return false;
      }
    }
    if (commit) {
      _highestId = highest;
      _lastRecordId = last;
      _inDeletions = inDeletions;
    }
    return true;
  }

  static int _bar(String line) {
    final index = line.indexOf('|');
    return index < 0 ? line.length : index;
  }

  void add(String chunk) {
    if (chunks.isEmpty && chunk.startsWith(BbsProtocol.compressedTag)) {
      compressed = true;
    }
    if (kind == _ReplyKind.sync && !compressed) {
      final body = chunks.isEmpty
          ? chunk.split('\n').skip(1).join('\n')
          : chunk;
      _continuesPlain(body, commit: true);
    }
    chunks.add(chunk);
    markArrived();
    _complete = _isComplete();
    if (_complete) {
      _finish(text);
    } else {
      _arm(_partTimeout);
    }
  }

  /// The request reached the BBS node (its ACK, or a reply part).
  void markArrived() {
    arrived = true;
    if (!_arrival.isCompleted) _arrival.complete();
  }

  bool _isComplete() {
    if (kind == _ReplyKind.post) return true;
    if (kind == _ReplyKind.help) {
      return BbsProtocol.parseHelp(text)?.isNotEmpty ?? false;
    }
    if (!compressed && text.startsWith('Usage: !x')) return true;
    try {
      return BbsProtocol.parseSync(syncText)?.isComplete ?? false;
    } on FormatException {
      return true;
    }
  }

  /// Whether the request arrives within [timeout]: an ACK or a reply part.
  Future<bool> waitForArrival(Duration timeout) async {
    if (arrived) return true;
    try {
      await _arrival.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return arrived;
    }
  }

  /// The reply, possibly partial, or `null` when no part arrived within
  /// [timeout]; each next part may take [timeout] too.
  Future<String?> wait(Duration timeout) {
    _partTimeout = timeout;
    if (_complete) return Future.value(text);
    final waiter = _waiter = Completer<String?>();
    _arm(timeout);
    return waiter.future;
  }

  void _arm(Duration timeout) {
    if (_waiter == null) return;
    _timer?.cancel();
    _timer = Timer(timeout, () => _finish(chunks.isEmpty ? null : text));
  }

  void _finish(String? value) {
    _timer?.cancel();
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete(value);
  }

  void cancel() => _finish(chunks.isEmpty ? null : text);
}

/// Keeps the local copy of meshcore-gui BBS boards up to date with `!h x`
/// and `!x` over DM. Replies are taken from the connector before they reach
/// the chat, so they cost no unread count or notification.
///
/// One request gets one reply: every attempt of a request carries the same
/// timestamp, so the BBS recognises a repeat; the app repeats only while
/// the BBS node has not confirmed the request; meshcore-gui 1.26.4 drops an
/// older sync reply when a new request arrives. Messages are stored as each
/// reply part arrives. Where inflating is available the app asks for a
/// compressed reply; a BBS before 1.26.4 answers with its usage line, after
/// which this BBS is asked without compression.
class BbsSyncService extends ChangeNotifier {
  BbsSyncService(this._connector, this._store) {
    _connector.addContactMessageInterceptor(_claim);
    _connector.addSendConfirmedInterceptor(_confirm);
    _connector.addListener(_loadKnownBbs);
    _loadKnownBbs();
  }

  /// Loads the BBS nodes of the connected radio once per radio.
  void _loadKnownBbs() {
    final device = deviceKey;
    if (device == null || device == _knownBbsDevice) return;
    _knownBbsDevice = device;
    _knownBbs.clear();
    unawaited(
      _store
          .bbsKeys(device)
          .then((keys) {
            if (_knownBbsDevice == device) _knownBbs.addAll(keys);
          })
          .catchError((Object error) {
            appLogger.warn('BBS nodes not loaded: $error', tag: 'BBS');
          }),
    );
  }

  final MeshCoreConnector _connector;
  final BbsStore _store;

  /// Attempts per request while the BBS node does not confirm it.
  static const int maxAttempts = 3;

  /// Margin on the time the BBS needs to try a reply part: the app can only
  /// estimate the timeout the radio of the BBS uses.
  static const double retryWindowMargin = 1.25;

  /// The time the BBS needs to try one reply part, with [retryWindowMargin],
  /// from its [delivery] settings (`!h x`): the first `floodAfter` attempts
  /// go along the known route and wait [direct] × `waitFactor` each; the
  /// rest flood and wait [flood] × `waitFactor`, at least `floodMinWait`.
  @visibleForTesting
  static Duration retryWindow(
    Duration direct,
    Duration flood, [
    BbsDeliverySettings delivery = BbsDeliverySettings.defaults,
  ]) {
    final routed = delivery.floodAfter < delivery.attempts
        ? delivery.floodAfter
        : delivery.attempts;
    final flooded = delivery.attempts - routed;
    final floodWait = flood.inMilliseconds * delivery.waitFactor;
    final perFlood = floodWait > delivery.floodMinWait.inMilliseconds
        ? floodWait
        : delivery.floodMinWait.inMilliseconds.toDouble();
    return Duration(
      milliseconds:
          ((routed * direct.inMilliseconds * delivery.waitFactor +
                      flooded * perFlood) *
                  retryWindowMargin)
              .ceil(),
    );
  }

  /// How long delivery settings from `!h x` are used before a sync asks for
  /// them again, so a change by the BBS operator reaches the app.
  static const Duration deliveryRefresh = Duration(hours: 24);

  /// Whether the delivery settings must be fetched (again) with `!h x`.
  static bool _deliveryStale(BbsDeliverySettings? delivery) {
    final checked = delivery?.checkedAt;
    return checked == null ||
        _nowSeconds - checked >= deliveryRefresh.inSeconds;
  }

  /// Version of the app for the log; set by `main.dart` at start.
  String appVersion = 'unknown';

  /// `!x` requests per sync, a guard against a BBS that keeps resetting.
  static const int maxRounds = 100;

  /// Replaces the path-based request timeout in tests; the flood minimum
  /// wait of the BBS is then left out of the reply window.
  @visibleForTesting
  Duration? replyTimeout;

  /// Ask for compressed replies where inflating is available. Tests of the
  /// plain `X1` path switch it off.
  @visibleForTesting
  bool compress = true;

  final Map<String, _PendingReply> _pending = {};
  final Map<int, _PendingReply> _expectedAcks = {};
  final Map<String, Set<String>> _lastSeen = {};
  final Map<String, Future<BbsSyncResult>> _running = {};
  final Map<String, BbsSyncResult> _lastResult = {};
  final Map<String, BbsSyncProgress> _progress = {};
  final Map<String, Future<void>> _applying = {};
  final Map<String, Set<int>> _storedIds = {};
  final Map<String, int> _revision = {};
  final Map<String, DateTime> _lastActivity = {};
  final Map<String, DateTime> _lastHelp = {};
  final Map<String, DateTime> _lastCompressed = {};
  final Map<String, Duration> _leftoverWindow = {};

  /// The last sync reply per BBS that stayed incomplete (also without any
  /// part): parts that still arrive after the request ended are added to it
  /// and applied (v0.4.0).
  final Map<String, _PendingReply> _lastPartial = {};

  /// BBS nodes this radio has a board of; their sync data never reaches the
  /// chat. Loaded from the store per radio, extended by every request.
  final Set<String> _knownBbs = {};
  String? _knownBbsDevice;
  final Set<String> _plainOnly = {};
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

  /// Progress of the request to [bbsKey] that runs now; `null` when none
  /// runs.
  BbsSyncProgress? progress(String bbsKey) => _progress[bbsKey];

  /// Changes every time messages of [bbsKey] are stored, so a screen knows
  /// when to reload them.
  int revision(String bbsKey) => _revision[bbsKey] ?? 0;

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
        _PendingReply(_ReplyKind.post),
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
      _progress.remove(key);
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

  /// Fetches new messages from [bbs]. Categories are fetched with `!h x`
  /// (also for the delivery settings) when [refreshCategories] is set, when
  /// none are known yet, when the delivery settings are missing or older
  /// than [deliveryRefresh], or when the BBS reports a category the app does
  /// not know. When only the delivery settings were due, a lost `!h x` reply
  /// does not stop the sync. A second call while a sync
  /// of the same BBS runs returns that sync.
  Future<BbsSyncResult> sync(Contact bbs, {bool refreshCategories = false}) {
    final key = bbs.publicKeyHex;
    final running = _running[key];
    if (running != null) return running;
    if (isPosting(key)) return Future.value(BbsSyncResult.failed);
    final future = _sync(bbs, refreshCategories)
        .then((result) async {
          _lastResult[key] = result;
          await _logResult(bbs, result);
          return result;
        })
        .whenComplete(() {
          _running.remove(key);
          _progress.remove(key);
          _storedIds.remove(key);
          notifyListeners();
        });
    _running[key] = future;
    notifyListeners();
    return future;
  }

  /// Logs the end of a sync with the cursor the next `!x` starts from.
  Future<void> _logResult(Contact bbs, BbsSyncResult result) async {
    final device = deviceKey;
    BbsBoard? board;
    try {
      board = device == null
          ? null
          : await _store.board(device, bbs.publicKeyHex);
    } on Object {
      board = null;
    }
    appLogger.info(
      'BBS sync ${bbs.name}: ${result.name}, next !x '
      '${board?.lastId ?? 0} ${board?.deletionSeq ?? 0}',
      tag: 'BBS',
    );
  }

  Future<BbsSyncResult> _sync(Contact bbs, bool refreshCategories) async {
    final device = deviceKey;
    if (device == null) return BbsSyncResult.failed;
    final key = bbs.publicKeyHex;
    _storedIds[key] = {};
    try {
      var board = await _store.board(device, key) ?? const BbsBoard();
      appLogger.info(
        'BBS sync ${bbs.name}: start at !x ${board.lastId} '
        '${board.deletionSeq} (app $appVersion)',
        tag: 'BBS',
      );
      final needCategories = refreshCategories || board.categories.isEmpty;
      if (needCategories || _deliveryStale(board.delivery)) {
        if (!await _fetchCategories(bbs, device) && needCategories) {
          return BbsSyncResult.noReply;
        }
      }
      var categoriesChecked = false;
      for (var round = 0; round < maxRounds; round++) {
        board = await _store.board(device, key) ?? const BbsBoard();
        final compressed =
            compress && BbsInflate.supported && !_plainOnly.contains(key);
        final pending = _PendingReply(
          _ReplyKind.sync,
          sinceId: board.lastId,
          sinceDeletion: board.deletionSeq,
          knownEpoch: board.epoch,
        );
        final raw = await _request(
          bbs,
          BbsProtocol.syncCommand(
            board.lastId,
            board.deletionSeq,
            compressed: compressed,
          ),
          pending,
        );
        await _applying[key];
        if (raw == null) {
          // Confirmed without any reply part after earlier progress is a
          // broken sync; without progress the BBS does not answer this app.
          return pending.arrived && (round > 0 || _storedIds[key]!.isNotEmpty)
              ? BbsSyncResult.incomplete
              : BbsSyncResult.noReply;
        }
        if (raw.startsWith('Usage: !x') && compressed) {
          // A BBS before meshcore-gui 1.26.4 does not know the flag.
          _plainOnly.add(key);
          continue;
        }
        final reply = BbsProtocol.parseSync(pending.syncText);
        if (reply == null && pending.compressed) {
          // Compressed parts arrived, but not one whole line.
          return BbsSyncResult.incomplete;
        }
        if (reply == null) {
          appLogger.warn('BBS sync refused: $raw', tag: 'BBS');
          return BbsSyncResult.failed;
        }
        if (!pending.matches(reply)) return BbsSyncResult.incomplete;
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
        if (!sameEpoch) {
          // The local copy was discarded; count from the new epoch on.
          _storedIds[key]!.clear();
          continue;
        }
        _stored(key, reply);
        if (!reply.isComplete) {
          final after = await _store.board(device, key) ?? const BbsBoard();
          if (after.lastId <= board.lastId) return BbsSyncResult.incomplete;
          _setProgress(key, BbsSyncStage.resuming);
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
    final text = await _request(
      bbs,
      BbsProtocol.helpCommand,
      _PendingReply(_ReplyKind.help),
    );
    final categories = text == null ? null : BbsProtocol.parseHelp(text);
    if (categories == null) return false;
    await _store.saveCategories(device, bbs.publicKeyHex, categories);
    final delivery =
        BbsProtocol.parseHelpSettings(text!) ?? BbsDeliverySettings.defaults;
    await _store.saveDelivery(
      device,
      bbs.publicKeyHex,
      delivery.checked(_nowSeconds),
    );
    appLogger.info(
      'BBS delivery settings ${delivery.announced ? 'from BBS' : 'default'}: '
      'a=${delivery.attempts} f=${delivery.floodAfter} '
      'w=${delivery.floodMinWait.inSeconds}s k=${delivery.waitFactor}',
      tag: 'BBS',
    );
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

  /// Delivery settings of the BBS [key] from the store; the defaults when
  /// unknown. With [replyTimeout] (tests) the flood minimum wait is left out.
  Future<BbsDeliverySettings> _deliveryFor(String key) async {
    final device = deviceKey;
    final stored = device == null
        ? null
        : (await _store.board(device, key))?.delivery;
    final delivery = stored ?? BbsDeliverySettings.defaults;
    if (replyTimeout == null) return delivery;
    return BbsDeliverySettings(
      attempts: delivery.attempts,
      floodAfter: delivery.floodAfter,
      floodMinWait: Duration.zero,
      waitFactor: delivery.waitFactor,
      announced: delivery.announced,
    );
  }

  /// Sends [command] and returns the reply text (all parts joined with
  /// `\n`, possibly partial), or `null` when no part arrived.
  ///
  /// Every attempt carries the same timestamp, so the BBS recognises a
  /// repeat. The command is sent again (up to [attempts] times) only while
  /// neither the ACK of the BBS node nor a reply part arrived within the
  /// request timeout. After that each reply part may take [retryWindow]: the
  /// time the BBS needs to try a part, from its delivery settings.
  Future<String?> _request(
    Contact bbs,
    String command,
    _PendingReply pending, {
    int attempts = maxAttempts,
  }) async {
    final key = bbs.publicKeyHex;
    final timestamp = _nowSeconds;
    // The new request starts from what was applied; an older broken-off
    // reply is not continued any more.
    _lastPartial.remove(key);
    _knownBbs.add(key);
    _pending[key] = pending;
    if (pending.kind == _ReplyKind.help) _lastHelp[key] = DateTime.now();
    if (command.endsWith(' ${BbsProtocol.compressFlag}')) {
      _lastCompressed[key] = DateTime.now();
    }
    var window = Duration.zero;
    try {
      final delivery = await _deliveryFor(key);
      for (var attempt = 0; attempt < attempts; attempt++) {
        final timeout = await _send(bbs, command, attempt, timestamp, pending);
        window = retryWindow(
          timeout,
          replyTimeout ?? _floodTimeout(bbs),
          delivery,
        );
        if (await pending.waitForArrival(timeout)) break;
      }
      // Without arrival a `!p` is still awaited: it is never sent again, and
      // only its ACK may have been lost.
      if (!pending.arrived && pending.kind != _ReplyKind.post) return null;
      return await pending.wait(window);
    } finally {
      pending.cancel();
      _expectedAcks.removeWhere((_, value) => identical(value, pending));
      if (identical(_pending[key], pending)) _pending.remove(key);
      if (pending.kind == _ReplyKind.sync && !pending.isComplete) {
        // Also without any part: the whole reply may still come, when the
        // radio hands DMs over late.
        _lastPartial[key] = pending;
        appLogger.info(
          'BBS reply incomplete after ${pending.chunks.length} part(s); '
          'parts that still arrive are applied',
          tag: 'BBS',
        );
      }
      _lastSeen[key] = pending.seen;
      _lastActivity[key] = DateTime.now();
      _leftoverWindow[key] = window;
    }
  }

  Future<Duration> _send(
    Contact bbs,
    String command,
    int attempt,
    int timestamp,
    _PendingReply pending,
  ) async {
    final selection = await _connector.preparePathForContactSend(bbs);
    final self = _connector.selfPublicKey;
    if (self != null) {
      // The command goes out unchanged (no SMAZ or Cyr2Lat), so the hash is
      // taken over the command as sent.
      final hash = MessageRetryService.computeExpectedAckHash(
        timestamp,
        attempt,
        command,
        self,
      );
      _expectedAcks[hash] = pending;
    }
    if (!pending.arrived) {
      final resuming =
          _progress[bbs.publicKeyHex]?.stage == BbsSyncStage.resuming;
      _setProgress(
        bbs.publicKeyHex,
        resuming ? BbsSyncStage.resuming : BbsSyncStage.requestSent,
      );
    }
    appLogger.info('BBS → $command (try ${attempt + 1})', tag: 'BBS');
    await _connector.sendFrame(
      buildSendTextMsgFrame(
        bbs.publicKey,
        command,
        attempt: attempt,
        timestampSeconds: timestamp,
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

  /// The timeout of a flooded DM to [bbs], as the attempts of the BBS after
  /// `floodAfter` are.
  Duration _floodTimeout(Contact bbs) => Duration(
    milliseconds: _connector.calculateTimeout(
      pathLength: -1,
      messageBytes: maxFrameSize,
      contactKey: bbs.publicKeyHex,
    ),
  );

  /// Marks the request whose ACK hash this is as arrived.
  bool _confirm(int ackHash) {
    final pending = _expectedAcks.remove(ackHash);
    if (pending == null) return false;
    final key = _pending.entries
        .where((entry) => identical(entry.value, pending))
        .map((entry) => entry.key)
        .firstOrNull;
    if (!pending.arrived && pending.chunks.isEmpty && key != null) {
      _setProgress(key, BbsSyncStage.waiting);
    }
    if (!pending.arrived) {
      appLogger.info('BBS request confirmed by the BBS node', tag: 'BBS');
    }
    pending.markArrived();
    return true;
  }

  /// Takes the DMs of a reply in progress, late copies of parts that were
  /// already taken, and leftovers of an older sync reply away from the chat.
  bool _claim(Message message) {
    if (message.isCli) return false;
    final key = message.senderKeyHex;
    final id = '${message.timestamp.millisecondsSinceEpoch}|${message.text}';
    final pending = _pending[key];
    if (pending != null) {
      if (pending.seen.contains(id)) return true;
      if (pending.accepts(message.text)) {
        pending.seen.add(id);
        pending.add(message.text);
        _lastActivity[key] = DateTime.now();
        appLogger.info(
          'BBS part ${pending.chunks.length} received (${pending.kind.name})',
          tag: 'BBS',
        );
        if (pending.kind == _ReplyKind.sync) _onSyncPart(key, pending);
        return true;
      }
    } else {
      if (_lastSeen[key]?.contains(id) ?? false) return true;
      final partial = _lastPartial[key];
      if (partial != null && partial.accepts(message.text)) {
        partial.seen.add(id);
        partial.add(message.text);
        _lastActivity[key] = DateTime.now();
        appLogger.info(
          'BBS late part ${partial.chunks.length} received after the request',
          tag: 'BBS',
        );
        _applyLate(key, partial);
        return true;
      }
    }
    final leftover = _isSyncLeftover(key, message.text);
    if (leftover || _knownBbs.contains(key)) {
      appLogger.info(
        leftover
            ? 'BBS: left-over sync DM dropped (${_notTaken(key, message.text)})'
            : 'BBS DM shown in chat (${_notTaken(key, message.text)})',
        tag: 'BBS',
      );
    }
    return leftover;
  }

  /// Why a DM of the BBS [key] was not taken as a part of a reply, for the
  /// log: which reply was waiting, how many parts it had, and what the DM
  /// looks like (its start and length).
  String _notTaken(String key, String text) {
    final start = text.length > 12 ? '${text.substring(0, 12)}…' : text;
    final shape =
        '"$start" ${text.length} chars'
        '${BbsProtocol.isCompressedPart(text) ? ', base64' : ''}';
    final pending = _pending[key];
    if (pending != null) {
      return 'running ${pending.kind.name} reply with '
          '${pending.chunks.length} part(s) does not take $shape';
    }
    final partial = _lastPartial[key];
    if (partial != null) {
      return 'broken-off reply with ${partial.chunks.length} part(s)'
          '${partial.compressed ? ' (compressed)' : ''} does not take $shape';
    }
    return 'no running or broken-off reply for $shape';
  }

  /// A DM of the BBS node that looks like sync data but belongs to no
  /// running reply: a part of an older reply that was still on its way.
  /// From a BBS node this radio has a board of, a reply start (`Z1|`, `X1|`,
  /// `X2|`), record lines or a base64 part are sync data at any time, also
  /// long after the last request (the radio may hand them over late). From
  /// another node, and for a help reply, they count only while a request
  /// runs or shortly after one.
  bool _isSyncLeftover(String key, String text) {
    if (_knownBbs.contains(key) &&
        BbsProtocol.looksLikeSyncData(text, compressed: true)) {
      return true;
    }
    final window = _leftoverWindow[key] ?? Duration.zero;
    bool within(DateTime? time) =>
        time != null && DateTime.now().difference(time) <= window;
    final recent = _pending.containsKey(key) || within(_lastActivity[key]);
    return recent &&
        BbsProtocol.looksLikeSyncData(
          text,
          // Only kinds of reply asked for recently; the window counts from
          // the end of the last request.
          compressed: within(_lastCompressed[key]) || _pending.containsKey(key),
          help: within(_lastHelp[key]) || _pending.containsKey(key),
        );
  }

  /// Stores the whole records of a reply that is still arriving, and shows
  /// them. The complete reply is applied by the sync loop.
  void _onSyncPart(String key, _PendingReply pending) {
    final previous = _applying[key] ?? Future<void>.value();
    // _applyPart never fails, so one bad part cannot block later ones.
    _applying[key] = previous.then((_) => _applyPart(key, pending));
  }

  /// Applies a part that arrived after its request ended: the whole records
  /// so far, also of a reply that is now complete, so the next `!x` starts
  /// after them.
  void _applyLate(String key, _PendingReply partial) {
    final previous = _applying[key] ?? Future<void>.value();
    _applying[key] = previous.then((_) async {
      final device = deviceKey;
      if (device == null) return;
      final BbsSyncReply? reply;
      try {
        reply = BbsProtocol.parseSync(partial.syncText);
      } on Object {
        return;
      }
      if (reply == null || !partial.matches(reply)) return;
      try {
        final board = await _store.board(device, key);
        if (board != null &&
            board.epoch.isNotEmpty &&
            board.epoch != reply.epoch) {
          _lastPartial.remove(key);
          return;
        }
        final before = board?.lastId ?? 0;
        if (reply.records.isNotEmpty || reply.isComplete) {
          await _store.applySync(device, key, reply, syncedAt: _nowSeconds);
        }
        if (reply.isComplete && identical(_lastPartial[key], partial)) {
          _lastPartial.remove(key);
        }
        final after = (await _store.board(device, key))?.lastId ?? before;
        appLogger.info(
          'BBS late part applied: last id $before → $after',
          tag: 'BBS',
        );
        _revision[key] = revision(key) + 1;
        notifyListeners();
      } on Object catch (error) {
        appLogger.warn('BBS late part not stored: $error', tag: 'BBS');
      }
    });
  }

  Future<void> _applyPart(String key, _PendingReply pending) async {
    final device = deviceKey;
    if (device == null) return;
    final BbsSyncReply? reply;
    try {
      reply = BbsProtocol.parseSync(pending.syncText);
    } on Object {
      return;
    }
    if (reply == null || !pending.matches(reply)) return;
    try {
      final board = await _store.board(device, key);
      // A new epoch is handled by the sync loop; storing records of a reply
      // to the old cursor would leave a hole.
      if (board != null &&
          board.epoch.isNotEmpty &&
          board.epoch != reply.epoch) {
        return;
      }
      if (!reply.isComplete && reply.records.isNotEmpty) {
        await _store.applySync(device, key, reply, syncedAt: _nowSeconds);
      }
      _stored(key, reply);
    } on Object catch (error) {
      appLogger.warn('BBS part not stored: $error', tag: 'BBS');
    }
  }

  /// Counts the records of [reply] as stored and updates the progress.
  void _stored(String key, BbsSyncReply reply) {
    final ids = _storedIds[key];
    if (ids == null) return;
    final before = ids.length;
    final pending = _pending[key];
    ids.addAll(reply.records.map((record) => record.id));
    final atRequest = pending == null
        ? ids.length
        : ids.where((id) => id <= pending.sinceId).length;
    if (pending != null) {
      _progress[key] = BbsSyncProgress(
        BbsSyncStage.receiving,
        received: ids.length,
        total: atRequest + reply.count,
      );
    }
    if (ids.length != before) _revision[key] = revision(key) + 1;
    notifyListeners();
  }

  void _setProgress(String key, BbsSyncStage stage) {
    final ids = _storedIds[key];
    _progress[key] = BbsSyncProgress(stage, received: ids?.length ?? 0);
    notifyListeners();
  }

  static int get _nowSeconds => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  @override
  void dispose() {
    _connector.removeContactMessageInterceptor(_claim);
    _connector.removeSendConfirmedInterceptor(_confirm);
    _connector.removeListener(_loadKnownBbs);
    for (final pending in _pending.values) {
      pending.cancel();
    }
    _pending.clear();
    super.dispose();
  }
}
