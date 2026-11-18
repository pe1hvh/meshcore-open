import 'bbs_inflate_stub.dart'
    if (dart.library.io) 'bbs_inflate_io.dart'
    as platform;

/// Raw deflate (no zlib header) for compressed BBS sync replies.
abstract final class BbsInflate {
  /// Whether this platform can inflate; not on web, where the BBS is not
  /// supported anyway.
  static bool get supported => platform.inflateSupported;

  /// Inflates the start of a raw deflate stream. [bytes] may stop anywhere
  /// in the stream: the result is then the text those bytes encode so far.
  /// Throws [FormatException] when [bytes] are not a deflate stream.
  static List<int> inflatePrefix(List<int> bytes) =>
      platform.inflatePrefix(bytes);
}
