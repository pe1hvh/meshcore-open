import 'dart:convert';

import '../../models/bbs_board.dart';
import '../../models/bbs_message.dart';
import 'bbs_inflate.dart';

/// One message record from a `!x` reply, after joining its `+` lines.
class BbsSyncRecord {
  const BbsSyncRecord({
    required this.id,
    required this.timestamp,
    required this.category,
    required this.region,
    required this.sender,
    required this.text,
  });

  final int id;
  final int timestamp;

  /// Abbreviation from `!h`, or the full name of a category that is no
  /// longer configured.
  final String category;
  final String region;
  final String sender;
  final String text;
}

/// A parsed `!x` reply: protocol `X1` (meshcore-gui 1.26.0), or `X2`, the
/// header inside a compressed reply (meshcore-gui 1.26.4), which adds the
/// cursors of the request.
class BbsSyncReply {
  const BbsSyncReply({
    required this.epoch,
    required this.count,
    required this.more,
    required this.deletionSeq,
    required this.deletionCount,
    required this.lineCount,
    required this.receivedLines,
    required this.retention,
    required this.records,
    required this.deletedIds,
    this.requestSinceId,
    this.requestSinceDeletion,
  });

  final String epoch;

  /// Number of records announced in the header.
  final int count;

  /// More records with a higher id remain on the BBS.
  final bool more;

  /// `since_del` for the next request.
  final int deletionSeq;

  /// Number of deleted ids announced in the header.
  final int deletionCount;

  /// Number of lines after the header, announced in the header.
  final int lineCount;

  /// Number of lines after the header that arrived.
  final int receivedLines;

  /// Days per category abbreviation; [BbsBoard.otherCategories] = the rest.
  final Map<String, int> retention;

  /// Records in ascending id. In a reply that is not complete, a record
  /// whose `+` lines may still be missing is left out.
  final List<BbsSyncRecord> records;
  final List<int> deletedIds;

  /// `since_id` and `since_del` of the request this reply answers, from an
  /// `X2` header; `null` for `X1`, which does not repeat them.
  final int? requestSinceId;
  final int? requestSinceDeletion;

  /// Every announced line arrived.
  bool get isComplete => receivedLines == lineCount;

  List<BbsMessage> messagesFor(BbsBoard board) => [
    for (final record in records)
      BbsMessage(
        id: record.id,
        timestamp: record.timestamp,
        category: board.categoryName(record.category),
        sender: record.sender,
        text: record.text,
      ),
  ];
}

/// Commands and reply parsers for the meshcore-gui BBS (DM commands
/// `!h x`, `!x` and `!p`). A reply that spans several DMs is passed in as
/// the DM texts joined with `\n`.
class BbsProtocol {
  BbsProtocol._();

  /// Help with the delivery settings line (meshcore-gui 1.27.0); an older
  /// BBS ignores the `x` and sends its plain help text.
  static const String helpCommand = '!h x';

  /// Start of the delivery settings line in the reply to [helpCommand].
  static const String helpSettingsTag = 'X|';

  static const String syncHeaderTag = 'X1';

  /// Header tag inside a compressed reply: `X1` plus the request cursors.
  static const String syncEchoHeaderTag = 'X2';

  /// Start of the first DM of a compressed reply (meshcore-gui 1.26.4).
  static const String compressedTag = 'Z1|';

  /// `!x` asks for a compressed reply with this flag after both numbers.
  static const String compressFlag = 'z';

  static String syncCommand(
    int sinceId,
    int sinceDeletion, {
    bool compressed = false,
  }) => compressed
      ? '!x $sinceId $sinceDeletion $compressFlag'
      : '!x $sinceId $sinceDeletion';

  static final RegExp _base64Part = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

  /// Whether [chunk] can be a next DM of a compressed reply: base64 only.
  static bool isCompressedPart(String chunk) => _base64Part.hasMatch(chunk);

  static final RegExp _recordLine = RegExp(r'^\d+\|\d+\|');
  static final RegExp _continuationLine = RegExp(r'^\+\d+\|');
  static final RegExp _deletionLine = RegExp(r'^-\d+(?:,\d+)*$');

