import '../models/bbs_board.dart';
import '../models/bbs_message.dart';
import '../services/bbs/bbs_protocol.dart';
import 'bbs_store_stub.dart'
    if (dart.library.io) 'bbs_store_io.dart'
    as platform;

/// Local copy of meshcore-gui BBS boards, keyed by the first 10 hex chars of
/// the connected radio ([deviceKey]) and the BBS node's public key ([bbsKey]).
abstract class BbsStore {
  /// `null` on web, where the BBS is not supported.
  static Future<BbsStore?> open() => platform.createBbsStore();

  Future<BbsBoard?> board(String deviceKey, String bbsKey);

  /// Stores the categories from a `!h` reply.
  Future<void> saveCategories(
    String deviceKey,
    String bbsKey,
    List<BbsCategory> categories,
  );

  /// Applies a (possibly partial) `!x` reply: stores its records, removes
  /// deleted ids and advances the cursors. Returns `false` when the epoch
  /// changed: the local copy is then discarded and the sync must start
  /// again from `!x 0 0`.
  Future<bool> applySync(
    String deviceKey,
    String bbsKey,
    BbsSyncReply reply, {
    required int syncedAt,
  });

  /// Messages newest first, optionally of one category (full name).
  Future<List<BbsMessage>> messages(
    String deviceKey,
    String bbsKey, {
    String? category,
  });

  /// Removes messages older than their category's retention; returns the
  /// number removed.
  Future<int> purgeExpired(String deviceKey, String bbsKey, {required int now});

  Future<void> close();
}
