import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/preferences.dart';
import 'windows_mihon_host.dart';

/// Credentials are deliberately not accepted or persisted in a proxy URL.
String normalizeSourceProxy(String value) {
  final text = value.trim();
  if (text.isEmpty) return '';
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme != 'http' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      !uri.hasPort ||
      uri.port < 1 ||
      uri.port > 65535 ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('请输入 http://主机:端口，不包含账号或路径');
  }
  return Uri(scheme: 'http', host: uri.host, port: uri.port).toString();
}

class SourceProxyController extends Notifier<String> {
  static const key = 'network.sourceProxy';
  @override
  String build() => ref.watch(preferencesProvider).get<String>(key) ?? '';

  Future<void> setProxy(String value) async {
    final proxy = normalizeSourceProxy(value);
    final previous = state;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      await WindowsMihonHost.instance.configureProxy(proxy);
    }
    try {
      await ref.read(preferencesProvider).set(key, proxy);
    } catch (_) {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        await WindowsMihonHost.instance.configureProxy(previous);
      }
      rethrow;
    }
    state = proxy;
  }
}

final sourceProxyProvider = NotifierProvider<SourceProxyController, String>(
  SourceProxyController.new,
);
