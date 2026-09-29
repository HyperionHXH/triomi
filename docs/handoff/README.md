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
| T7 | 杂项收口（追番订阅/到底提示/同书版本/SAF 导出/在线字体/备份开关/后台提醒） | ✅ **已完成**（[T7-misc-cleanup.md](T7-misc-cleanup.md)） | 无 |

**全部任务已完成。** 剩余工作都需要真实账号或设备，由本机环境接手：

- LNS：登录/发现/详情/正文/远端书架/签到 **全部联调完成**，页面入口已补齐
  （通用远端书架页 + 轻书架账号页），来源已默认启用；正文分页溢出 10px 也已修复
  （见「分页正文底部溢出 10px（已修复）」）。
- LK：资料页、消息中心、详情页评论 Tab（含**评论配图**）与真实账号端到端已完成；
  「真实账号发表公开评论（含配图）」**2026-09-28 已补跑并在服务端核验**
  （见「模拟器实测补齐」）。
- 番剧（视频）下载：**代码 + 夹具设备验证已完成**（见「番剧视频离线下载」）。
- 后台更新提醒（D5/T7-7）：**代码 + 夹具设备验证已完成**（见「后台更新提醒」），
  Android 侧已无待做代码项。
- WebDAV 双设备同步：**两台模拟器 + 夹具 WebDAV 已验证**（见「模拟器实测补齐」），
  并顺手修掉了「合并后书架不刷新」的缺陷（commit `c9f8fa2`）。
- 性能：模拟器上取到了冷启动 / 内存 / 帧间隔的参考数字（见「模拟器实测补齐」），
  真机数字仍需真机。
- **仍缺真机**：视频画面合成（模拟器试了 4 种渲染配置都是黑屏，已排除截屏因素，
  见「模拟器实测补齐」）。
- Bangumi 公开数据（追番放送表）：**已加镜像回退**并在模拟器上实测可用
  （见「Bangumi 不可达 → 镜像回退」）。
- 追踪（Bangumi / AniList）：**夹具链路的设备端到端已验证**（绑定 → 状态上报 →
  逐集进度上报 → 宿主回读夹具状态，见「追踪链路设备验证」）；真实站点联调**仍需
  token**（用户给到即可跑），带 token 的请求已接入镜像回退（见「Bangumi 不可达 →
  镜像回退」）。
- 弹幕：规则自带弹幕源（`content.danmaku`）的**渲染链路已在设备上验证**（见「追踪
  链路设备验证」末段）；**发送链路也已在设备上验通**（登录拿 token → 手动匹配 →
  发送，见「弹幕发送链路设备验证」），这条不需要凭据。按条目匹配弹幕需要**内置
  凭据槽位已就位**——用户注册弹弹play 应用后，用 `--dart-define` 注入即可开箱拿弹幕；
  发弹幕仍需用户自己的账号 token（见「弹幕：Kazumi 为什么不用登录」）。
- **Android 10+ 机型复验按用户决定不做**（模拟器已覆盖）。
- Anime4K 番剧超分：用户明确不做，项关闭。
- T7：SAF 目录选择/写入与在线字体下载的模拟器 E2E 已完成。

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
- **W8 站点页面入口**（commit `5b4c543`）：远端书架页去站点化（按
  `remoteShelf` 能力挑来源 + 来源切换条）、新增轻书架账号页（资料 + 签到）、
  LNS 默认启用；设备验证见下文「LNS 页面入口 + 默认启用」。
- **W9 番剧视频离线下载**（commit `52c7466` 起）：流式下载 + 明文 HLS 拼接 +
  播放器离线优先；设备验证见下文「番剧视频离线下载」。
- **W10 LK 评论配图**（commit `32ba17f`）：选图（SAF）→ 上传拿引用 →
  发表时按 `media_json` 回传；设备验证见下文「LK 评论配图」。
- **模拟器端到端已验证**：登录 → 资料/签到（夹具侧余额 138、streak 3 落库）
  → 消息中心未读 → 远端书架进详情（同书版本/标签）→ 评论区渲染 → 发表评论
  （夹具记录到内容）→ 点赞 501 → 打开章节（正文接口参数正确）。

### T7 设备验证结果（模拟器，本次补齐）

| 项 | 结果 |
|---|---|
| T7-1 追番点击链路 | 放送表按星期渲染 → 点条目 → 详情页带正确标题打开（经宿主中继，见上节） |
| T7-4 SAF 目录选择 / 写入 | 选择器建 `Download/triomi-export` → 授权后导出，zip 真实落在 `/sdcard/Download/triomi-export/`（含 `covers/*.jpg` 与 `data.json`），应用私有目录保持为空；**杀进程重启后再导出仍成功**（`takePersistableUriPermission` 生效） |
| T7-5 在线字体下载 | 霞鹜文楷（18.4 MB）下载成功：进入本地字体列表（`LXGWWenKai-Regular.ttf · 18.4 MB`）并出现在预览卡里 |

关于字体下载的观察：本机网络下 18.4 MB 的字体要**几分钟**才下完，
界面在这期间只有按钮上的转圈、没有进度指示。曾试过加「总时长上限」，
但实测会把这种「慢但正常」的下载掐断（20 MB 级别的字体在慢网下必然超时），
因此**没有加**——真正的黑洞连接由 HTTP 层已有的空闲超时兜底，只是缺少进度反馈。

