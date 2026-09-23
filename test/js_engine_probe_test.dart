import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';

/// 探测 flutter_js 的原生库在**宿主测试环境**是否可用。
///
/// flutter_js 在 Windows 上以 `DynamicLibrary.open('quickjs_c_bridge.dll')`
/// 加载预编译库（随包分发在 pub cache 的 `windows/shared/` 下），而 DLL
/// 搜索路径包含当前工作目录——所以把它复制到项目根即可，不需要构建
/// Windows runner（本机没有 Visual Studio 也无妨）。
///
/// 一键安装：`python tools/setup_quickjs_dll.py`
void main() {
  test('flutter_js 原生库探测', () {
    JavascriptRuntime? runtime;
    try {
      // xhr: false —— 自带 fetch polyfill 需要 rootBundle（测试环境没有），
      // 我们的宿主桥也不依赖它（网络统一走 SourceHttpClient）。
      runtime = getJavascriptRuntime(xhr: false);
    } catch (error) {
      // ignore: avoid_print
      print(
        'PROBE_RESULT: UNAVAILABLE ($error)\n'
        '修复：python tools/setup_quickjs_dll.py 后重试',
      );
      return;
    }
    final result = runtime.evaluate('1 + 1');
    // ignore: avoid_print
    print(
      'PROBE_RESULT: ${result.isError ? 'ERROR' : 'OK'} '
      'string=${result.stringResult}',
    );
    runtime.dispose();
  });
}
