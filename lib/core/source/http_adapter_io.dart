import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'lk_tls_socket.dart';

// Only the built-in LK hosts use this fallback. TLS still authenticates the
// original URL hostname; DNS results never replace the URL, Host or SNI.
const lkDnsHosts = {
  'www.lightnovel.fun',
  'api.lightnovel.fun',
  'res.lightnovel.fun',
};

void configureSourceHttpAdapter(Dio dio, {String proxy = ''}) {
  final resolver = LkDnsFallback();
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      if (proxy.isNotEmpty) {
        final uri = Uri.parse(proxy);
        final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
        client.findProxy = (_) => 'PROXY $host:${uri.port}';
      }
      client.connectionFactory = (uri, proxyHost, proxyPort) async {
        if (proxyHost != null || !lkDnsHosts.contains(uri.host)) {
          if (proxyHost == null && uri.scheme == 'https') {
            return SecureSocket.startConnect(uri.host, uri.port);
          }
          return Socket.startConnect(
            proxyHost ?? uri.host,
            proxyPort ?? uri.port,
          );
        }
        return connectLkAddresses(uri, await resolver.lookup(uri.host));
      };
      return client;
    },
  );
}

/// Each attempt owns its TCP/TLS socket until it is handed to HttpClient.
/// Cancellation and deadlines destroy it, including a TLS completion arriving
/// after its attempt was abandoned. Host/SNI and certificate checks stay intact.
ConnectionTask<Socket> connectLkAddresses(
  Uri uri,
  List<InternetAddress> addresses, {
  Duration timeout = const Duration(seconds: 5),
}) {
  ConnectionTask<RawSocket>? active;
  ConnectionTask<Socket>? plainActive;
  RawSocket? owned;
  var cancelled = false;
  void cancel() {
    cancelled = true;
    active?.cancel();
    plainActive?.cancel();
    owned?.close();
  }

  Future<Socket> connect() async {
    Object? last;
    for (final address in addresses) {
      if (cancelled) throw const SocketException('Connection cancelled');
      var abandoned = false;
      try {
        if (uri.scheme != 'https') {
          plainActive = await Socket.startConnect(address, uri.port);
          if (cancelled) plainActive!.cancel();
          return await plainActive!.socket
              .then((socket) {
                if (cancelled || abandoned) {
                  socket.destroy();
                  throw const SocketException('Connection cancelled');
                }
                return socket;
              })
              .timeout(timeout);
        }
        active = await RawSocket.startConnect(address, uri.port);
        if (cancelled) active!.cancel();
        final tcp = await active!.socket.timeout(timeout);
        owned = tcp;
        if (cancelled) throw const SocketException('Connection cancelled');
        final tls = RawSecureSocket.secure(tcp, host: uri.host).then((socket) {
          if (cancelled || abandoned) {
            socket.close();
            throw const SocketException('Connection cancelled');
          }
          return socket;
        });
        final secured = await tls.timeout(timeout);
        if (cancelled) throw const SocketException('Connection cancelled');
        owned = null;
        return LkTlsSocket(secured);
      } catch (error) {
        abandoned = true;
        active?.cancel();
        plainActive?.cancel();
        await owned?.close();
        owned = null;
        last = error;
      }
    }
    throw SocketException(
      cancelled ? 'Connection cancelled' : 'LK connection failed',
      osError: last is SocketException ? last.osError : null,
    );
  }

  return ConnectionTask.fromSocket(connect(), cancel);
}

class LkDnsFallback {
  LkDnsFallback({this.systemLookup = InternetAddress.lookup, this.query});
  final Future<List<InternetAddress>> Function(String) systemLookup;
  final Future<Map<String, dynamic>> Function(Uri)? query;
  final _cache =
      <String, ({DateTime expires, List<InternetAddress> addresses})>{};

  Future<List<InternetAddress>> lookup(String host) async {
    try {
      final result = await systemLookup(host)
          .timeout(const Duration(seconds: 3));
      if (result.isNotEmpty) return result;
    } catch (_) {
      /* Try HTTPS DNS only for an explicitly built-in LK host. */
    }
    if (!lkDnsHosts.contains(host)) {
      throw const SocketException('DNS lookup failed');
    }
    final cached = _cache[host];
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      return cached.addresses;
    }
    for (final origin in [
      'https://dns.alidns.com/resolve',
      'https://doh.pub/dns-query',
      'https://cloudflare-dns.com/dns-query',
      'https://dns.google/resolve',
      'https://1.1.1.1/dns-query',
    ]) {
      try {
        final uri = Uri.parse(origin)
            .replace(queryParameters: {'name': host, 'type': 'A'});
        final data = await (query ?? _query)(uri)
            .timeout(const Duration(seconds: 5));
        final addresses = parseDnsAnswers(data);
        if (addresses.isEmpty) continue;
        final ttl = (data['Answer'] as List)
            .whereType<Map<Object?, Object?>>()
            .where((a) => a['type'] == 1)
            .map((a) => (a['TTL'] as num?)?.toInt() ?? 30)
            .fold(60, (a, b) => a < b ? a : b)
            .clamp(1, 60);
        _cache[host] = (
          expires: DateTime.now().add(Duration(seconds: ttl)),
          addresses: addresses,
        );
        return addresses;
      } catch (_) {
        /* The second resolver has an independent network path. */
      }
    }
    throw const SocketException('LK DNS lookup failed');
  }

  static List<InternetAddress> parseDnsAnswers(Map<String, dynamic> data) {
    if (data['Status'] != 0 || data['Answer'] is! List) return [];
    return [
      for (final answer
          in (data['Answer'] as List).whereType<Map<Object?, Object?>>())
        if (answer['type'] == 1 && answer['data'] is String)
          if (InternetAddress.tryParse(answer['data'] as String)
              case final address?)
            if (isPublicV4(address)) address,
    ];
  }

  static bool isPublicV4(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) return false;
    final b = address.rawAddress;
    return b[0] != 0 &&
        b[0] != 10 &&
        b[0] != 127 &&
        b[0] < 224 &&
        !(b[0] == 169 && b[1] == 254) &&
        !(b[0] == 172 && b[1] >= 16 && b[1] <= 31) &&
        !(b[0] == 192 && b[1] == 168) &&
        !(b[0] == 100 && b[1] >= 64 && b[1] <= 127);
  }

  Future<Map<String, dynamic>> _query(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    final deadline = Timer(const Duration(seconds: 5), () {
      client.close(force: true);
    });
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set('Accept', 'application/dns-json');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw const FormatException('DNS response failed');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 32768) {
          throw const FormatException('DNS response too large');
        }
      }
      return (jsonDecode(utf8.decode(bytes)) as Map<Object?, Object?>)
          .cast<String, dynamic>();
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }
}