### 后台更新提醒（D5/T7-7，commit `50b3ed8`）

规格原文只有一句「后台更新提醒（默认关闭，Android WorkManager 等价物，
需通知权限）」。T7 设计约束写明**不引入 workmanager 插件**，因此实现如下：

- **排程**（`BackgroundUpdate.kt`）：原生 `JobScheduler` 周期任务，作业 id `7301`，
  12 小时一次、`NETWORK_TYPE_UNMETERED`（仅 WiFi）、`setPersisted(true)`。
  带网络约束必须声明 `ACCESS_NETWORK_STATE`，否则系统抛
  `SecurityException`；缺该权限时设置页开关会回滚并提示（已实测到这一路径）。
- **执行**（`BackgroundUpdateCheckJobService.kt`）：作业触发时建一个
  headless `FlutterEngine`（构造时已自动登记插件，**不要**再手动调
  `GeneratedPluginRegistrant`，否则每个插件都会打一条「already registered」）
  → 按名字执行 Dart 入口 `backgroundUpdateCheck`。Dart 判定有更新就调
  `triomi/background` 的 `notify` 回传标题/正文，最后必须调 `done`；
  原生侧在 `done`（或 60s 超时兜底）后 `jobFinished` + 销毁引擎。
- **入口位置**（踩坑）：入口函数**必须声明在应用入口库**（`lib/main.dart`），
  函数体可以转发到别处（`runBackgroundUpdateCheckEntrypoint`）——放在
  feature 目录里会报 `Could not resolve main entrypoint function`，
  引擎起不来且日志只在 `flutter :` tag 下。
- **检查内容**（`features/schedule/data/background_update_check.dart`）：
  最小 `ProviderContainer`（drift/path_provider 在后台 isolate 里可用）→
  读本地书架中 `bangumi-anime` 来源的追番 → 拉 Bangumi 当日放送 →
  交集非空才产生通知（`今天有 N 部追番更新：《…》`，最多列 3 部）。
  **没有追番 / 当天没数据 / 当天没命中都不打扰**。
- **设置**：`我的 → 备份与恢复 → 后台检查更新`，默认关；开启先申请
  `POST_NOTIFICATIONS`（Android 13+），被拒或排程失败则保持关闭并说明；
  关闭即取消排程。非 Android 平台只保存偏好。

设备验证（模拟器 + 夹具放送表 `--dart-define=TRIOMI_SCHEDULE_BASE=…`）：

| 步骤 | 结果 |
|---|---|
| 开关开启 | 弹出系统通知权限对话框 → 允许后提示「已开启：约每 12 小时检查一次追番更新（仅 WiFi）」 |
| 作业登记 | `dumpsys jobscheduler` 出现 `JOB #…/7301 …BackgroundUpdateCheckJobService`，PERIODIC +12h、PERSISTED、Network NOT_METERED |
| 强制触发 | `adb shell cmd jobscheduler run -f io.github.hyperionhxh.triomi 7301` → 通知 `channel=triomi.updates`，标题「追番更新提醒」、正文「今天有 1 部追番更新：《夹具新番甲（夹具）》」 |
| 任务收尾 | 作业历史出现 `STOP-P … app called jobFinished`（Dart 的 `done` 回调生效，引擎正常销毁） |
| 开关关闭 | 开关置为关闭后 `dumpsys` 中待执行作业归零（排程已取消） |
| 排程失败回滚 | 缺 `ACCESS_NETWORK_STATE` 时开关保持关闭并提示「后台检查排程失败，请稍后重试」（修复前实测） |

**本机可做的验证到此为止**：真机后台调度策略（Doze / 厂商省电）与
「通知权限被拒后的引导」需真机，按用户决定不做 Android 10+ 机型复验。

### 真实账号联调结果（LNS 轻书架，2026-09-27）

用户自己登录后开始联调，**连着修掉三个此前从未在真机跑通过的问题**：

| 问题 | 现象 | 修复 |
|---|---|---|
| hub 地址 scheme | `WebSocket.connect` 只接受 `ws`/`wss`，配置里是 `https://`，直接抛 `Unsupported URL scheme 'https'` → 界面「连接轻书架失败」。**LNS 在设备上从来没有连上过** | 建连前把 scheme 映射成 `wss`（`webSocketUrl`，单测覆盖生产常量） |
| 章节字体地址 | 站点下发的是相对路径 `/font/xxx.woff2`，直接丢给 HTTP 层 → `DioException` → 「章节加载失败」 | 按 API 源站补全为绝对地址（`absoluteUrl`） |
| 章节字体格式 | 引擎（Flutter/Skia）不支持 WOFF2，字体「加载成功」但被忽略 → 正文全是乱码 | 同路径换 `.ttf` 后缀可直接拿到 TrueType（实测两者都在）；加 TTF/OTF magic 校验，拿到 WOFF2 就报错；新增 `ChapterContent.fontFamily` 并由阅读器应用（`fontUrl` 至此才真正接进渲染） |

修完后的真实账号验证：发现榜单（热门/最近更新/最新上架/日榜/周榜）→ 详情
（作者/简介/目录 169 章）→ 正文（1/20 页，字体生效，正文完全可读）。

### LNS 页面入口 + 默认启用（commit `5b4c543`）

