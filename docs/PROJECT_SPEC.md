# 三位一体动漫聚合软件 — 项目规格与交接文档

> **文档用途**：本文件是完整的需求 + 调研 + 方案 + 任务拆解，交给下一个 AI 模型（或人类开发者）直接动工。读完后应能不依赖任何外部上下文开始写代码。
>
> **文档版本**：v1.5（2026-10-01，Android 播放画面合成修复并完成模拟器像素验收）
>
> **实施进度**：M0（脚手架）✅ ｜ M1（规则引擎，声明式部分）✅ ｜ M2（漫画闭环）✅ ｜ M3（追番闭环）✅ ｜ M4（小说闭环）✅ ｜ M5（增强）✅ ｜ 项目位于 `D:\noval_and_manga\triomi`
> 复查记录见 `triomi/docs/M0_REVIEW.md`、`M1_REVIEW.md`、`M2_REVIEW.md`；规则写法见 `triomi/docs/RULE_FORMAT.md`
> **项目代号**（暂定，可改）：**Triomi**（Triple + Anime/Manga/Novel 的组合，亦可沿用用户自有项目 mixn 的名字）

---

## 1. 需求概述

做一个**追番 + 漫画 + 小说 三位一体**的集成聚合软件：

- **追番（看动画）**：功能对齐 **Kazumi** —— 自定义规则采集番剧、在线播放、弹幕、追番列表、时间表。
- **看漫画**：功能对齐 **Komikku** —— 多源漫画阅读、书库管理、多种阅读模式、离线下载、追踪服务。
- **看小说**：**完整移植**用户自有项目 **Mixn** 的全部功能（不是 subset）——LK/LNS 双源聚合、阅读器、账号体系、站点功能、下载导出、字体外观，见 2.4 全量功能清单。

**开发方式声明**：本项目是**全新独立开发的 App**（Flutter），不是在 Mixn 仓库上叠加开发。Mixn 的角色是「设计蓝本 + 功能验收基准」——其架构思想被吸收、Kotlin 代码作为移植参照（MIT，用户自有），但新 App 的代码从零写。小说模块的完成定义 = **Mixn v1.17.0 功能全量对齐**（下含清单逐项打勾）。
- **UI 一定要好看**：以 **Komikku 的 GNOME/libadwaita 风格**为视觉基准（简洁、卡片化、自适应、圆角、留白充足），在跨端框架中复刻其设计语言。

**核心原则**：软件本身**不存储任何内容**，一切内容来自用户导入的「规则/源」，软件只做聚合、解析、呈现与管理。这是 Komikku / Kazumi / Miru / Mihon 共同的生存模式，也是法律风险的隔离带。

---

## 2. 调研结论

### 2.1 参照项目一览

| 项目 | 技术栈 | 平台 | 规则/源机制 | 核心亮点 | 许可证 |
|---|---|---|---|---|---|
| **Komikku** | Python + GTK4 + libadwaita + WebKitGTK | Linux (GNOME) | 内置 Python 解析器（数十个 server 模块） | 书库分类、RTL/LTR/Vertical/Webtoon 四种阅读模式、自动更新/自动下载新章节、阅读历史、AniList/MAL/MangaUpdates 追踪、OCR 翻译、本地 CBZ/CBR/EPUB/PDF | GPL-3.0+ |
| **Kazumi** | Flutter + Dart（media_kit/libmpv、Hive、MobX、flutter_modular、canvas_danmaku） | Android/Win/macOS/Linux/iOS/HarmonyOS | **最多五行 XPath 选择器**自定义规则，规则仓库导入/分享 | 番剧目录/搜索/时间表、弹幕（弹弹play API）、追番收藏、历史、倍速、硬解、Anime4K 超分、WebDAV 跨设备同步、DLNA、一起看(SyncPlay)、Material You 动态配色 | GPL-3.0 |
| **Miru** | Flutter + Dart（quickjs 运行 JS 扩展） | Android/Windows/Web | **JavaScript 扩展**（最快上手、生态活跃），支持自定义扩展仓库 | **视频+漫画+小说三合一**（与本项目定位完全一致）、TMDB 元数据、AniList 追踪、代理支持、统一 UI | AGPL-3.0 |
| **Mihon**（Tachiyomi 继任者） | Kotlin + Jetpack Compose | Android | 独立 APK 扩展（source-api 接口） | 数百源生态、离线缓存、追踪服务全家桶、Material You、源迁移工具 | Apache-2.0 |
| **Mixn**（用户自有） | Kotlin + Jetpack Compose (Material 3) Android；Kotlin/JVM + Swing 桌面预览版 | Android 8+ / Windows | **内置来源适配器**（轻之国度 LK + 轻书架 LNS），能力接口式契约 | 双源聚合搜索、统一书架（`sourceId+remoteId` 复合键）、独立登录态、付费章节解锁、评论/签到等站点功能、EPUB 3/TXT 导出、SignalR 协议适配 | **MIT** |

### 2.2 关键结论

