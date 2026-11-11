/// One message in the local copy of a meshcore-gui BBS board.
class BbsMessage {
  const BbsMessage({
    required this.id,
    required this.timestamp,
    required this.category,
    required this.sender,
    required this.text,
    this.read = false,
  });

  /// Message id on the BBS node; ids only grow within one board epoch.
  final int id;

  /// Unix seconds as stored by the BBS node.
  final int timestamp;

  /// Full category name, e.g. `URGENT`.
  final String category;
  final String sender;
  final String text;
  final bool read;

  DateTime get time =>
      DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true);
}