上节遗留的两个入口与默认停用标记本次收口：

- **远端书架页泛化**（`lib/features/novel/remote_shelf_page.dart`）：不再写死
  轻之国度，改为按「已启用 + `capability.remoteShelf` + 实现
  `RemoteShelfProvider`」挑来源；多来源时顶部给来源切换条（单来源隐藏），
  未登录给「去登录」引导。「我的 → 数据 → 远端书架」入口文案随之去站点化。
- **轻书架账号页**（`lib/features/novel/lns/lns_account_page.dart`，路由
  `/lns-account`）：资料（用户名 / UID / 轻币 / 连续签到）+ 每日签到；
  「我的」页新增「站点账号」分组，LK 两项也标注站点名。轻书架站点没有
  关注 / 粉丝 / 消息，所以不与 LK 共用页面（能力显隐）。
- **默认启用**：LNS 从 `SourceRegistry.defaultDisabledBuiltins` 移除
  （`source_providers.dart`），新装用户首次播种即为启用态；已装设备保留用户
  自己的开关状态。
- 测试：新增 `test/lns_pages_test.dart`（来源挑选纯函数、远端书架三态与来源
  切换、账号页签到链路、默认启用断言），全套 **252 例全绿**，`flutter analyze`
  零问题。

模拟器真实账号验证（`emulator-5554`，debug 包）：

| 路径 | 结果 |
|---|---|
| 我的 → 站点账号 | 「轻之国度 · 账号与签到 / 消息中心」「轻书架 · 账号与签到」三项 |
| 轻书架账号页 | 真实账号 Miuna5633 / UID 67277 / 轻币 429 / 连续签到 1 天；点「领取今日签到」后轻币 429 → 459（+30），按钮转「今日已签到」 |
| 远端书架 | 来源切换条「轻之国度 / 轻书架」；LK 侧显示站点收藏 2 本 |
| 远端书架（LNS） | 初始为空 → 详情页「加入书架」后出现《年度最垃圾伪圣女》→ 移出后重新加载回到空（读、写两个方向都验证，账号状态已复原） |
| LNS 发现 → 详情 → 正文 | 榜单正常；详情含作者/简介/目录 169 章；正文分页渲染、站点字体生效、9 页可读 |

附注：从详情页返回远端书架时页面不会自动刷新（`_future` 缓存），下拉刷新或
切换来源可重新加载——这是刻意的（避免每次 pop 都打站点），不是缺陷。

### LK 评论配图（commit `32ba17f`）

站点**不接受外链配图**，必须先上传拿引用再发表；契约照 Mixn 的
`LightNovelRepository.uploadCommentImage / publishComment` 移植。

- `LkClient.uploadCommentImage`：手工组 multipart（`security_key` /
  `scene=book_comment` / `file`）POST 到 `api/dynamic/upload-image-v1`，解析
  `url / width / height / res_id`（多候选键）；响应信封拆解抽成 `_unwrapResponse`
  与 `_post` 共用。
- `publishComment(media: …)`：`media_json` 按站点要求是**数组字符串**；
  **只有图片没有文字也是合法评论**（原实现直接报「内容不能为空」）。
- 平台层 `triomi/platform` 新增 `pickImage`（SAF `ACTION_OPEN_DOCUMENT` +
  `image/*`，读字节回 Dart）；用户取消 / 非 Android 都返回 null。
- 评论区 UI：输入框左侧「添加图片」→ 选图后立刻上传（缩略图 + 「上传中 /
  已上传 / 未上传成功」+ 移除）；上传中禁止发表；只有图片时也能发表。
- 夹具：`lk_fixture` 增 `api/dynamic/upload-image-v1` 并把上传记录写进 state；
  发表记录保留 `media_json`；`dev_fixture_server` 读 body 改 `errors='replace'`
  （multipart 含二进制，严格 utf-8 解码会直接把请求打成 500）。
- 测试：新增 `lk_comment_image_test.dart`（multipart 形状、响应解析、未登录、
  空图、`media_json` 序列化、纯图评论）；测试替身 `uploadBytes` 现在把响应交给
  handler（原先固定 201 空体，上传响应解析测不到）。全套 **282 例全绿**。

设备验证（模拟器 + LK 夹具，夹具包）：

| 项 | 结果 |
|---|---|
| 选图上传 | 夹具记录 `{fileName: triomi_comment.png, scene: book_comment}`（multipart 字段正确） |
| 纯图评论 | 点「发表」（不输文字）→ 夹具记录 `content: ""`、`media_json: [{"url":…,"width":640,"height":480,"res_id":"res-1"}]` |
| 真实站点 | **未跑**：公开发言需用户逐条授权（与纯文字评论同一红线） |

### 番剧视频离线下载（规格 4.8 二期，commit `52c7466` / `ae9444a` / `2627ad6`）

代码与夹具设备验证都已完成。边界与「不绕过付费/加密」一致：**只下明文线路**。

- **网络层**：`SourceHttpClient.downloadBytes` 返回 `SourceByteStream`（流式，
  大视频不整块进内存），dio 实现走 `ResponseType.stream`。
