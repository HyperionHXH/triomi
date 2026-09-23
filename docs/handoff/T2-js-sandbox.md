# T2 · JS 规则沙箱（T2b）

> **状态：✅ 已完成（2026-09-23）。** 宿主探测结果（本机关键信息）：
> **Windows 宿主可用真实 quickjs**——flutter_js 0.8.7 随包自带
> `windows/shared/quickjs_c_bridge.dll`，复制到项目根（DLL 搜索路径包含
> cwd）即可，无需 Visual Studio 构建 Windows runner
> （一键脚本：`python tools/setup_quickjs_dll.py`）。
> 必须用 `getJavascriptRuntime(xhr: false)` 构造——flutter_js 自带的
> fetch polyfill 依赖 rootBundle（测试环境没有），且网络统一走宿主桥。
> 真实引擎全流程测试 `test/t2_js_engine_test.dart` 全绿，未启用 skip 分支。
> 对应规格：PROJECT_SPEC 3.2（`flutter_js` 已在依赖表）、路线图 M1 验收、
> 原任务单「T2b JS 规则沙箱（需设备验证）」。
> 现状：声明式规则引擎已完成（HTML/JSON + CSS/XPath）；M1 时 flutter_js
> 依赖因「未使用」被移除，现在正式接入。目标：声明式 + JS **双轨规则**。

## 现状（已就位）

- 能力契约：`lib/core/source/source_api.dart`
  （`DiscoverProvider / SearchProvider / DetailProvider / ContentProvider /
  AccountProvider / ChapterUnlockProvider`）。
- 声明式执行器：`lib/core/source/declarative_source.dart`
  （规则 JSON → 各能力方法）；规则格式文档 `docs/RULE_FORMAT.md`。
- 选择器引擎：`lib/core/source/selector_engine.dart`（CSS + XPath 双语法，
  可作为宿主函数暴露给 JS）。
- 注册表：`lib/core/source/source_registry.dart`（数据库 rules 表 →
  SourceEntry；已有 `builtinAdapters` 双轨先例：LK 适配器就是这么挂的）。
- 来源管理页会把加载失败的规则作为可见失败项展示（坏规则不能静默消失）。

## 范围

### 做
1. JS 运行时封装（可注入抽象 + flutter_js 实现）。
2. `JsSource`：用 JS 规则实现与声明式相同的能力契约。
3. 规则加载路径：注册表支持 JS 规则（与声明式并存、失败可见）。
4. 单元测试（引擎可注入 stub，规则契约用真实 JS 引擎跑通则更好——见
   「引擎与测试的取舍」）。

### 不做
- 设备端到端验证（归本机：模拟器跑通一条 JS 规则并截图）。
- JS 沙箱的资源限制（内存/CPU 限额）——quickjs 本身隔离已够用，
  恶意规则治理不在本期。

## 实现规格

### 1. 运行时抽象 — `lib/core/source/js/js_runtime.dart`

```dart
/// 注入宿主函数后的最小 JS 引擎抽象（测试可注入 fake）。
abstract class JsRuntime {
  /// 加载规则源码（模块上下文，可多次 evaluate 同一实例内复用全局状态）。
  Future<void> load(String script, {required String name});
  /// 调用规则导出函数；args 按位置传 JSON 可序列化值；返回 JSON 可序列化值。
  /// JS 端可以是 async 函数（引擎需等待 promise）。
  Future<Object?> call(String function, List<Object?> args);
  void dispose();
}
```

flutter_js 实现要点：
- 用 `getJavascriptRuntime()`；宿主函数用 `onMessage` 通道注册
  （`triomiFetch` / `triomiCss` / `triomiXpath`）。
- **fetch 必须走 `SourceHttpClient`**（统一 UA / 超时 / 错误分类），
  通过 `JavascriptChannel` 或 `onMessage` 回传 `{status, body}`。
  flutter_js 的 channel 是同步回调，**异步 fetch 用
  `runtime.evaluateAsync` + promise 模式**：JS 端 `await triomi.fetch(url)`，
  宿主侧用 `sendMessage` 回推结果 resolve——flutter_js 自带
  `handlePromise`，按其官方推荐模式封装即可。
