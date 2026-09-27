# dpsk 交接文档 · 总览

> 这份文档是给 **dpsk** 的工作单。Triomi 主线路 M0–M5 已完成（见
> `docs/M*_REVIEW.md`），本目录收录剩余缺口任务 T1–T6。每个任务一份独立
> 文档，含现状、范围、实现规格、测试要求与验收标准。
> **先读完本页再开工。**

## 项目速览

- **Triomi**：「追番 + 漫画 + 小说」聚合客户端，Flutter（go_router + Riverpod 3 +
  drift + Hive），GPL-3.0。规格书：`docs/PROJECT_SPEC.md`（验收标准的最终依据）。
- 代码：`lib/`（78 文件）；测试：`test/`（15 文件 / 199 用例全绿）；
  参考实现（Mixn，Kotlin）：`D:\noval_and_manga\_refs\mixn`。
- 当前 HEAD：`1e4a67d`（feat(T5): 轻之国度账号域接口层）。
- **交接单 T1–T7 已全部完成**（T4/T5 的协议层与接口层已交付，剩余的是需要
  真实账号/设备的联调与页面接线，见各自文档的「后续集成点」）。

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
| T4 | LNS SignalR 适配器协议层 | ✅ **已完成**（[T4-lns-signalr.md](T4-lns-signalr.md)） | 联调需 LNS 账号 |
| T5 | LK 账号域接口层 | ✅ **已完成**（[T5-lk-account.md](T5-lk-account.md)） | 联调需 LK 账号 |
| T6 | 阅读器增强逻辑 + 凭据安全迁移 | ✅ **已完成**（[T6-reader-security.md](T6-reader-security.md)） | — |
| T7 | 杂项收口（追番订阅/到底提示/同书版本/SAF 导出/在线字体/备份开关/后台提醒桩） | ✅ **已完成**（[T7-misc-cleanup.md](T7-misc-cleanup.md)） | 无 |

**全部任务已完成。** 剩余工作都需要真实账号或设备，由本机环境接手：

- LNS：登录/发现/详情/正文/书架/签到联调；fontUrl 接入阅读器渲染；
  `defaultDisabledBuiltins` 翻转；页面入口。
- LK：资料页、消息中心、详情页评论 Tab（接口已在 `LkSource` 就位）。
- T7：SAF 目录选择/写入与在线字体下载的模拟器 E2E。

## 本机（设备环境）已完成的部分

- **W6 轻之国度账号域页面**（commit `1788b31`）：资料页（余额/关注/粉丝 +
  七日签到 + 领取）、消息中心（分类未读角标）、详情页评论区（最热/最新、
  分页、星级、发表、点赞）；我的页新增「轻之国度」分组。
- **Android 构建修复**（commit `fccb595`）：`MainActivity` 的
  `MethodChannel.Call` 类型写错导致 T6/T7 的 Kotlin 从未编译过；`flutter_js`
  0.8.7 的 Java 11 / Kotlin 1.8 target 冲突用
  `kotlin.jvm.target.validation.mode=warning` 解除。**T2 之后 Android 构建
  一直是坏的**，本次才恢复。
- **LK 正文参数缺陷修复**：`content()` 曾把章节号同时当作品号发给
  `get-chapter-detail`（实测请求为 `book_id=3001&chapter_id=3001`），现章节键
  带作品号（`作品号:章节号`），实测变为 `book_id=1001&chapter_id=3001`。
- **夹具**：新增 `tools/lk_fixture.py`（LK pc-proxy / pc-comment-proxy 全端点）
  与 `tools/lk_fixture_selftest.py`；LK base 支持
  `--dart-define=TRIOMI_LK_BASE=http://10.0.2.2:8123/lk`。
- **W7 消息中心补全**：T5 遗留的「分类消息列表 + 标读」接口层与页面已接上——
  `LkClient.messages/dmConversations/dmMessages/markCategoryRead`
  （分类消息走 `message-replies-v1` / `message-likes-v1` / `message-fans-v1` /
  `message-system-v1`，@ 用 `filter=mention` 区分；标读带 `ts` + `nonce`）；
  页面为消息中心 → 分类列表（分页、加载更多、显式「全部标为已读」）与
  私信会话 → 只读线程；通知里只有 `target_book_id` 才跳作品详情，
  章节 / 动态这类定位不构造猜测路由。私信发送按 Mixn 的边界明确不做。
  夹具包设备验证：消息中心（6 分类角标）→ 回复分类列表（未读底色、
  引用块、关联作品）→「全部标为已读」二次确认后夹具落库
  （`message-mark-read-v1` / category=reply、未读 8 → 6）→ 私信会话 →
  只读线程（左右气泡 + 只读说明），全部通过。
- **模拟器端到端已验证**：登录 → 资料/签到（夹具侧余额 138、streak 3 落库）
  → 消息中心未读 → 远端书架进详情（同书版本/标签）→ 评论区渲染 → 发表评论
  （夹具记录到内容）→ 点赞 501 → 打开章节（正文接口参数正确）。

### 真实账号联调结果（LK，2026-09-27）

在真实站点（`www.lightnovel.fun`）用真实账号跑通：

| 路径 | 结果 |
|---|---|
| 资料页 | 昵称/UID/等级/轻币正常；关注·粉丝·发布显示「—」（站点未返回或为 0，与 Mixn 同策略） |
| 七日签到 | 领取成功，轻币 1668 → 1806（+138），第 1 天转「已领」，按钮转「今日已签到」 |
| 消息中心 | 未读汇总解析正常（该账号当前全 0，逐类显示「无未读」） |
| 远端书架 | 拉到站点收藏 2 本，封面/作者正常 |
| 详情页 | 封面/标签/简介正常；同书版本（B1）在真实站点有数据；目录 58 章 |
| 评论区 | 最热/最新标签、真实评论（含时间与点赞数）正常渲染 |
| 点赞 | 真实写入生效：点赞 0 → 1，取消 → 0 |
| 正文 | 章节 8 页完整渲染；`book_id`/`chapter_id` 修复在真实站点生效 |
| 发现页 | LK 榜单（热门/日榜/周榜/新人新作/最近更新）与封面全部正常 |

未做：**发表评论**（真实账号的公开发言，属外部可见写入）与**加入书架**
（站点侧写入）未在自动验证中执行，待用户确认后单独跑。

环境注意：`api.bgm.tv` 在本机网络下首个 A 记录
（`98.159.108.71`）不可达，模拟器直连会一直停在加载态（Dart 的
connectTimeout 覆盖不到 DNS 阶段的黑洞地址），「追番」页因此无法在本机
直接做 E2E；需要时用 `--dart-define=TRIOMI_SCHEDULE_BASE` 指到本机中继。