1. **三合一已有成功先例**：Miru 证明了「Flutter + JS 扩展」做视频/漫画/小说三合一完全可行，架构可直接对标。
2. **规则引擎选 JS 不选纯 XPath**：Kazumi 的 XPath 规则简单但表达力弱（遇到 JS 渲染、加密、复杂翻页就抓瞎）；Miru 的 JS 扩展表达力强且社区生态好。**最佳方案：JS 为主，内置 XPath 兼容层作为简式写法**（简单站点 5 行选择器搞定，复杂站点写完整 JS）。
3. **Flutter 是唯一合理选择**：单代码库覆盖 Android/Windows/iOS/macOS/Linux；Kazumi 和 Miru 两个最重要的参照都是 Flutter，播放器（media_kit）、弹幕、解析等轮子全部现成可参考。
4. **许可证红线**：Komikku(GPL3)/Kazumi(GPL3)/Miru(AGPL3) 的代码**不能直接复制**，否则本项目必须同许可证开源。正确姿势：**参考架构思想，自己实现**；若要直接复用代码，本项目须采用 GPL-3.0 并在 README 声明。**本项目建议直接采用 GPL-3.0 开源**，与生态保持一致，省去所有纠结。
5. **UI 复刻路径**：Komikku 是 libadwaita 风格（Adw 大圆角卡片、Sidebar + Content 布局、自适应断点、柔和阴影）。Flutter 用 Material 3 + 自定义 Design Token 可以高度还原（见第 6 章）。

### 2.3 Mixn 深入解析（已读源码，2026-09-22）

仓库：`HyperionHXH/lightnovel-android-aggregator`，分支 `feature/multi-source-foundation`（v1.17.0）。

**工程结构**：
```
app/src/main/java/io/github/jiangyuyi/lightnovel/
├─ core/       统一模型、来源契约、网络、缓存、会话、离线、阅读设置
│  ├─ source/  SourceContracts.kt（能力接口）、SourceModels.kt、SourceRegistry.kt
│  ├─ epub/ txt/   EPUB 3 / TXT 导出
│  └─ session/ offline/ cache/ reader/ updates/
├─ feature/    发现、搜索、书架、详情、阅读、账号、消息、字体、设置页面
└─ source/     lightnovelkingdom（LK）、lightnovelshelf（LNS）两个内置适配器
desktopApp/    Kotlin/JVM + Swing 桌面预览版
```

**最值得继承的设计 —— 能力接口式来源契约**（`SourceContracts.kt`）：不按站点写死功能，而是把来源能力拆成一组可组合接口，源按需实现、UI 按能力显隐：

| 能力接口 | 职责 |
|---|---|
| `DiscoverProvider` | 分站榜单/频道（不把多站混成一个榜） |
| `SearchProvider` | 分页搜索；聚合搜索并行查询、逐源返回成败 |
| `DetailProvider` / `ReaderProvider` | 详情、分卷、章节目录、章节正文（**卷→章两级结构**，小说特有） |
| `AccountProvider` / `SourceProfileProvider` | 登录/会话恢复/资料，**登录态按源隔离** |
| `ShelfProvider` / `HistoryProvider` / `ReadingProgressSyncProvider` | 远端书架、远端历史、进度云同步 |
| `ChapterUnlockProvider` | **付费章节解锁**（不绕过、不伪造） |
| `RewardProvider` / `CommentProvider` | 签到、评论（含富评论、点赞、评分） |

**核心不变量（新项目必须沿用）**：
- 一切业务键 = `(sourceId, remoteId)` 复合键（`SourceResourceId`），禁止只用 remoteId。
- 各源登录态/凭据严格隔离，不跨源共享。
- 聚合操作允许部分成功，错误必须标注具体来源与类型（认证/限流/超时/解析/权限/不存在）。
- 站点兼容逻辑（防盗链、协议、专用字体）留在源适配层，不进通用 UI。

**两个小说源的技术要点（移植时必须处理）**：
- **LK（轻之国度）**：网页接口 + 账号体系（轻币、签到、评论），付费章节走账号权限。
- **LNS（轻书架）**：**SignalR 实时协议**获取章节内容；**正文依赖服务端下发的专用字体**（不加载则乱码）——阅读器和下载器都必须先持久缓存字体再渲染。Dart 侧可用 `signalr_netcore` 包对接。
- 两个源都是**登录态 + 付费内容**站点：规则引擎因此必须支持「需要登录的源」（见 4.3 修订）。
- Mixn 是 MIT 且为用户自有项目：**Kotlin 适配器代码可以直接移植/改写**，无许可证障碍。

### 2.4 Mixn 功能全量清单（小说模块验收基准，逐项不可缺）

> 来源：Mixn v1.17.0 README + CONTEXT.md。新 App 小说模块以下列每一项为验收标准。

**A. 发现与搜索**
- [x] A1 双源独立发现：LK/LNS 各自的热门、排行、新书、更新频道，**不混榜**
- [x] A2 聚合搜索：并行查询两源，逐来源显示结果或错误；搜索不要求登录
- [x] A3 发现/搜索触底分页；固定榜单到底时明确提示，不重复追加