- 引擎不可用（Windows 测试环境缺原生库）时构造要可捕获并降级（见下）。

### 2. JS 规则契约（文档同步进 `docs/RULE_FORMAT.md`）

规则文件 = 元数据 JSON（与声明式同格式，`"engine": "js"` 标识）+ JS 源码
（同目录同名 `.js`，或 JSON 内嵌 `"script"` 字段——任选其一并在文档中定死）。

JS 侧导出（Miru 思路简化版）：

```js
// 每个函数对应一个能力；缺省即该能力不可用（与声明式的缺省语义一致）
async function discover(url, page)   // → MediaItem[]（字段对齐现有模型）
async function search(keyword, page) // → MediaItem[]
async function detail(url)           // → { item: MediaItem, chapters: Chapter[] }
async function content(url)          // → { images?|text?|html?|playSources?|danmakuUrl? }
```

宿主注入全局 `triomi`：
`triomi.fetch(url, {method, headers, body}) → Promise<{status, body}>`、
`triomi.css(html, selector) → string[]`、`triomi.xpath(html, query) → string[]`、
`triomi.attr(html, selector, attr)` 便捷函数（可选）。

MediaItem / Chapter 的 JSON 字段名与 `lib/core/models/` 现有序列化保持一致
（`sourceId / remoteId / type / title / url / coverUrl / author / description /
tags / rating / status`）。

### 3. JsSource — `lib/core/source/js/js_source.dart`

实现 `DiscoverProvider / SearchProvider / DetailProvider / ContentProvider`
（按 JS 端实际导出的函数决定 `capabilities` 集合；`descriptor.capabilities`
在加载时探测）。错误：JS 抛异常 → `SourceException(type: parse, 附 JS 栈
摘要)`；fetch 失败 → 透传宿主分类错误。

### 4. 注册表双轨

- rules 表 `rule_text` 存 JSON 元数据（含 `engine: "js"` 与 `script` 内嵌
  或 script 引用）；`SourceRegistry.load()` 按 `engine` 字段分流到
  DeclarativeSource / JsSource。
- **失败可见**：JS 语法错 / 引擎不可用 → 记为 SourceFailure（与声明式一致）。
- 随包示例规则：声明式在 `assets/rules/*.json`；加一条
  `assets/rules/example-js.json`（debug 播种，走夹具站点，见 `tools/
  dev_fixture_server.py` 的 manga 端点）。

### 引擎与测试的取舍（重要）

- **引擎必须可注入**：`JsSource(JsRuntime engine)`。单测里用
  `FakeJsRuntime`（预录函数返回值）验证 JsSource 的映射、能力探测、错误分类。
- **真实 JS 引擎测试**：flutter_test 在 Windows 上能否加载 flutter_js 的
  quickjs 原生库**未验证**。先写 `test/js_engine_probe_test.dart` 探测：
  能加载就跑真实规则全流程（发现→详情→正文）；加载不了就把该测试标记
  `skip: 'flutter_js 原生库在宿主不可用'`，设备侧（本机）再验。
- 交付说明里明确写探测结果（这是本机接手时的关键信息）。

## 测试要求

1. JsSource 映射：discover 返回的 JSON → MediaItem（含 tags/rating/可选字段）。
2. 能力探测：只导出 search/detail 的规则，capabilities 恰为这两个。
3. JS 异常 → SourceErrorType.parse，消息含函数名；宿主 fetch 抛 auth 错误
   时原样透传不降级成 parse。
4. 加载失败进注册表失败列表（规则含语法错）。
5. （可跳过）真实引擎跑通夹具站点的示例规则全流程。

## 验收标准

- analyze 零问题；测试全绿；`docs/RULE_FORMAT.md` 增补 JS 规则章节。
- 声明式规则的现有测试（m1_test 等）不回归。

## 后续集成点

- 本机：模拟器跑示例 JS 规则全流程截图；若 flutter_js Windows 库不可用，
  仅影响宿主测试，Android 设备侧 flutter_js 有 arm64/x86_64 预编译库。
