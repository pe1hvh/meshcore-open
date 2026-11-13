import 'dart:typed_data';

/// One message in the local copy of a meshcore-gui BBS board.
class BbsMessage {
  const BbsMessage({
    required this.id,
    required this.timestamp,
    required this.category,
    required this.sender,
    required this.text,
    this.read = false,
    this.pathLength,
    this.pathHashWidth,
    this.pathBytes,
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

  /// Route to the BBS node when this radio posted the message with `!p`, as
  /// the radio knew it then (-1 = flood, 0+ = hops); `null` for messages
  /// posted by others, whose route this radio never saw.
  final int? pathLength;

  /// Bytes per hop in [pathBytes].
  final int? pathHashWidth;

  /// Hop hashes of that route; empty for flood or direct.
  final Uint8List? pathBytes;

  /// Whether this radio posted the message and stored its route.
  bool get hasPath => pathLength != null;

  DateTime get time =>
      DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true);
}
