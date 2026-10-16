import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_adapter_io.dart';
import 'package:triomi/core/source/http_client.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('public LK network paths', (tester) async {
    final result = <String, Object?>{};
    for (final host in [
      'www.lightnovel.fun',
      'cloudflare-dns.com',
      'dns.google',
    ]) {
      try {
        result['dns:$host'] = (await InternetAddress.lookup(
          host,
        ).timeout(const Duration(seconds: 4))).map((a) => a.address).toList();
      } catch (e) {
        result['dns:$host'] = e.runtimeType.toString();
      }
    }
    try {
      result['fallback'] = (await LkDnsFallback().lookup('www.lightnovel.fun'))
          .map((a) => a.address)
          .toList();
    } catch (e) {
      result['fallback'] = e.runtimeType.toString();
    }
    final client = DioSourceHttpClient();
    for (final url in [
      'https://dns.alidns.com/resolve?name=www.lightnovel.fun&type=A',
      'https://cloudflare-dns.com/dns-query?name=www.lightnovel.fun&type=A',
    ]) {
      final probe = HttpClient()
        ..connectionTimeout = const Duration(seconds: 4);
      try {
        final req = await probe.getUrl(Uri.parse(url));
        req.headers.set('Accept', 'application/dns-json');
        final res = await req.close().timeout(const Duration(seconds: 5));
        result['resolver:${Uri.parse(url).host}'] = {
          'status': res.statusCode,
          'bytes': (await res.fold<int>(0, (a, b) => a + b.length)),
        };
      } catch (e) {
        result['resolver:${Uri.parse(url).host}'] = '$e';
      } finally {
        probe.close(force: true);
      }
    }
    try {
      final response = await client.send(
        const SourceRequest(url: 'https://www.lightnovel.fun/'),
        sourceId: 'public-diagnostic',
      );
      result['publicGet'] = response.statusCode;
    } on SourceException catch (e) {
      result['publicGet'] = e.userMessage;
    }
    client.close();
    // Anonymous public request only: no account, cookies, request body or token.
    // ignore: avoid_print
    print('PUBLIC_NETWORK_EVIDENCE ${jsonEncode(result)}');
    expect(result['publicGet'], 200);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