**B. 书籍与阅读**
- [x] B1 详情页：简介、标签、同书版本、分卷、章节目录（卷→章两级）
- [x] B2 统一书架：`(sourceId, remoteId)` 复合键，全部书籍/已下载/阅读历史视图
- [x] B3 阅读器双模式：分页 + 上下滚动
- [x] B4 排版调节：字体、字号、行距、边距、背景（护眼色）、点击区域、图片缩放、屏幕方向、音量键翻页、屏幕常亮、进度条
- [x] B5 正文插图：懒加载、协议相对地址与 CDN 兼容、放大查看、长按保存相册、右上角关闭/系统返回退出
- [x] B6 付费章节：按源接口与账号权限处理；**不绕过锁定、不伪造余额/阅读记录**
- [x] B7 服务端专用字体（LNS）：在线与离线均先持久缓存字体再渲染；失败显示来源错误，**不显示混淆正文**

**C. 账号与站点功能**
- [x] C1 双源独立登录/退出/会话恢复，凭据不跨站共享，凭据用安全存储（Android Keystore 等价物，Flutter 用 `flutter_secure_storage`）
- [ ] C2 LK：个人资料、轻币余额、七日签到、关注/粉丝、发布管理、消息中心、作品评论（最热/最新排序、分页、星级、发表评论）（缺口：发布管理页未实现，见 docs/ACCEPTANCE_MATRIX.md）
- [x] C3 LNS：个人资料、收藏同步、官方签到（LNS 无评论接口则不显示入口——能力显隐原则）
- [x] C4 站点接口/权限不可用时保留具体错误（来源/认证/超时/权限/不存在）

**D. 下载与导出**
- [x] D1 整本或指定分卷下载；锁定章节不计入已下载
- [x] D2 下载页：已完成卷/章数、失败重试、删除记录
- [x] D3 导出 UTF-8 TXT / EPUB 3（EPUB 含封面与正文插图，TXT 用 `[插图]` 占位）
- [x] D4 导出目录：优先用户授权目录，否则应用专用目录 `offline_library/exports`；**不扫描/导入本地 EPUB，不删除用户原始文件**
- [x] D5 仅 WiFi 下载开关；后台更新提醒（默认关闭，Android WorkManager 等价物，需通知权限）

勾选依据与逐项证据见 [`docs/ACCEPTANCE_MATRIX.md`](ACCEPTANCE_MATRIX.md)（D17 建立：
实现层 = 代码 + 单测；设备/账号层 = 模拟器或真实站点记录）。未勾选项（C2、G1）
在矩阵中写明具体缺口，交 Codex 决定修复或裁剪。

**E. 字体与外观**
- [x] E1 系统字体 + 可下载字体，独立预览页（中文/标点/英文示例，下载前后可对比）
- [x] E2 阅读设置与界面外观设置**分开保存**，各分组可单独恢复默认值
- [x] E3 主题、界面字号、图标大小可调

**F. 隐私与安全红线（继承 Mixn）**
- [x] F1 密码/验证码/security_key 不写入缓存、日志、崩溃报告；退出登录清理该账号私有缓存
- [x] F2 只申请必需权限（网络/通知/相册写入），不申请全盘存储
- [x] F3 不伪造阅读时长、不接"浏览赚币"类灰色接口（Mixn 明确拒绝的边界，继续拒绝）

**G. 书架更新提示**
- [ ] G1 LK 用来源提供的未读章数；其他源仅在有基线且章节数跨刷新增加时标更新（缺口：unread_count 无写入方，见 docs/ACCEPTANCE_MATRIX.md）
- [x] G2 更新以复合键为准、书架按来源汇总更新数；"全部标为已读"只确认本地提示，不改远端历史

---

## 3. 技术选型

### 3.1 方案对比

| 方案 | 优点 | 缺点 | 结论 |
|---|---|---|---|
| **Flutter（推荐）** | 单代码库全平台；参照项目同源；media_kit 播放器成熟；性能好 | 桌面端插件生态略弱于 Electron；Mixn 的 Kotlin 代码无法直接跑，需移植 | ✅ **选定** |
| Kotlin Multiplatform Compose（Path B） | **可直接复用 Mixn 的 core/source 适配器**；Compose 与 Mixn UI 同源 | 视频播放/弹幕生态远弱于 Flutter（无 media_kit 级别轮子）；iOS 不成熟；桌面端 Mixn 自己也只有 Swing 预览版 | ❌ 追番是本项目的硬需求，播放生态是决定性的 |
| Electron/Tauri + Web | Web 生态强、UI 自由度高 | 移动端基本没戏；播放器/弹幕要另找轮子 | ❌ |
| 原生多端 | 体验最好 | 三端三套代码，单人/小团队不可行 | ❌ |

> **结论说明**：选 Flutter 不选 KMP 的决定性原因是追番播放器与弹幕生态。Mixn 侧的损失可控——它只有两个内置源，把 LK/LNS 适配器用 Dart 重写（含 SignalR 用 `signalr_netcore`）工作量有限；而 Mixn 的**架构设计（能力接口契约、复合键、错误分类）全部吸收进本项目**，见 4.2/4.3。

### 3.2 依赖清单（pubspec 核心依赖）