  /// Whether a DM of the BBS node looks like part of a `!x` reply: a reply
  /// header, or only record, `+`, `-` and `R|` lines in their exact
  /// format. With [compressed] (a compressed `!x` was asked for) also a
  /// base64 part; with [help] (`!h` was asked for) also a help reply. Used
  /// to keep left-overs of an older reply out of the chat; `!r` and `!s`
  /// replies (`2026-11-18 12:30 …`) do not match.
  static bool looksLikeSyncData(
    String text, {
    bool compressed = false,
    bool help = false,
  }) {
    if (text.isEmpty) return false;
    if (text.startsWith('$syncHeaderTag|') ||
        text.startsWith('$syncEchoHeaderTag|') ||
        text.startsWith(compressedTag)) {
      return true;
    }
    if (help && text.split('\n').first.trim() == 'BBS') return true;
    if (compressed && text.length >= 16 && isCompressedPart(text)) return true;
    return text
        .split('\n')
        .every(
          (line) =>
              _recordLine.hasMatch(line) ||
              _continuationLine.hasMatch(line) ||
              _deletionLine.hasMatch(line) ||
              line.startsWith('R|'),
        );
  }

  /// The text of a compressed reply from its first DMs, [reply] being the
  /// DM texts joined with `\n` (the first starting with [compressedTag]).
  /// Only whole lines are returned: the server ends every line with `\n`,
  /// so a line is whole once its line feed arrived. `null` when [reply] is
  /// not a compressed reply or inflating is not supported here. Throws
  /// [FormatException] for a malformed reply.
  static String? inflateSync(String reply) {
    if (!reply.startsWith(compressedTag) || !BbsInflate.supported) {
      return null;
    }
    final encoded = reply.substring(compressedTag.length).replaceAll('\n', '');
    if (encoded.isNotEmpty && !_base64Part.hasMatch(encoded)) {
      throw FormatException('Invalid compressed reply', reply);
    }
    final whole = encoded.length - encoded.length % 4;
    final bytes = base64.decode(encoded.substring(0, whole));
    final text = utf8.decode(
      BbsInflate.inflatePrefix(bytes),
      allowMalformed: true,
    );
    final end = text.lastIndexOf('\n');
    return end < 0 ? '' : text.substring(0, end);
  }

  /// Regions are not used by the app, so a post never carries one.
  static String postCommand(String abbreviation, String text) =>
      '!p $abbreviation $text';

  static final RegExp _abbreviationTable = RegExp(
    r'^\S+=\S.*?(?:\s+\S+=\S.*?)*$',
  );
  static final RegExp _abbreviationEntry = RegExp(r'(\S+)=(.+?)(?=\s+\S+=|$)');
  static final RegExp _postedId = RegExp(r'^Posted #(\d+) \[');

