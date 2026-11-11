import '../../models/bbs_board.dart';
import '../../models/bbs_message.dart';

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

/// A parsed `!x` reply (protocol `X1`, meshcore-gui 1.26.0).
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
/// `!h`, `!x` and `!p`). A reply that spans several DMs is passed in as
/// the DM texts joined with `\n`.
class BbsProtocol {
  BbsProtocol._();

  static const String helpCommand = '!h';
  static const String syncHeaderTag = 'X1';

  static String syncCommand(int sinceId, int sinceDeletion) =>
      '!x $sinceId $sinceDeletion';

  /// Regions are not used by the app, so a post never carries one.
  static String postCommand(String abbreviation, String text) =>
      '!p $abbreviation $text';

  static final RegExp _abbreviationTable = RegExp(
    r'^\S+=\S.*?(?:\s+\S+=\S.*?)*$',
  );
  static final RegExp _abbreviationEntry = RegExp(r'(\S+)=(.+?)(?=\s+\S+=|$)');
  static final RegExp _postedId = RegExp(r'^Posted #(\d+) \[');

  /// Categories from a `!h` reply, in board order; `null` when [reply] is
  /// not a BBS help text.
  static List<BbsCategory>? parseHelp(String reply) {
    final lines = reply
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
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

  /// Message id from the `!p` confirmation `Posted #<id> [<CAT>]: ...`.
  static int? parsePostedId(String reply) {
    final match = _postedId.firstMatch(reply.trim());
    return match == null ? null : int.parse(match.group(1)!);
  }

  /// Parses a `!x` reply, complete or cut short; `null` when [reply] does
  /// not start with an `X1` header (for example the usage line). Throws
  /// [FormatException] for a malformed reply.
  static BbsSyncReply? parseSync(String reply) {
    final lines = reply.split('\n');
    if (!lines.first.startsWith('$syncHeaderTag|')) return null;

    final header = lines.first.split('|');
    if (header.length != 7) {
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
