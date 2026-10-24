import 'dart:io';

import 'package:flutter/services.dart';

/// Resolve only the user's OS proxy configuration. No endpoint probing,
/// credentials, target headers or response bodies cross the platform channel.
Future<String> systemProxyForUri(Uri uri) async {
  if (!(Platform.isWindows || Platform.isAndroid) ||
      !{'http', 'https'}.contains(uri.scheme)) {
    return 'DIRECT';
  }
  // IO tools and isolates need no Flutter binding just to use HTTP. Probe
  // accessors only: genuine errors from an available platform stay errors.
  late final BinaryMessenger messenger;
  try {
    messenger = ServicesBinding.instance.defaultBinaryMessenger;
  } on Object {
    try {
      messenger = BackgroundIsolateBinaryMessenger.instance;
    } on StateError {
      return 'DIRECT';
    }
  }
  return _systemProxyWithMessenger(uri, messenger);
}

Future<String> _systemProxyWithMessenger(
  Uri uri,
  BinaryMessenger messenger,
) async {
  final Map<String, Object?>? raw;
  try {
    raw =
        await MethodChannel(
          'triomi/platform',
          const StandardMethodCodec(),
          messenger,
        ).invokeMapMethod<String, Object?>('resolveSystemProxy', {
          'url': uri.replace(userInfo: '').removeFragment().toString(),
        });
  } on MissingPluginException {
    return 'DIRECT';
  }
  if (raw == null) return 'DIRECT';
  return systemProxyDirective(uri, raw);
}

/// WinHTTP resolves PAC itself; static settings retain their protocol mapping
/// and bypass list. Unsupported/malformed proxy settings are reported, never
/// silently changed to a different route.
String systemProxyDirective(Uri uri, Map<String, Object?> settings) {
  if (settings['direct'] == true) return 'DIRECT';
  final bypass = '${settings['bypass'] ?? ''}';
  final host = uri.host.toLowerCase();
  for (final entry in bypass.split(RegExp(r'[;\s]+'))) {
    final rule = entry.toLowerCase();
    if (rule.isEmpty) continue;
    if (rule == '<local>' && !host.contains('.') && !host.contains(':')) {
      return 'DIRECT';
    }
    if (rule == '[::1]' && host == '::1') {
      return 'DIRECT';
    }
    final pattern = RegExp(
      '^${RegExp.escape(rule).replaceAll(r'\*', '.*').replaceAll(r'\?', '.')}\$',
    );
    if (pattern.hasMatch(host) ||
        pattern.hasMatch('$host:${uri.port}') ||
        pattern.hasMatch('${uri.scheme}://$host') ||
        pattern.hasMatch('${uri.scheme}://$host:${uri.port}')) {
      return 'DIRECT';
    }
  }
  final text = '${settings['proxy'] ?? ''}'.trim();
  if (text.isEmpty) return 'DIRECT';
  final entries = text.split(RegExp(r'[;\s]+')).where((e) => e.isNotEmpty);
  final selected = <String>[];
  for (final entry in entries) {
    final separator = entry.indexOf('=');
    if (separator >= 0) {
      if (entry.substring(0, separator).toLowerCase() == uri.scheme) {
        selected.add(entry.substring(separator + 1));
      }
    } else if (!text.contains('=')) {
      selected.add(entry);
    }
  }
  if (selected.isEmpty) return 'DIRECT';
  return selected
      .map((entry) {
        final endpoint = Uri.tryParse(
          entry.contains('://') ? entry : 'http://$entry',
        );
        if (endpoint == null ||
            endpoint.scheme != 'http' ||
            endpoint.host.isEmpty ||
            endpoint.userInfo.isNotEmpty ||
            (endpoint.path.isNotEmpty && endpoint.path != '/') ||
            endpoint.hasQuery ||
            endpoint.hasFragment ||
            endpoint.port < 1 ||
            endpoint.port > 65535) {
          throw const FormatException('系统代理地址无效或不支持');
        }
        final proxyHost = endpoint.host.contains(':')
            ? '[${endpoint.host}]'
            : endpoint.host;
        return 'PROXY $proxyHost:${endpoint.port}';
      })
      .join('; ');
}