| 领域 | 包 | 说明 |
|---|---|---|
| 框架/路由/DI | `flutter_modular` 或 `go_router` + `get_it` | 二选一，新写建议 go_router |
| 状态管理 | `flutter_riverpod` | Kazumi 用 MobX，新项目推荐 Riverpod（编译期安全、社区主流） |
| 本地数据库 | `isar` 或 `drift`(SQLite) | 书库/历史/收藏/下载记录；Isar 更快，drift SQL 表达力强。建议 **drift**（复杂查询多） |
| KV 存储 | `hive_ce` | 设置项 |
| 网络 | `dio` + `cookie_manager` | 请求源站，处理反爬 cookie |
| HTML 解析 | `xpath_selector` + `html` | XPath 简式规则 |
| JS 引擎 | `flutter_js`（quickjs 绑定） | 运行 JS 扩展规则（Miru 同款思路） |
| WebView 兜底 | `flutter_inappwebview` | 过 Cloudflare / JS 渲染页面 |
| 视频播放 | `media_kit` + `media_kit_video` | libmpv 内核，硬解，Kazumi 同款 |
| 弹幕 | `canvas_danmaku` | 弹弹play API 匹配弹幕 |
| 漫画阅读 | 自绘 `InteractiveViewer` / `photo_view` 网格 | 四种阅读模式（见 4.4） |
| 小说阅读 | 自绘分页引擎（TextPainter 排版） | 见 4.5 |
| 图片加载 | `cached_network_image` | 封面/漫画页缓存 |
| 云同步 | `webdav_client` | WebDAV 同步书库/进度 |
| 桌面窗口 | `window_manager` | Windows/macOS/Linux 窗口控制 |
| 主题 | `dynamic_color` | Material You 取色（Android 12+） |
| 元数据/追踪 | 自写 HTTP 客户端 | Bangumi.tv API、AniList GraphQL、TMDB API |

**最低目标**：Flutter 3.2x+ / Dart 3.5+；Android 10+、Windows 10+ 为一期平台，iOS/macOS/Linux 二期。

---

## 4. 架构设计

### 4.1 分层架构

```
┌─────────────────────────────────────────────────────┐
│ UI 层（页面/组件，Riverpod 消费状态）                  │
│  书架库 │ 发现/搜索 │ 详情 │ 追番时间表 │ 设置 │ 阅读器×3 │
├─────────────────────────────────────────────────────┤
│ 应用服务层（Controllers / Providers）                 │
│  LibraryService  HistoryService  TrackService        │
│  DownloadManager UpdateChecker  SyncService(WebDAV)  │
├─────────────────────────────────────────────────────┤
│ 领域层（统一内容模型 + 仓储接口）                       │
│  MediaItem / Chapter / Episode / Source 接口          │
├─────────────────────────────────────────────────────┤
│ 规则引擎层（本项目核心壁垒）                            │
│  JS Runtime (flutter_js)  │ XPath 简式解析器           │
│  规则加载/校验/沙箱/仓库导入/更新                        │
├─────────────────────────────────────────────────────┤
│ 基础设施层                                             │
│  dio 网络 │ drift DB │ hive KV │ 缓存 │ WebView 兜底    │
└─────────────────────────────────────────────────────┘
```

### 4.2 统一内容模型（三合一的关键抽象）

三种内容形态统一为一套模型，UI 和书库逻辑只写一遍：

```dart
enum MediaType { anime, manga, novel }

/// 沿用 Mixn 的 SourceResourceId 不变量：一切业务键 = (sourceId, remoteId) 复合键，
/// 禁止只用 remoteId（缓存、导航、书库、进度、下载全部如此）。
typedef SourceResourceId = ({String sourceId, String remoteId});

class MediaItem {          // 一部作品（番/漫/小说统一）
  SourceResourceId key;    // 复合主键
  MediaType type;
  String title, coverUrl, author, description;
  List<String> tags;
  double? rating;
  String status;           // 连载中/已完结
}

class Chapter {            // 章节/剧集统一
  SourceResourceId key;
  String title;
  double number;           // 支持 4.5 / 4.a 这类章节号（参考 Mihon ChapterRecognition）
  String? volumeTitle;     // 小说的「卷」层级（沿用 Mixn 卷→章两级结构）；番/漫为 null
  DateTime? releaseDate;
  bool locked;             // 付费/锁定章节（Mixn 设计：不解锁、不伪造，仅标注）
  // anime → 播放地址列表（多线路）；manga → 图片 URL 列表；novel → 正文文本（含插图标签）
}

/// 来源错误分类（沿用 Mixn）：聚合操作允许部分成功，错误必须带来源与类型。
enum SourceErrorType { auth, rateLimited, timeout, parse, permission, notFound, network }

class TrackEntry {         // 书库条目（用户收藏 + 进度）
  SourceResourceId key;
  MediaType type;
  double progress;         // 看到的章节号
  int? score;              // 用户评分
  String watchStatus;      // 在看/想看/看过/搁置/抛弃（对齐 Bangumi 五态）
  List<String> categoryIds;
}
```

### 4.3 规则引擎（Source API）

**双轨来源体系**（吸收 Mixn 设计后的修订）：

