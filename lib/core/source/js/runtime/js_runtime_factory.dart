// JS 引擎工厂：按平台条件导出。
//
// flutter_js 依赖 `dart:ffi`，Web 上无法编译，因此这里必须做条件导入，
// 否则 `flutter build web`（本项目的浏览器预览通道）会直接失败。
export 'js_runtime_factory_stub.dart'
    if (dart.library.io) 'js_runtime_factory_io.dart';
