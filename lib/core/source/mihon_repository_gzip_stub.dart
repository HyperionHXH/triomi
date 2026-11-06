import 'dart:typed_data';

Uint8List decodeRepositoryGzip(Uint8List bytes, int limit) =>
    throw const FormatException('当前平台不支持 gzip 仓库索引');