> **实施结论（M1 已落地）**：规则层最终实现为**两种格式**——① 声明式 JSON 规则
> （`response: html | json`，选择器支持 CSS 与 XPath，覆盖绝大多数站点与开放接口，**跨平台含 Web 可用**）；
> ② JS 扩展源（表达力更强，但需要原生引擎，因当时无可用设备验证而延后为独立任务 T2b）。
> 声明式部分不需要 JS 引擎即可运行，因此优先落地；JS 沙箱接在同一个能力接口之下，
> 后续增加不会影响已上线的规则。规则格式详见 `triomi/docs/RULE_FORMAT.md`。

- **内置适配器（built-in）**：需要登录态/付费/特殊协议的源，用 Dart 直接实现能力接口，随 App 编译——LK、LNS 两个小说源走这条路（SignalR、专用字体、付费解锁不适合塞进 JS 沙箱）。
- **JS 扩展源（plugin）**：普通公开站点，JS 文件动态加载，走沙箱。

两轨实现同一套**能力接口**（Dart abstract class，移植自 Mixn `SourceContracts.kt`），UI 按源声明的能力显隐功能：

```dart
abstract class SourceProvider { SourceDescriptor get descriptor; }
abstract class DiscoverProvider implements SourceProvider { /* 分站榜单，不混榜 */ }
abstract class SearchProvider  implements SourceProvider { /* 分页搜索 */ }
abstract class DetailProvider  implements SourceProvider { /* 详情 + 卷/章节目录 */ }
abstract class ContentProvider implements SourceProvider { /* 章节正文/图片/播放地址 */ }
abstract class AccountProvider implements SourceProvider { /* 登录/会话恢复/退出，按源隔离 */ }
abstract class RemoteShelfProvider  implements SourceProvider { /* 远端书架（可选能力） */ }
abstract class ProgressSyncProvider implements SourceProvider { /* 进度云同步（可选能力） */ }
abstract class UnlockProvider  implements SourceProvider { /* 付费章节解锁（可选能力） */ }
abstract class CommentProvider implements SourceProvider { /* 评论（可选能力） */ }
// 聚合搜索：并行查询全部 SearchProvider，逐源返回成功或 SourceError，单源故障不阻断。
```

JS 扩展源文件约定：

```js
// ---- 规则文件示例骨架（交给实现者完善） ----
const source = {
  id: "example-manga",
  name: "示例漫画源",
  type: "manga",            // anime | manga | novel
  lang: "zh",
  baseUrl: "https://example.com",
  capabilities: ["search", "discover", "detail", "content"],  // 声明能力，与内置适配器对齐
  requireLogin: false,     // 需要登录的源置 true（引擎提供按源隔离的 cookie/凭据存储）
  // XPath 简式模式：提供选择器即可，引擎自动生成实现
  selectors: {
    search: { list: "//div[@class='item']", title: ".//a/@title", url: ".//a/@href", cover: ".//img/@src" },
  },
  // 或 JS 完全模式：实现下列方法（优先于 selectors）
  async search(keyword, page) { /* 返回 MediaItem[] */ },
  async detail(url)           { /* 返回 MediaItem + Chapter[] */ },
  async content(chapterUrl)   { /* anime: 视频URL[]; manga: 图片URL[]; novel: 文本 */ },
};
```

引擎职责：
- 加载/缓存/校验规则；规则内发出的请求经统一网络栈（可挂代理、统一 UA、cookie 池）。
- **沙箱**：规则内只暴露受限 API（`fetch`, `xpath`, `parseHtml`, `crypto`, `log`），禁止访问本地文件。
- **规则仓库**：支持从 URL（GitHub repo / 任意 JSON 索引）批量导入、一键更新（对齐 Kazumi 规则仓库 + Miru 扩展仓库）。
- **WebView 兜底**：规则可声明 `useWebView: true`，用 inappwebview 渲染页面取结果（过 Cloudflare）。
- 版本号 + 更新检查；规则隔离崩溃不影响主程序。

### 4.4 漫画阅读器（对齐 Komikku）

- 四种模式：**RTL 翻页 / LTR 翻页 / 垂直条漫（Webtoon）/ 垂直滚动连续**。
- 导航：键盘方向键、鼠标点击左右区、滚轮、触摸滑动（Komikku 全部导航方式照搬）。
- 预加载前后各 2~3 章图片；双页模式（桌面端）；缩放适配（宽度/高度/原始）。
- 每部作品可单独记忆阅读模式（对齐 Mihon per-series 设置）。
- 阅读完成自动标记进度 + 上报追踪服务。

### 4.5 小说阅读器（对齐 Mixn 阅读器，功能逐项移植）

Mixn v1.17.0 阅读器已验证的功能清单，全部作为本项目小说阅读器的验收标准：