- **两条下载路径**（`lib/features/downloads/data/`）：
  - `video_downloader.dart`：渐进式（mp4/mkv…）整文件流式落盘；
    HLS（地址后缀 `.m3u8`）解析后分段边下边写——TS 拼成 `.ts`、
    带 `#EXT-X-MAP` 的 fMP4 拼成 `.mp4`。主列表挑**最高带宽**变体（最多两跳）。
  - `hls_playlist.dart`：m3u8 解析（变体/分段/初始化段/加密识别）。
- **加密流直接拒绝**：`#EXT-X-KEY` 且 METHOD 非 NONE → 报「这条线路是加密流」，
  不下载密文、不做解密。
- **完整性**：响应头给了长度就一字不差校验；任何失败（含半截文件）**删掉重来**，
  不留残缺视频。失败原因显示在下载管理卡片上（此前只有「N 章失败」没法排查）。
- **离线播放**：播放器先查 `downloads` 里本集是否已下载，是则直接播本地文件
  （`file://`），不取站点正文；文件被外部删掉时回退联网播放。
- **夹具**：新增 `/video/sample.m3u8` + 3 个分段；番剧**第 3 话**把 m3u8 放在
  第一条线路（其余话仍是 mp4），两条路径都能在设备上验。
- 测试：`hls_playlist_test.dart` / `video_download_test.dart`（20 例），全套
  **274 例全绿**；analyze 零问题。

模拟器真实验证（`emulator-5554`，夹具番剧源，debug 包）：

| 项 | 结果 |
|---|---|
| 渐进式（第 1/2 话） | `video.mp4` 与源文件**字节一致**（562487 B），任务转「已完成」 |
| HLS（第 3 话） | `video.ts` = 3 段之和 3072 B（顺序拼接正确） |
| 失败表现 | 掐断时任务标记失败、残缺文件被清掉、卡片显示 `HttpException: Connection closed while receiving data`，重试可成功 |
| 离线播放 | **停掉夹具服务**后从下载管理进详情（详情页提示「离线模式…显示本地缓存」）→ 打开第 1 话：播放器时间轴走到 `0:29 / 0:30`（本地文件解码播放；画面仍是模拟器黑帧，见下方真机项） |

环境注意：模拟器（QEMU slirp）+ 本地夹具下，562KB 的**大响应偶发被掐断**
（同一地址重试即成功；宿主侧用生产同款 `downloadBytes` 连拉 3 次字节全对，
HLS 的小分段全对），判定为模拟器网络层而非应用缺陷——应用侧行为是「报错 +
可重试 + 不落残缺文件」。

### 分页正文底部溢出 10px（已修复，commit `059e4ee`）

**现象**：分页模式在「这一页正好填满」时内容比可用高度多 10px——debug 构建显示
`BOTTOM OVERFLOWED BY 10 PIXELS` 黄黑条，release 下最后一行会被裁掉一点。

**根因**（与来源/站点字体无关，LK 同样会中）：渲染走 `Text`，它会**把环境的
`DefaultTextStyle` 合并进来**（Material 的 `bodyMedium` 带 `letterSpacing: 0.3`、
`leadingDistribution: even`），而分页是把裸样式直接交给 `TextPainter` 量高度。
两边字距不同 → 同一个文本片段的换行数不同 → 整页实际高度超过模型；模型里段间距
按 `0.8×字号` 预留、渲染只有 `0.7×字号`，这点余量刚好抵消掉大部分差异，所以只在
内容正好填满时溢出 10px（一个换行约 30.6px 减去余量）。

排查中被否掉的假设：**不是**「站点字体刚注册、首帧分页按回退字体度量」——加了
`await WidgetsBinding.instance.endOfFrame` 再发布内容后实测无效（同一章第二次
打开、字体早已注册，仍然溢出），该改动已回退。

**修法**：新增 `readerTextStyle(base, sourceFont)`（`inherit: false`，来源字体仍
优先），分页测量与分页/滚动两种渲染共用同一份样式——`TextStyle.merge` 对
`inherit: false` 直接返回入参，环境字段不再渗入。

**测试**：`test/reader_pagination_test.dart` 断言「`Text` 的实际渲染高度 == 分页
`TextPainter` 量出的高度」，并额外断言「环境字距确实会改变高度」，避免断言空转。

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
| 收藏同步 | 详情页「加入书架」现在会把本地收藏同步到站点：加《与你飞跃银盘》→ 站点书架 2 → 3 本；移出 → 回到 2 本 |
| 正文 | 章节 8 页完整渲染；`book_id`/`chapter_id` 修复在真实站点生效 |
| 发现页 | LK 榜单（热门/日榜/周榜/新人新作/最近更新）与封面全部正常 |

未做：**发表评论**（真实账号的公开发言）未在自动验证中执行——写入链路
已由夹具端到端覆盖（夹具记录到发表内容），真实站点这一步等用户明确授权
再单独跑。→ **2026-09-28 已补跑**，见下文「LK 真实站点发表评论（含配图）」。

### 收藏同步接线（本次新增）

`setInRemoteShelf` 此前只有 LK / LNS 的来源实现、没有 UI 调用方（详情页的
「加入书架」只写本地库）。现在详情页在本地变更后走
`syncShelfToSource`（`lib/core/source/source_providers.dart`）尽力同步站点：
只对「声明 `capability.remoteShelf` + 已登录 + 实现 `RemoteShelfProvider`」的
来源生效，失败只在提示里说明、不回滚本地。顺带修了 LK 描述符漏声明
`remoteShelf` 能力的问题（来源页能力行现在会显示「远端书架」）。

