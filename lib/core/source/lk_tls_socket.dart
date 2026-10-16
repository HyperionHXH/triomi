import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Adapts the public RawSecureSocket API without relinquishing the raw TCP
/// cancellation handle during the TLS handshake.
class LkTlsSocket extends Stream<Uint8List> implements SecureSocket {
  LkTlsSocket(this.raw) {
    _input = StreamController<Uint8List>(
      onPause: () => raw.readEventsEnabled = false,
      onResume: () => raw.readEventsEnabled = true,
      onCancel: destroy,
    );
    _sink = IOSink(
      _SocketConsumer(_write, () async {
        raw.shutdown(SocketDirection.send);
      }),
    );
    raw.listen(
      (event) {
        if (event == RawSocketEvent.read) {
          final data = raw.read();
          if (data != null && !_input.isClosed) _input.add(data);
        } else if (event == RawSocketEvent.write) {
          raw.writeEventsEnabled = false;
          _writable?.complete();
          _writable = null;
        } else if (event == RawSocketEvent.readClosed) {
          if (!_input.isClosed) unawaited(_input.close());
        } else if (event == RawSocketEvent.closed) {
          destroy();
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!_input.isClosed) _input.addError(error, stack);
        destroy();
      },
      onDone: destroy,
    );
  }
  final RawSecureSocket raw;
  late final StreamController<Uint8List> _input;
  late final IOSink _sink;
  Completer<void>? _writable;
  bool _destroyed = false;

  Future<void> _write(List<int> bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      if (_destroyed) throw const SocketException('TLS connection closed');
      offset += raw.write(bytes, offset, bytes.length - offset);
      if (offset == bytes.length) return;
      _writable ??= Completer<void>();
      raw.writeEventsEnabled = true;
      await _writable!.future;
    }
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _input.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _writable?.complete();
    _writable = null;
    raw.close();
    if (!_input.isClosed) unawaited(_input.close());
  }

  @override
  void add(List<int> data) => _sink.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      throw UnsupportedError('Socket.addError');
  @override
  Future<void> addStream(Stream<List<int>> stream) => _sink.addStream(stream);
  @override
  Future<void> flush() => _sink.flush();
  @override
  Future<void> close() async {
    await _sink.close();
  }

  @override
  Future<void> get done async {
    await _sink.done;
  }

  @override
  Encoding get encoding => _sink.encoding;
  @override
  set encoding(Encoding value) => _sink.encoding = value;
  @override
  void write(Object? object) => _sink.write(object);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _sink.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _sink.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _sink.writeln(object);
  @override
  bool setOption(SocketOption option, bool enabled) =>
      raw.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => raw.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => raw.setRawOption(option);
  @override
  InternetAddress get address => raw.address;
  @override
  InternetAddress get remoteAddress => raw.remoteAddress;
  @override
  int get port => raw.port;
  @override
  int get remotePort => raw.remotePort;
  @override
  X509Certificate? get peerCertificate => raw.peerCertificate;
  @override
  String? get selectedProtocol => raw.selectedProtocol;
  @override
  void renegotiate({
    bool useSessionCache = true,
    bool requestClientCertificate = false,
    bool requireClientCertificate = false,
  }) {}
  // Socket's private detach operation cannot be exposed across library bounds.
  // This adapter is already TLS and is never upgraded by HttpClient.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SocketConsumer implements StreamConsumer<List<int>> {
  _SocketConsumer(this.write, this.finish);
  final Future<void> Function(List<int>) write;
  final Future<void> Function() finish;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      await write(chunk);
    }
  }

  @override
  Future<void> close() => finish();
}