- **两种模式**：分页阅读 + 上下滚动。
- **排版调节**：字体（含可下载字体，独立预览页）、字号、行距、边距、背景（含护眼色）、进度条。
- **交互**：点击区域翻页、音量键翻页（Android）、屏幕方向锁定、屏幕常亮。
- **正文插图**：懒加载、协议相对地址与常见 CDN 兼容、点击放大、长按保存相册。
- **服务端专用字体**：源声明需要专用字体时（LNS），先持久缓存字体再渲染正文；字体加载失败显示来源错误，**不得显示混淆文本**（Mixn 不变量）。
- **付费章节**：标注锁定状态，引导走源内解锁流程；不解锁不缓存不导出。
- 繁简转换、替换净化、听书 TTS（二期，Mixn 暂无，属增量）。
- 章节缓存 + 整本/按卷下载；**EPUB 3 / TXT 导出**（EPUB 带封面与正文插图，TXT 用 `[插图]` 占位——Mixn 已有成熟实现可直接参考 `core/epub/`、`core/txt/`）。

### 4.6 追番播放（对齐 Kazumi）

- 播放器：桌面端继续使用 `media_kit/libmpv`；Android 使用 `TextureView + MediaPlayer.setDataSource(String)`，通过 Flutter Hybrid Composition 嵌入，避免 API 35 x86_64 模拟器上的外部纹理黑屏。倍速 0.5~3x、画面比例、手势亮度/音量/进度保持不变。
- 弹幕：弹弹play API 自动匹配 + 手动搜索；弹幕样式/过滤/透明度/速度设置。
- 多线路切换；失败自动换源；外部播放器调用；DLNA 投屏（二期）。Anime4K 超分按用户决定关闭，不列入后续实现。
- 新番时间表：Bangumi.tv API 按星期展示当季新番；更新提醒。

### 4.7 追踪与同步

- 内置追踪服务：**Bangumi（国内首选）+ AniList**，进度变更时上报；MyAnimeList 延后，不列入当前验收范围。
- **WebDAV 同步**书库/历史/设置（Kazumi 已验证可行的零服务器方案）。
- 本地备份导出/导入（JSON + 封面打包 zip）。

### 4.8 下载管理

- 漫画：按章节批量下载为本地图片目录 + CBZ 导出。
- 小说：章节文本入库。
- 番剧：视频下载（已在 M5 收口，支持渐进式 MP4/MKV 与明文 HLS；加密流拒绝）。
- 队列管理、断点续传、仅 WiFi 选项。

---

## 5. 数据模型（drift / SQLite 表）

```
sources      (id, name, type, lang, kind, version, enabled, rule_text, repo_url, updated_at)
media_items  (source_id, remote_id, type, title, url, cover_url, author, desc, tags, rating, status, detail_json, cached_at)
chapters     (source_id, remote_id, item_source_id, item_remote_id, title, url, number, sort_index, volume_title, release_date, locked, content_json)
library      (item_id PK, type, progress, score, watch_status, pinned, added_at, updated_at)
categories   (id, name, sort)
library_category (item_id, category_id)
history      (id, item_id, chapter_id, position, device, timestamp)   -- 番=秒, 漫=页, 小说=段落偏移
downloads    (id, item_id, chapter_id, status, progress, path)
track_binds  (item_id, service, remote_id)                            -- Bangumi/AniList/MAL 绑定
settings     (hive KV)
```

---

## 6. UI 设计规范（Komikku 风格移植）

### 6.1 设计语言

Komikku 的观感 = **GNOME libadwaita**：大留白、圆角卡片、无边框线（用背景色分层）、柔和投影、自适应布局。Flutter 落地为 **Material 3 + 以下 Design Token**：

| Token | 浅色 | 深色 | 说明 |
|---|---|---|---|
| 背景底色 | `#F6F5F4` | `#1E1E1E` | 窗口底色（Adwaita 灰白/炭黑） |
| 卡片色 | `#FFFFFF` | `#2B2B2B` | 书架卡片、设置组 |
| 强调色 | `#3584E4` | `#78AEED` | Adwaita 蓝；同时支持 Material You 动态取色覆盖 |
| 成功/更新提醒 | `#33D17A` | `#8FF0A4` | 新章节角标 |
| 圆角 | 12（卡片）/ 8（按钮）/ 999（chip） | 同 | Adwaita 标志性圆角 |
| 卡片阴影 | `0 1px 4px rgba(0,0,0,.12)` | 无（深色用明度分层） | 宁淡勿浓 |
| 间距基数 | 4 / 8 / 12 / 16 / 24 | 同 | 全局 8pt 网格 |
| 字体 | 系统默认（Win: 微软雅黑 / Android: Roboto + Noto Sans CJK） | 同 | 标题 20/17/15 三档字重 600/500/400 |

### 6.2 全局布局（自适应断点）

- **< 600dp（手机）**：底部 NavigationBar 四栏 —— `书架 │ 发现 │ 追番 │ 我的`。
- **600~1240dp（平板/小窗）**：NavigationRail 侧栏。
- **> 1240dp（桌面）**：Komikku 式 **Sidebar（源/分类列表）+ Content 区**，窗口最小 360×600，标题栏用自定义 header bar（ window_manager 去原生边框）。

### 6.3 页面清单与要点