### 追番页点击链路（模拟器，宿主中继）

本机网络下 `api.bgm.tv` 首个 A 记录黑洞，模拟器直连会一直转圈；本次用
宿主代理起了一个放送表中继（含封面转发）并 `--dart-define=TRIOMI_SCHEDULE_BASE`
指向它，验证：放送表按星期渲染（今日默认选中、条目含评分/首播日/条目号）
→ 点条目 → 详情页带正确标题打开。详情正文要直连 api.bgm.tv，这条网络下
拿不到（已在上面的环境注意里记录），属环境限制而非应用缺陷。

环境注意：`api.bgm.tv` 在本机网络下首个 A 记录
（`98.159.108.71`）不可达，模拟器直连会一直停在加载态（Dart 的
connectTimeout 覆盖不到 DNS 阶段的黑洞地址），「追番」页因此无法在本机
直接做 E2E；需要时用 `--dart-define=TRIOMI_SCHEDULE_BASE` 指到本机中继。

## 模拟器实测补齐（2026-09-28）

用户要求「能自己做的就别留真机」，本轮把原属「真机项 / 需授权项」的几件事
在模拟器上尽量跑掉，并记下仍然只能真机确认的部分。

### LK 真实站点发表评论（含配图）

用已登录的真实账号（Hypex）在真实站点（`www.lightnovel.fun`）发表了一条
带配图的评论：

| 步骤 | 结果 |
|---|---|
| 选作品 | 远端书架 → 《国王的求婚》（book_id 2481） |
| 选图 | SAF 选 `Download/triomi_comment_test.png`（637 B，`adb push` + MEDIA_SCANNER 广播后才在 DocumentsUI 可见）→ 界面提示「图片已上传，发表后一起展示」 |
| 发表 | 评论文本 `Triomi-E2E-test-comment-please-ignore` → 列表顶部出现「Hypex · 2026-09-27 23:29:44」+ 缩略图 |
| 服务端核验 | **脱离 App**，宿主直接 POST `api/new-content-read/get-book-comments`（pageSize 20、newest）拿到 `comment_id=1352023`，`author.uid=1676831`，`imageUrls` 指向 `api.lightnovel.fun/upload-files/images/260927/….png` |

**这条评论是真实的公开发言**（评论 id `1352023`，作品《国王的求婚》），
需要清理的话在站点侧删除即可；应用内没有删除评论的入口。
说明：文本输入只能用 ASCII（`adb shell input text` 不支持中文），
所以测试评论是英文串——这不是应用的限制，是自动化输入的限制。

### WebDAV 双设备同步（两台模拟器 + 夹具 WebDAV）

新建第二台 AVD（`triomi_dev2`，同一 android-35 镜像，`-port 5556`）当第二台设备，
两台都装 debug 包、都指向夹具的 `/dav`：

| 方向 | 结果 |
|---|---|
| A → 云 → B | A 加《夹具番剧 51》→ 上传（远端 1315.8 KB）→ B（全新安装、空库）检测到远端备份 → 拉取合并提示「作品 4、书架 1、历史 7、目录 3」→ **书架当场出现《夹具番剧 51》** |
| B → 云 → A | B 再加《夹具番剧 52》→ 上传 → 宿主校验远端包内 `data.json`：`library=2`、`history=14`（确实是 B 的包）；A 侧下载这一步被下面那条环境问题挡住 |

**顺带修掉一个真实缺陷**（commit `c9f8fa2`）：合并/导入写的是 drift，而书架、
历史是内存里的 AsyncNotifier，原来导入完不会失效这些 provider —— 表现是
「提示合并完成，但书架还是空的，重启才出现」。修复后两台设备都当场刷新。

### 视频画面合成：模拟器上仍然确认不了（试了 4 种配置）

`sample.mp4`（夹具视频）在宿主用 OpenCV 解码确认**不是黑片**（720 帧 /
24fps / 640×360 / 平均亮度 126）。但播放时画面区在模拟器上始终是黑的，
本轮把能试的都试了：

| 配置 | 结果 |
|---|---|
| 默认（AVD `hw.gpu.enabled=no`，软件 GL） | 黑 |
| `hw.gpu.enabled=yes` + `hw.gpu.mode=host`（启用宿主 AMD 780M，模拟器日志 `gles_mode_selected:host`） | 黑，且播放时间轴反而停住不动 |
| 关 Impeller（`am start --ez enable-impeller false`，日志确认已 opt-out） | 黑 |
| 关 media_kit 硬件加速（`enableHardwareAcceleration: false`，临时改+重编验证后已还原） | 黑 |
| 关 `hw.gpu.enabled`（还原回初始配置） | 黑 |

两层证据说明不是「截屏抓不到」：① `dumpsys SurfaceFlinger --list` 里
media_kit 用的是 `SurfaceView` 图层；② **绕过 screencap**，直接在宿主用
GDI 截模拟器窗口，画面区同样是黑的。所以结论保持原样——**画面合成仍需真机**；
`enableHardwareAcceleration: true` 这条既有注释与实际观察不一致，
但真机默认路径没问题（media_kit 是 Kazumi 同款成熟路径），本轮不再改。

### 追踪链路设备验证（夹具，emulator-5556）