  /// Categories from a `!h` reply, in board order; `null` when [reply] is
  /// not a BBS help text. The delivery settings line is skipped.
  static List<BbsCategory>? parseHelp(String reply) {
    final lines = reply
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith(helpSettingsTag))
        .toList();
    if (lines.isEmpty || lines.first != 'BBS') return null;
    final table = lines.length > 2 ? lines.last : '';
    if (table.startsWith('Regions:') || !_abbreviationTable.hasMatch(table)) {
      return const [];
    }
    return [
      for (final match in _abbreviationEntry.allMatches(table))
        BbsCategory(match.group(1)!, match.group(2)!.trim()),
    ];
  }

  /// Delivery settings from the `X|a=3,f=2,w=30,k=1.2` line of a `!h x`
  /// reply; `null` when the reply has no such line. Unknown keys are
  /// ignored; a missing or invalid value keeps its default. `announced` is
  /// set.
  static BbsDeliverySettings? parseHelpSettings(String reply) {
    final line = reply
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.startsWith(helpSettingsTag))
        .firstOrNull;
    if (line == null) return null;
    final values = <String, num>{};
    for (final pair in line.substring(helpSettingsTag.length).split(',')) {
      final separator = pair.indexOf('=');
      if (separator <= 0) continue;
      final value = num.tryParse(pair.substring(separator + 1).trim());
      if (value != null && value.isFinite && value >= 0) {
        values[pair.substring(0, separator).trim()] = value;
      }
    }
    const fallback = BbsDeliverySettings.defaults;
    final attempts = values['a'];
    final floodAfter = values['f'];
    final wait = values['w'];
    final factor = values['k'];
    return BbsDeliverySettings(
      attempts:
          attempts != null && attempts >= 1 && attempts == attempts.toInt()
          ? attempts.toInt()
          : fallback.attempts,
      floodAfter:
          floodAfter != null &&
              floodAfter >= 1 &&
              floodAfter == floodAfter.toInt()
          ? floodAfter.toInt()
          : fallback.floodAfter,
      floodMinWait: wait != null
          ? Duration(milliseconds: (wait * 1000).round())
          : fallback.floodMinWait,
      waitFactor: factor != null && factor >= 1
          ? factor.toDouble()
          : fallback.waitFactor,
      announced: true,
    );
  }

  /// Message id from the `!p` confirmation `Posted #<id> [<CAT>]: ...`.
  static int? parsePostedId(String reply) {
    final match = _postedId.firstMatch(reply.trim());
    return match == null ? null : int.parse(match.group(1)!);
  }

  /// Parses a `!x` reply, complete or cut short; `null` when [reply] does
  /// not start with an `X1` or `X2` header (for example the usage line).
  /// A compressed reply is parsed after [inflateSync]. Throws
  /// [FormatException] for a malformed reply.
  static BbsSyncReply? parseSync(String reply) {
    final lines = reply.split('\n');
    final echo = lines.first.startsWith('$syncEchoHeaderTag|');
    if (!echo && !lines.first.startsWith('$syncHeaderTag|')) return null;

    final header = lines.first.split('|');
    if (header.length != (echo ? 9 : 7)) {
      throw FormatException('Invalid sync header', lines.first);
    }
    final count = _number(header[2]);
    final more = _number(header[3]);
    final deletionSeq = _number(header[4]);
    final deletionCount = _number(header[5]);
    final lineCount = _number(header[6]);

    final retention = <String, int>{};
    final deletedIds = <int>[];
    final recordTexts = <int, StringBuffer>{};
    int? lastRecordId;
    var receivedLines = 0;
    var endsInRecord = false;

    for (final line in lines.skip(1)) {
      if (line.isEmpty) continue;
      receivedLines++;
      endsInRecord = false;
      if (line.startsWith('R|')) {
        for (final item in line.substring(2).split(',')) {
          final separator = item.lastIndexOf(':');
          if (separator <= 0) throw FormatException('Invalid retention', line);
          retention[item.substring(0, separator)] = _number(
            item.substring(separator + 1),
          );
        }
      } else if (line.startsWith('-')) {
        deletedIds.addAll(line.substring(1).split(',').map(_number));
      } else if (line.startsWith('+')) {
        final separator = line.indexOf('|');
        if (separator < 0) throw FormatException('Invalid continuation', line);
        final id = _number(line.substring(1, separator));
        if (id != lastRecordId) {
          throw FormatException('Continuation without record', line);
        }
        recordTexts[id]!.write(line.substring(separator + 1));
        endsInRecord = true;
      } else if (_isDigit(line.codeUnitAt(0))) {
        final separator = line.indexOf('|');
        final id = _number(separator < 0 ? line : line.substring(0, separator));
        recordTexts[id] = StringBuffer(line);
        lastRecordId = id;
        endsInRecord = true;
      } else {
        throw FormatException('Unknown sync line', line);
      }
    }

    if (receivedLines > lineCount) {
      throw FormatException('More lines than announced', reply);
    }
    if (receivedLines < lineCount && endsInRecord) {
      recordTexts.remove(lastRecordId);
    }

    return BbsSyncReply(
      epoch: header[1],
      count: count,
      more: more == 1,
      deletionSeq: deletionSeq,
      deletionCount: deletionCount,
      lineCount: lineCount,
      receivedLines: receivedLines,
      retention: retention,
      records: [
        for (final text in recordTexts.values) _record(text.toString()),
      ],
      deletedIds: deletedIds,
      requestSinceId: echo ? _number(header[7]) : null,
      requestSinceDeletion: echo ? _number(header[8]) : null,
    );
  }

  /// Splits a record on its first five `|`; the text may contain more.
  static BbsSyncRecord _record(String line) {
    final fields = <String>[];
    var start = 0;
    for (var i = 0; i < 5; i++) {
      final separator = line.indexOf('|', start);
      if (separator < 0) throw FormatException('Incomplete record', line);
      fields.add(line.substring(start, separator));
      start = separator + 1;
    }
    return BbsSyncRecord(
      id: _number(fields[0]),
      timestamp: _number(fields[1]),
      category: fields[2],
      region: fields[3],
      sender: fields[4],
      text: line.substring(start),
    );
  }

  static bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

  static int _number(String value) {
    if (value.isEmpty || !value.codeUnits.every(_isDigit)) {
      throw FormatException('Invalid number', value);
    }
    return int.parse(value);
  }
}
