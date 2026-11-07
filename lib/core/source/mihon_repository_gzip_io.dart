import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Uint8List decodeRepositoryGzip(Uint8List bytes, int limit) {
  final output = _LimitedSink(limit);
  final decoder = gzip.decoder.startChunkedConversion(output);
  // Chunked conversion checks every emitted output block before retaining it.
  try {
    for (var offset = 0; offset < bytes.length; offset += 4096) {
      decoder.add(
        Uint8List.sublistView(
          bytes,
          offset,
          (offset + 4096).clamp(0, bytes.length),
        ),
      );
    }
    decoder.close();
  } on IOException catch (error) {
    throw FormatException('gzip 仓库索引无效：$error');
  }
  return output.bytes.takeBytes();
}

class _LimitedSink extends ByteConversionSink {
  _LimitedSink(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > limit) {
      throw const FormatException('仓库解压内容超过 16 MiB 限制');
    }
    bytes.add(chunk);
  }

  @override
  void close() {}
}