1. **书架库页**（Komikku Library 复刻）：封面网格（2:3 比例圆角卡片，长按多选）；顶部搜索 + 筛选 chip 行（全部/番/漫/小说 + 分类）；封面右上角未读/更新角标；左侧可展开分类边栏。
2. **发现页**：源选择器 + 热门/最新列表；全局搜索（跨源并发搜索，结果按源分组折叠）。
3. **详情页**（Komikku Details 复刻）：顶部封面毛玻璃背景 + 大封面 + 标题/作者/标签/评分；操作行（追/已追、继续观看按钮、下载、分享）；Tab：章节列表（已读置灰、当前高亮、下载状态图标）│ 简介 │ 关联推荐。
4. **追番页**：周更时间表（周一~周日分栏，对齐 Kazumi 时间表）+ 在看列表（剩余集数徽标）。
5. **阅读器×3**：全屏沉浸，顶部/底部控制条点击呼出并自动隐藏；设置面板从底部弹出（圆角 sheet）。
6. **设置页**：Komikku Preferences 式分组列表（常规/书库/阅读器/播放器/规则管理/追踪账号/同步/关于），每组一个圆角卡片容器。
7. **规则管理页**：已装规则列表（类型图标+开关+更新按钮）；规则仓库浏览；剪贴板/文件/URL 三种导入方式。

### 6.4 动效与细节

- 页面切换：Material 3 fade-through；详情页 Hero 封面共享元素动画。
- 列表滚动：封面渐入（fade-in 300ms）；骨架屏占位。
- 主题：明/暗/跟随系统；OLED 纯黑选项；Material You 动态取色开关。

---

## 7. 实现路线图（里程碑）

| 里程碑 | 内容 | 验收标准 |
|---|---|---|
| **M0 脚手架** | Flutter 工程、go_router+Riverpod 骨架、drift 建表、主题 Token、自适应壳（四栏导航） | 三端跑起空壳，明暗主题切换正常 |
| **M1 规则引擎** | JS 沙箱 + XPath 简式层 + 规则管理页 + 发现/搜索/详情数据通路 | 用一个漫画源和一个番剧源跑通「搜索→详情→章节列表」 |
| **M2 漫画闭环** | 漫画阅读器四模式、书架、阅读进度、历史 | 完整看完一章并记录进度，重启后续读 |
| **M3 追番闭环** | 跨平台播放器（桌面 media_kit、Android 原生 TextureView）、弹幕、追番时间表、多线路 | 播放任意番剧带弹幕，加入追番列表 |
| **M4 小说闭环** | 小说阅读器、章节缓存、（对接 mixn 源格式） | 完整阅读一章小说，调字号主题生效 |
| **M5 增强** | 下载管理、Bangumi/AniList 追踪、WebDAV 同步、备份导入导出 | 进度上报 Bangumi；两台设备 WebDAV 互同步 |
| **M6 二期** | iOS/macOS/Linux 适配、DLNA、TTS、一起看 | 视精力排期；Anime4K 已关闭，视频下载已在 M5 收口 |

---

## 8. 交接任务清单（下一个模型按此顺序动工）

> 每个任务完成后再开下一个。所有代码提交到 git，每个任务一个 commit。

- [x] **T1（M0）**：`flutter create triomi`，配置 `analysis_options.yaml`（严格 lint），接入 go_router + Riverpod + drift + hive_ce；实现第 6 章 Design Token 的 `AppTheme`；搭建自适应四栏壳（含空页面占位）。
- [x] **T2（M1）**：定义 `MediaItem/Chapter/TrackEntry` 模型与 drift 表（按第 5 章）；实现 `SourceEngine`：flutter_js 沙箱、受限 API 注入（fetch/xpath/parseHtml）、XPath 简式规则转 JS 实现；写 2 个内置示例规则（1 漫画 + 1 番剧，用真实可用站点）；规则管理页（列表/开关/删除/剪贴板导入）。
- [x] **T3（M1）**：发现页 + 全局搜索 + 详情页（不含阅读器），数据全部走 SourceEngine；封面 Hero 动画 + 骨架屏。
- [x] **T4（M2）**：漫画阅读器（四模式、预加载、进度记录）；书架页（加入/移除/分类/角标）；历史页。
- [x] **T5（M3）**：播放器页（media_kit、手势、倍速、多线路）；canvas_danmaku 弹幕接入弹弹play；追番时间表页（Bangumi API）。
- [x] **T6（M4）**：小说模块全量移植，**验收标准 = 2.4 清单 A~G 逐项打勾**。拆解：
  - ① **LK/LNS 内置适配器**（Dart 重写，参照 Mixn `source/lightnovelkingdom/`、`source/lightnovelshelf/`）：LK 走 HTTP 接口；LNS 用 `signalr_netcore` 对接 SignalR + 服务端专用字体缓存加载（B7）；实现能力接口全家桶——`AccountProvider`（独立登录态、会话恢复、`flutter_secure_storage` 存凭据）、`RemoteShelfProvider`、`ProgressSyncProvider`、`UnlockProvider`（LK 付费章节）、`CommentProvider`（LK）、`RewardProvider`（两源签到）、LNS 收藏同步（清单 C1~C3）；
  - ② **小说阅读器**：TextPainter 分页 + 滚动双模式，B3~B6 逐项过；正文插图处理（B5）；
  - ③ **下载与导出**：D1~D5（EPUB 3/TXT 参照 Mixn `core/epub/`、`core/txt/`）；
  - ④ **字体与外观**：E1~E3，字体下载预览页；
  - ⑤ **隐私红线**：F1~F3 作为代码审查检查项；
  - ⑥ LK 站点功能页（资料/轻币/签到/关注粉丝/发布管理/消息中心，C2）可作为 T6 收尾或独立子任务，工作量大则排入 M5。
  Mixn 为 MIT 且属用户自有代码，可直接移植改写；注意是**参照重写为新 App 的 Flutter 代码**，不是在 Mixn 仓库上改。