第二台模拟器装的是带 `--dart-define=TRIOMI_TRACKING_BASE=http://10.0.2.2:8123/tracking`
的包，夹具在宿主 8123（`tools/tracking_fixture.py`），全程不碰真实站点。

| 步骤 | 结果 |
|---|---|
| 「追踪账号」填 `fixture-token` → 保存并测试连接 | Bangumi 显示「连接正常：**triomi-fixture**」；AniList 同样（夹具只要求 token 非空） |
| 发现 → 本地夹具番剧源 → 《夹具番剧 51》→ 加入书架 → 详情页「追踪」 | 面板自动搜索（夹具返回两条），绑定「夹具番剧 51（中文名）」→ `当前绑定 Bangumi · 51` |
| 面板内切到 AniList 再绑 | 绑定「Fixture Anime 51」→ `当前绑定 AniList · 51`（两条并存） |
| 播第 1 话约 5 秒 | 宿主 `/tracking/state` 出现 `watchedEpisodes['51'] = [101]`（逐集收藏 PATCH）与 `anilist['51'].progress = 1` |

宿主侧断言（夹具内存态，`GET /tracking/state`）：

| 时点 | collections | watchedEpisodes | anilist |
|---|---|---|---|
| 绑定 Bangumi 后 | `{51: {type: 3}}` | `{}` | `{}` |
| 再绑 AniList 后 | 同上 | `{}` | `{51: {status: CURRENT, progress: 0}}` |
| 播放 10 秒后 | 同上 | `{51: [101]}` | `{51: {status: CURRENT, progress: 1}}` |

结论：**「绑定 → 状态上报 → 逐集进度上报」整条写链路在设备上是通的**；
剩下的只有真实站点的 token 联调（等用户提供）。

**顺带把弹幕链路也验了**：夹具番剧源的规则里写了
`content.danmaku = /danmaku/{id}.json`，夹具返回 40 条滚动 + 1 条顶部 + 1 条底部；
播放器自绘弹幕层在设备上正常滚动（截图可见白/橙/绿三色弹幕），时间轴走到 `0:29 / 0:30`。
也就是说**规则自带弹幕源时不需要任何凭据**，这条链路是通的——之前只差「弹弹play 凭据」
那一半（用于按条目匹配弹幕）。

同一张播放截图再次确认：视频**画面区仍是黑的**（上面那 4 组渲染配置的老结论，
仍需真机），但时间轴推进、弹幕层、线路/剧集/倍速/全屏这些控制都正常。

### 弹幕发送链路设备验证（夹具，emulator-5556）

T3 当初只做了单测 + 夹具端点，**从没在设备上跑过完整发送链路**。本轮补齐
（夹具先补了 `GET /api/v2/search/episodes` 与 `GET /api/v2/comment/{id}`，
原来只有 login 与 POST comment 两个端点）：

| 步骤 | 结果 |
|---|---|
| 「我的 → 弹幕设置」填 AppId / AppSecret + 账号 / 密码 → 点「登录获取 token」 | 夹具 `/api/v2/login` 返回 `fixture-dandanplay-token`，token 自动写进输入框；状态从「未配置」变成**「可拉取、可发送」**（密码只在请求里用一次，不落盘） |
| 播放器 → 「搜索弹幕」→ 搜索 | 夹具 `/api/v2/search/episodes?anime=…` 返回一部剧两集，底部面板列出「夹具番剧（夹具番剧 51） · 第 1 话 / 第 2 话」 |
| 选第 1 话 | `GET /api/v2/comment/9001` 载入弹幕，`_danmakuEpisodeId = 9001` |
| 「发送弹幕」→ 输入 → 发送 | 夹具进程日志出现 `[dandanplay] comment sent to episode 9001: 'triomi-e2e-danmaku' @ 29.75s` |

也就是说 **AppId/AppSecret + 账号密码 → token → 手动匹配 → 发送** 整条链路在设备上
是通的（签名头 X-AppId / X-Timestamp / X-Signature 与 Bearer token 都按预期带上）。
剩下的只有真实弹弹play 凭据（等用户注册应用）。

### 性能数字（模拟器 / debug 包，仅作量级参考）

| 指标 | 数值 | 采集方式 |
|---|---|---|
| 冷启动 TotalTime | 3376 ms（WaitTime 3380 ms） | `am start -W` |
| 常驻内存 PSS | 391 MB（RSS 488 MB；Java heap 12.4 MB / native heap 41.5 MB） | `dumpsys meminfo` |
| 帧间隔 | 播放器页稳定 avg ≈16.6 ms（60 FPS）；滚动时 avg ≈23 ms、偶发 ~300 ms 尖峰 | logcat `EGL_emulation: app_time_stats` |

注意：debug 包 + 软件渲染，数字只代表「模拟器上能跑」；`dumpsys gfxinfo`
对 Flutter 无效（帧由引擎自绘，gfxinfo 统计的 HWUI 帧数是 0）。

### 环境注意：夹具 WebDAV 的大包传输

