import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const jsWorkerMessageLimit = 8 * 1024 * 1024;

/// Length framing checks the advertised size before buffering its payload.
class JsWorkerWire {
  JsWorkerWire(this.socket, this.onMessage, this.onClosed) {
    socket.listen(_receive, onError: (_) => close(), onDone: close);
  }
  final Socket socket;
  final void Function(Map<String, dynamic>) onMessage;
  final void Function() onClosed;
  final _header = BytesBuilder(copy: false);
  final _payload = BytesBuilder(copy: false);
  int? _length;
  bool _closed = false;

  void send(Map<String, Object?> message) {
    if (_closed) throw const SocketException('Worker connection closed');
    final bytes = utf8.encode(jsonEncode(message));
    if (bytes.length > jsWorkerMessageLimit) {
      throw const FormatException('Worker message exceeds limit');
    }
    final header = ByteData(4)..setUint32(0, bytes.length);
    socket.add(header.buffer.asUint8List());
    socket.add(bytes);
  }

  void _receive(Uint8List chunk) {
    try {
      var offset = 0;
      while (offset < chunk.length) {
        if (_length == null) {
          final count = (4 - _header.length).clamp(0, chunk.length - offset);
          _header.add(Uint8List.sublistView(chunk, offset, offset + count));
          offset += count;
          if (_header.length < 4) return;
          _length = ByteData.sublistView(_header.takeBytes()).getUint32(0);
          if (_length! < 2 || _length! > jsWorkerMessageLimit) {
            throw const FormatException('Worker frame exceeds limit');
          }
        }
        final count = (_length! - _payload.length).clamp(
          0,
          chunk.length - offset,
        );
        _payload.add(Uint8List.sublistView(chunk, offset, offset + count));
        offset += count;
        if (_payload.length == _length) {
          final value = jsonDecode(utf8.decode(_payload.takeBytes()));
          _length = null;
          if (value is! Map<String, dynamic>) {
            throw const FormatException('Invalid worker envelope');
          }
          onMessage(value);
        }
      }
    } catch (_) {
      close();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    socket.destroy();
    onClosed();
  }
}