- [x] **T7（M5）**：下载管理器（漫画/小说）；Bangumi + AniList OAuth 绑定与进度上报；WebDAV 同步服务；本地备份导入导出。
- [x] **T8**：README（含免责声明、规则编写指南链接）、GPL-3.0 LICENSE、CI（GitHub Actions 构建 Android APK + Windows zip）。✅ 2026-09-29 完成：免责声明/CI 说明在 README，许可证是 GitHub Licenses API 拉的标准 GPL-3.0 全文，CI 见 `.github/workflows/build.yml`（analyze+test / Android APK / Windows zip）。

> **状态（2026-10-01）**：T1~T8 全部完成。Android 视频画面合成已由原生
> `TextureView + MediaPlayer` 路径修复，并在 API 35 x86_64 模拟器正式播放器中
> 通过像素与帧变化验收；真实物理 Android 手机仍需一次兼容性复验。其余设备/真实账号
> 偏差清单见 [`docs/handoff/README.md`](handoff/README.md)。

**给实现模型的硬约束**：
1. 任何页面先过第 6 章 UI 规范，禁止裸用默认 Material 样式交差。
2. 规则引擎是核心，所有内容数据禁止硬编码进 UI 层。
3. 参考 Kazumi/Miru/Komikku 时只可学习架构与 API 用法，**禁止整段复制源码**（许可证见 2.2-4）。
4. 每个里程碑结束跑一次 `flutter analyze` + 真机/真窗体验证。

---

## 9. 风险与注意事项

1. **法律/版权**：App 不内置任何内容源，默认无规则；README 必须带免责声明（"本软件与任何内容提供方无关，规则由用户自行添加"）。这是 Komikku/Kazumi 的标准做法。
2. **许可证**：建议 GPL-3.0 开源；若未来想闭源商用，则一行参照项目的代码都不能看进实现里。
3. **反爬对抗**：部分站点有 Cloudflare/防盗链 → WebView 兜底 + Referer 注入 + cookie 池，这些能力在 M1 就要预留接口，别后补。
4. **弹幕匹配准确率**：弹弹play 按文件名/标题匹配会错配，需保留「手动搜索弹幕」入口（Kazumi 的做法）。
5. ~~mixn 信息缺口~~（已解决，2026-09-22）：Mixn = `HyperionHXH/lightnovel-android-aggregator`（分支 `feature/multi-source-foundation`），Kotlin + Compose，MIT，内置 LK/LNS 双源。结论已并入 2.3 / 3.1 / 4.3 / 4.5 / T6。**遗留确认项**：Mixn 现有书架/阅读进度数据是否需要从 Mixn App 迁移到新 App？如需迁移，在 T7 备份格式中预留 Mixn 导入器（Mixn 侧需先提供导出，或新项目直接读其私有目录——仅同一设备且用户授权时可行）。
6. **LNS 协议风险**：SignalR 与专用字体是站点私有协议，可能随时变更（Mixn CONTEXT.md 已声明此边界）。适配器必须集中隔离协议代码，接口变更时只改适配器。

---

## 附：参考链接

- **Mixn（用户自有，小说模块直接参照）**: https://github.com/HyperionHXH/lightnovel-android-aggregator/tree/feature/multi-source-foundation
  - 来源契约：`app/src/main/java/io/github/jiangyuyi/lightnovel/core/source/SourceContracts.kt`
  - LK 适配器：`app/.../source/lightnovelkingdom/`；LNS 适配器：`app/.../source/lightnovelshelf/`
  - EPUB/TXT 导出：`app/.../core/epub/`、`app/.../core/txt/`
  - 架构文档：仓库内 `CONTEXT.md`、`docs/AGGREGATOR_PLAN.md`、`docs/adr/0001-built-in-source-adapters.md`
- Komikku: https://codeberg.org/valos/Komikku （GNOME Apps 页面有全套界面截图，UI 复刻照它画）
- Kazumi: https://github.com/Predidit/Kazumi （规则格式、播放器、弹幕、WebDAV 同步实现参考）
- Miru: https://github.com/miru-project/miru-app （三合一架构、JS 扩展 API 设计的最直接参照）
- Mihon: https://github.com/mihonapp/mihon （书库/章节/追踪的领域设计参考）
- 弹弹play API: https://api.dandanplay.net
- Bangumi API: https://bangumi.github.io/api/
- AniList GraphQL: https://anilist.gitbook.io/anilist-apiv2-docs/
- Dart SignalR 客户端: https://pub.dev/packages/signalr_netcore （LNS 适配器用）
