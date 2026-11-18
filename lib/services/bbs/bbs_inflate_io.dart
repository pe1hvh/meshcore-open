import 'dart:io';

const bool inflateSupported = true;

List<int> inflatePrefix(List<int> bytes) {
  final filter = RawZLibFilter.inflateFilter(raw: true);
  final out = <int>[];
  try {
    filter.process(bytes, 0, bytes.length);
    while (true) {
      final chunk = filter.processed(flush: true, end: false);
      if (chunk == null) break;
      out.addAll(chunk);
    }
  } on FormatException {
    rethrow;
  } on Exception catch (error) {
    throw FormatException('Invalid deflate stream: $error');
  }
  return out;
}
