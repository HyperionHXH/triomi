# dpsk 交接文档 · 总览

> 这份文档是给 **dpsk** 的工作单。Triomi 主线路 M0–M5 已完成（见
> `docs/M*_REVIEW.md`），本目录收录剩余缺口任务 T1–T6。每个任务一份独立
> 文档，含现状、范围、实现规格、测试要求与验收标准。
> **先读完本页再开工。**

## 项目速览

- **Triomi**：「追番 + 漫画 + 小说」聚合客户端，Flutter（go_router + Riverpod 3 +
  drift + Hive），GPL-3.0。规格书：`docs/PROJECT_SPEC.md`（验收标准的最终依据）。
- 代码：`lib/`（70 文件 / 24.5k 行）；测试：`test/`（13 文件 / 80 用例全绿）；
  参考实现（Mixn，Kotlin）：`D:\noval_and_manga\_refs\mixn`。
- 当前 HEAD：`933242e`（docs: 执行评估与下一步规划）。

## 分工边界（重要）

**dpsk 负责**：纯代码层（数据层 / 协议层 / 引擎层 / 解析层）+ **单元测试**。
**不**负责：UI 页面接线、APK 构建、模拟器端到端验证——这些由本机环境（Kimi）
在 dpsk 交付后接手（交接文档里的「后续集成」一节说明接口预留方式）。

规则：**没写完代码+单测的任务不算完成**；遇到规格与代码冲突，以
`docs/PROJECT_SPEC.md` 为准并在交付说明里记录分歧。

## 环境与命令（Windows，Git Bash）

```bash
cd D:/noval_and_manga/triomi
FLUTTER="C:/Users/MiunaH/.workbuddy/binaries/flutter/sdk/bin/flutter.bat"
DART="C:/Users/MiunaH/.workbuddy/binaries/flutter/sdk/bin/dart.bat"

# 静态分析（必须零问题）
"$FLUTTER" analyze

# 测试（**必须先清代理**，否则报 Invalid WebSocket upgrade request）
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy NO_PROXY no_proxy
"$FLUTTER" test --reporter compact

# 格式化（提交前必跑）
"$DART" format .
```

- 拉依赖：`"$FLUTTER" pub get`（也要先 `unset` 代理）。
- 数据库测试用 `NativeDatabase.memory()`，基建在 `test/fixtures/test_database.dart`，
  直接可用，无需配置 sqlite3。
- 假 HTTP 客户端在 `test/fixtures/fake_http_client.dart`（含 `bytesHandler` /
  `uploads` 断言）；内存 Preferences 在 `test/fixtures/fake_preferences.dart`。

## 代码约定（必须遵守）

1. **业务键一律 `(sourceId, remoteId)` 复合键**，禁止只用 `remoteId`。
2. **来源错误必须分类**（`lib/core/models/source_exception.dart` 的
   `SourceErrorType`）；聚合操作允许部分成功。
3. **凭据不落日志、不进缓存/崩溃报告**（密码 / token / security_key）。
4. 设计令牌单一来源 `lib/core/theme/app_tokens.dart`，禁止硬编码颜色与尺寸。
5. 表结构改动：改 `lib/core/db/tables.dart` → `schemaVersion + 1` →
   `migration.onUpgrade` 补一步 → `dart run build_runner build` → **跑
   `flutter test`**（analyzer 排除 `*.g.dart`，生成代码的编译错误只在测试编译时暴露）。
6. 每个任务**独立 commit**，信息用中文、结构为 `feat(模块): 摘要`；
   提交前 `dart format .` + analyze 零问题 + 测试全绿。
7. **不要**改动 `docs/` 以外的文档文件；**不要**提交 `tools/_dav/`、
   `build/`、临时截图等产物。
8. 新增依赖要评估插件化成本：优先纯 Dart 包；插件包在交付说明里标注
   （Windows 开发者模式未开启，含 Windows 平台插件的包会触发符号链接警告，
   Android 不受影响）。

## 交付说明格式（每个任务交付时附在 commit body 或交付回复里）

```
任务: T<n> <标题>
完成范围: <做了什么，引用文件>
测试: <新增/修改的测试，flutter test 结果>
未做/偏差: <明确列出，含原因>
后续集成点: <本机接手时要接的接口/类名>
```

## 任务清单

| # | 任务 | 文档 | 依赖 |
|---|---|---|---|
| T1 | 追踪服务（Bangumi / AniList 进度上报） | ✅ **已完成**（[T1-tracking-service.md](T1-tracking-service.md)） | — |
| T2 | JS 规则沙箱 | ✅ **已完成**（[T2-js-sandbox.md](T2-js-sandbox.md)） | — |
| T3 | 弹幕发送（弹弹play 登录补全） | ✅ **已完成**（[T3-danmaku-send.md](T3-danmaku-send.md)） | — |
| T4 | LNS SignalR 适配器协议层 | [T4-lns-signalr.md](T4-lns-signalr.md) | 可先做协议层，联调需账号 |
| T5 | LK 账号域接口层 | [T5-lk-account.md](T5-lk-account.md) | 可先做接口层，联调需账号 |
| T6 | 阅读器增强逻辑 + 凭据安全迁移 | ✅ **已完成**（[T6-reader-security.md](T6-reader-security.md)） | — |
| T7 | 杂项收口（追番订阅/到底提示/同书版本/SAF 导出/在线字体/备份开关/后台提醒桩） | [T7-misc-cleanup.md](T7-misc-cleanup.md) | 无 |

建议顺序：**T1 → T2 → T3 → T6 → T7 → T4 → T5**（T1/T2 是验收硬缺口；
T7 各项可穿插；T4/T5 的联调部分等账号）。
