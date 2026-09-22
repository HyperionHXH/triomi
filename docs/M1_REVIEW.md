# M1 复查记录（规则引擎与数据通路）

日期：2026-09-22 ｜ 对应任务：T2 ｜ 状态：**已完成声明式规则部分，JS 沙箱延后**

## 1. 本轮交付

| 模块 | 文件 | 说明 |
|---|---|---|
| 领域模型 | `core/models/media_item.dart`、`chapter.dart`、`source_descriptor.dart`、`source_exception.dart` | 作品 / 章节（含卷→章两级）/ 来源描述与能力 / 分类明确的来源异常 |
| 来源契约 | `core/source/source_api.dart` | Discover / Search / Detail / Content / Account 能力接口（对齐 Mixn 的能力式契约） |
| 选择器引擎 | `core/source/selector_engine.dart` | **CSS 与 XPath 双语法**统一；字段提取（text/html/属性、正则、捕获组、绝对地址补全）；正文 HTML→纯文本 |
| 规则模型 | `core/source/rule_schema.dart` | 声明式 JSON 规则解析 + **结构自检**（能力声明必须与规则内容一致）+ 请求模板渲染 |
| 执行器 | `core/source/declarative_source.dart` | 榜单 / 搜索 / 详情 / 目录 / 正文全链路；HTML 与 JSON 两种响应 |
| 网络层 | `core/source/http_client.dart` | dio 实现 + 抽象（测试可注入固定响应）；状态码 → 错误分类 |
| 注册表 | `core/source/source_registry.dart`、`source_repository.dart` | 内置示例规则播种、导入校验、启停/删除；**坏规则作为可见失败项而不是静默消失** |
| 页面 | `features/sources`、`discover`、`search`、`detail` | 来源管理（粘贴 / 剪贴板 / URL 导入）、分站榜单、聚合搜索（逐源成败）、详情 + 目录 |
| 文档 | `docs/RULE_FORMAT.md` | 规则编写指南（写规则的人看这份就够） |

## 2. 验收结果

| 检查项 | 结果 |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test` | **21 passed**（M0 的 5 个 + 本轮 16 个） |
| `dart format` | 0 变更 |
| `flutter build web` | 成功（预览通道可用） |

**被测试真实覆盖的行为**（不是「能编译」，而是断言了行为）：

- CSS 与 XPath（文档级 `//div[...]`、相对级 `.//a`、属性级 `//a/@href`）选择与取值
- `img@data-src` 简写解析、正则 + 捕获组提取、相对/协议相对地址补全
- 正文 HTML→纯文本（段落换行、实体还原）
- 规则解析：缺字段、类型非法、非 JSON 文本的报错信息；**能力声明与规则内容不一致会被自检拒绝**
- 请求模板渲染（`{keyword}` 编码、`{page}`、`{offset}`）
- HTML 源全链路：搜索 → 详情（字段补全）→ 目录（含章节号解析）→ 正文（图片选择器兜底）
- JSON 源全链路：**随包分发的 Bangumi 规则**能通过自检，并用固定响应跑通
  搜索（校验 POST 请求体与 offset 计算）→ 详情 → 剧集目录
- 标题 `name` 兜底（`name_cn` 为空时不丢条目）、空 `airdate` 不产生脏数据

## 3. 复查中发现并修复的问题

| # | 问题 | 性质 | 处理 |
|---|---|---|---|
| 1 | **URL 模板先补全再替换**，导致 `{urlRaw}` 被当成路径转义（`%7BurlRaw%7D`） | 逻辑缺陷（推理时发现，尚未造成事故） | 改为「先替换占位符、再补全相对地址」 |
| 2 | `app_database.g.dart` 缺 `MediaType` 类型 —— **analyzer 排除了生成文件，静态分析没有报错**，直到跑测试才暴露 | 构建链路风险 | 补齐 `app_database.dart` 的 import；并把「改表后必须跑测试」写入约定 |
| 3 | 发现页与搜索页各写了一份响应式列表 → 排版迟早会不一致 | 重复实现 | 抽出 `MediaItemCollection` 共用 |
| 4 | `flutter_js` 装了但无人使用 | 死依赖（且是原生插件，会破坏 web 预览） | 移除依赖，JS 沙箱作为 T2b 单独立项 |
| 5 | 格式化后 `if (...) return ...;` 触发 lint、未用的 import / 私有方法 | 卫生问题 | 逐一修掉，analyze 归零 |
| 6 | 测试替身缺失导致外壳测试被加载动画卡死（`pumpAndSettle` 超时） | 测试设计问题 | 用空来源快照覆盖 provider，让外壳测试与数据库/资产解耦 |

## 4. 已知缺口（诚实记录）

1. **JS 扩展源尚未支持**。本轮把「声明式 JSON 规则」做成了完整可用的引擎（HTML + JSON 接口、跨平台含 Web）。
   JS 沙箱需要原生引擎，而**本机没有真机 / 桌面工具链可验证**，因此没有先写一份无法验证的实现。
   计划（T2b）：抽象 `ScriptRuntime` → `flutter_js`（QuickJS）实现 + Web 端 stub，
   注入受限宿主 API（`fetch` / `css` / `xpath` / `log`），并明确「导入 JS 规则时若平台不支持则拒绝并说明原因」。
   **必须在一台能跑 Android 或 Windows 的机器上做。**
2. **数据库读写没有自动化测试**。`sources` 表的 upsert / 查询只有编译级保证；
   单元测试里跑 drift 需要宿主 sqlite3 动态库，本机未配置。
   计划：引入 `sqlite3_flutter_libs` 或在测试中显式 `open.overrideFor`，补一个用内存库的仓储测试。
3. **未对真实站点做联网验证**。引擎行为用固定响应夹具验证；内置 Bangumi 规则是按官方 v0 接口文档写的，
   但「真实网络下是否可用」需要在能联网运行的机器上确认一次（这也是把 `User-Agent` 写进规则的原因：
   Bangumi 接口要求带 UA）。
4. **Web 预览只能看壳**：drift 在 Web 需要 sqlite3 WASM 资源，未配置时来源注册表会报错，
   因此 Web 端只适合验证布局与主题，功能验证要走 Android / Windows。
5. 详情页的「加入书架」按钮为禁用状态（M2 随书架开放）。

## 5. 下一步

- **M2（漫画闭环）**：阅读器四模式、书架（drift 落库）、阅读进度、历史；届时补 DB 仓储测试与第一次改表的 migration。
- **T2b（JS 沙箱）**：需可运行的设备。
- 隐患提醒：`PageScaffold` 之外若新增页面自行拼 AppBar，桌面端观感会走样 —— 新页面一律走 `PageScaffold`。