夹具 `/dav` 的 GET 单次写 1.35 MB，在**模拟器 slirp** 下偶发被掐断：
客户端报 `HttpException: Connection closed while receiving data`，重试有时
变成 `Bad state: Too many elements`（同一对比：同样大小的包在刚装好的
第二台模拟器上可以正常下载；宿主侧 GET 的字节与磁盘文件 MD5 完全一致，
`PROPFIND`/`GET` 在夹具日志里全是 200）。这与番剧下载那节记的
「562 KB 大响应偶发被掐断」是同一个模拟器网络层问题，不是应用缺陷——
应用侧表现是明确报错、可重试、且不会破坏本机数据（书架内容保持完好）。
反过来，真实站点的大文件（18.4 MB 字体）在同一台模拟器上是可以正常下载的。

### Bangumi 不可达 → 镜像回退（commit `1ad83dd`）

`api.bgm.tv` 在本机网络下是 DNS 污染 + IP 黑洞：实测 `api.bgm.tv` /
`bgm.tv` / `www.bgm.tv` / `next.bgm.tv` 四个域名全部解析到不可达地址，
「追番」页会一直转圈且不给任何提示。

**Kazumi 为什么能用**（读它的 `lib/request/config/api_endpoints.dart`）：
它走镜像——`bangumiMirrorDomain = https://api.kazumi.fyi`（榜单/放送表缓存）、
`bangumiAuthAPIMirrorDomain = https://api.bgmapi.com`（鉴权）、
`bangumiAPINextDomain = https://next.bgm.tv`。

**Kazumi 的那对镜像凭据在仓库里也是空的**（2026-09-29 核实）——
`lib/utils/bangumi_mirror_credentials.dart` 只是
`String.fromEnvironment('KAZUMI_APPID')` / `('KAZUMI_KEY')`，
值由它自己的 CI 用 `--dart-define` 注入（与我们的
`TRIOMI_DANDANPLAY_APP_ID/SECRET` 做法完全一样）。
它给这个签名加在**镜像的受保护端点**上：`POST /v0/search/subjects` 与
`/p1/{subjects,episodes,characters}/{id}/comments`（其 `bangumi_client.dart`
的 `_shouldSignProtectedMirrorRequest`）。**本项目用不到这对值**：实测
`api.bgmapi.com` 的 `/v0/subjects/{id}`、`/v0/episodes`、`POST /v0/search/subjects`
**匿名就能 200**，`/v0/me` 无 token 401、伪造 token 也 401（就是把 Authorization
透传给上游后的判定），所以带用户 token 的回退是有效的。

本项目的处理（只覆盖**公开数据**）：

| 接口 | 处理 |
|---|---|
| `/calendar`（追番页放送表） | 默认官方；失败回退 `api.bgmapi.com/calendar`（同格式，实测 200/88 KB，且 v0 详情/剧集/搜索也一并代理） |
| 加载中 | 有备用地址时提示「正在连接官方接口；不通会自动改用镜像」 |
| 回退后 | 页面顶部注明「官方接口不可达，本次放送表来自镜像 api.bgmapi.com」，不偷偷换源 |
| 夹具模式（`--dart-define=TRIOMI_SCHEDULE_BASE`） | **不回退**，夹具是权威来源 |

设备验证：模拟器上打开「追番」→ 先出连接提示 → 约 20 秒（官方 connect
timeout）→ 自动切镜像并渲染出真实放送表（今日条目：评分 / 首播日 / 条目号）。

**追踪的 token 请求：2026-09-28 起也回退，但换源可见**（用户明确同意，commit `8a738c3`）。

原先是「刻意没做」（带 access token 的请求把 token 发给第三方镜像要用户同意）。
先核实了镜像能否承担这件事：带**伪造** Bearer token 请求
`/v0/me`、`/v0/users/-/collections/{id}`、
`/v0/users/-/collections/{id}/episodes`、`/v0/search/subjects`
全部返回 **401 而不是 404**——说明 `api.bgmapi.com` 把 v0 的鉴权端点也一并代理了，
带 token 的请求能走。代价是**用户的 token 会发给第三方镜像**，所以做了三件事：

| 约束 | 实现 |
|---|---|
| 只在官方不可达时被动触发 | `BangumiClient.fallbackBaseUrl`：官方连不上（含超时）或 5xx 才回退；**401/403 不回退**——换地址也一样，没必要为此把 token 转手给第三方 |
| 不能偷偷换源 | 「追踪账号」页配置说明里写明会走镜像、token 会发给它；「测试连接」结果后追加「（官方 api.bgm.tv 不可达，本次请求走了镜像 api.bgmapi.com）」 |
| 夹具模式仍是权威 | dart-define 指到夹具时不回退（与放送表同一条规矩） |

一个容易踩的实现细节：网络层对**非 2xx 是抛异常**而不是返回响应（`DioSourceHttpClient.send`），
所以「实际发往哪个地址」必须在**请求前**记录，等拿到响应再记就记不上——镜像回 401 时正好
是这种情况，而那正是最需要提示「token 发出去了」的场景（已补测试盯住）。

设备验证（emulator-5554，**不带 dart-define 的真实站点包**）：`api.bgm.tv` 在模拟器里
解析到污染地址 `168.143.171.189`（ping 100% 丢包）→ 「追踪账号」贴一个假 token →
点「保存并测试连接」→ 约 30 秒后显示
「连接失败：SourceException(bangumi, auth): HTTP 401（官方 api.bgm.tv 不可达，
本次请求走了镜像 api.bgmapi.com）」——401 来自镜像，回退链路真实跑通。
AniList（`graphql.anilist.co`）本机可直连（伪造 token 返回 401），**不需要镜像**。

