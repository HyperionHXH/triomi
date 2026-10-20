import 'dart:io';

import '../js_runtime.dart';
import 'ios_js_runtime.dart';
import 'process_js_runtime.dart';
export 'flutter_js_runtime.dart' show FlutterJsRuntime;

JsRuntime createFlutterJsRuntime() {
  if (Platform.isAndroid || Platform.isWindows) return ProcessJsRuntime();
  if (Platform.isIOS) return IosJsRuntime();
  throw UnsupportedError('当前平台尚未提供可终止的 JS 子进程');
}
