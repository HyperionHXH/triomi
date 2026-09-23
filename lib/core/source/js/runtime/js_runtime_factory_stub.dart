import '../js_runtime.dart';

/// Web 平台没有原生 JS 引擎：flutter_js 走 `dart:ffi`，浏览器上不可用。
///
/// 声明式规则不依赖 JS 引擎，因此在 Web 上仍完全可用；只有 JS 规则会
/// 作为「引擎不可用」的失败项出现在来源管理页。
JsRuntime createFlutterJsRuntime() => throw UnsupportedError('当前平台不支持原生 JS 引擎');