### 弹幕：Kazumi 为什么「不用登录」

弹弹play 的开放接口**无凭据直接 403**（实测：不带 `X-AppId` 403，伪造 appId
也 403），所以「不登录就能拿弹幕」不是接口开放，而是**客户端内置了自己注册的
AppId/AppSecret**——Kazumi 的 `lib/utils/dandan_credentials.dart` 就是干这个的。
但注意（2026-09-29 核实）：**那个文件里只有
`String.fromEnvironment('DANDANAPI_APPID' / 'DANDANAPI_KEY')` 占位**，
真值在它自己的发布/CI 构建里用 `--dart-define` 注入，**仓库里拿不到**；
就算去扒它的 APK 也是别人的生产凭据（会随时被停用，也不该搬）。
本项目原先刻意不内置他人凭据（见 `dandanplay_client.dart` 的注释），所以要求
用户自己填。

现在改成一个**槽位**（commit `1ad83dd`）：`DandanplayCredentials.builtInAppId /
builtInAppSecret`——用户没填时用应用自己注册的那对，「拿弹幕」开箱可用；
**发弹幕仍然需要用户自己的账号 token**。值可以从构建时注入：

```
flutter build apk --dart-define=TRIOMI_DANDANPLAY_APP_ID=xxx \
                  --dart-define=TRIOMI_DANDANPLAY_APP_SECRET=yyy
```

未注入时行为与之前完全一致（要求用户自填）。用户已答应去
<https://dev.dandanplay.com> 注册应用并提供这对凭据，拿到后即可内置/联调。

（另注：规则自带弹幕源时**本来就不需要任何凭据**——播放器直接 GET 规则里
声明的 `danmaku` 地址，见 `player_page.dart` 的 `_loadDanmaku`。）

### 凭据怎么拿（三条线，2026-09-29 核实）

| 用途 | 需要什么 | 获取方式 | 审核 |
|---|---|---|---|
| Bangumi 追踪 | 个人 access token | <https://next.bgm.tv/demo/access-token> 登录 → 「创建个人令牌」→ 填名称与有效期 → 复制 | **不需要**（不用建应用） |
| AniList 追踪 | 个人 access token | anilist.co → Settings → Developer → Create New Token | **不需要**（不用建应用） |
| 弹弹play 弹幕匹配 / 发送 | AppId + AppSecret（**应用级**） | dev.dandanplay.com 注册开发者账号 → 完善资料 + 邮件验证 → 创建应用 → **提交审核** | **要审核**（官方流程；公开/私有项目都可申请） |

- **追踪 token 是账号级授权**（以你的身份写收藏），任何第三方 App 都不可能内置别人的，
  只能用户自己生成——所以「从 Kazumi 抄一份」不存在（它的凭据文件也是
  `String.fromEnvironment` 占位，见上一节）。
- 弹弹play 是**应用级**凭据，可以内置（Kazumi 就是这么做的），但要自己注册 + 过审。
  **过审前的退路**：规则自带弹幕源（`content.danmaku`）**不需要任何凭据**，弹幕照常渲染
  （已设备验证）；受影响的只有「按番剧名去弹弹play 匹配弹幕」和「发弹幕到弹弹play」。
- 弹弹play 开发者协议要求展示其数据时**标注完整来源**（「弹弹play」/「弹弹play开放弹幕网络」，
  不得只写「弹弹」或「dandan」），未书面授权不得商用。设置页文案写的是「弹弹play」，
  符合标注要求；将来在播放器里显示弹幕来源时也要带上。
- `bgm.tv` / `next.bgm.tv` / `api.bgm.tv` 在本机网络下都被 DNS 污染，**生成 Bangumi 令牌
  要用手机或代理**；生成后 App 侧有镜像回退，同一台机器上也能同步。

### 收尾：把实测结论写回注释与文案（commit `da12277`）

三处**只动注释/文案，不动行为**：

| 位置 | 改动 |
|---|---|
| `danmaku_settings_page.dart` | 说清 AppId/AppSecret 只管**拉取**弹幕，发弹幕另需账号 token；**规则自带弹幕源时无需任何凭据**；已内置凭据时提示「可被自己的值覆盖」。状态文案由「已配置（仅可拉取）」改为「仅可拉取（未配置账号 token）」，可发送时写「可拉取、可发送」——`isConfigured` 在注入内置值后本就可能为真，旧文案会让人误以为是自己填的 |
| `player_page.dart` | 原注释声称「显式开硬件加速以保证模拟器调试时画面可见」，与上面那 4 组实测不符；改为「真机默认路径可用，模拟器黑屏已排除截屏因素，判定为模拟器外部纹理合成问题，与本开关无关」，`enableHardwareAcceleration: true` 保持不变 |
| `schedule_providers.dart` | `resolveScheduleCover` 的注释点明官方与镜像**都**返回绝对地址，相对地址补全只对夹具生效，避免后人以为镜像也走这条逻辑 |

自查：`dart format`（无改动）+ `flutter analyze`（零问题）+ `flutter test`（291 例全绿）。
另 grep 了 `TODO|FIXME|后续版本|暂不`，剩下的两处（`detail_page.dart` 的章节入口说明、
`lk_dm_page.dart` 的「本轮为只读：暂不支持发送私信」）都是**准确**的现状描述，不改。
