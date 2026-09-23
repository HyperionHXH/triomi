# T4 · LNS（轻书架）SignalR 适配器——协议层

> 对应规格：2.4 A1（双源独立发现）/ B7（服务端专用字体）/ C3（资料/收藏/
> 签到）。参照实现（必读）：`_refs/mixn/.../source/lightnovelshelf/` 四个文件。
> **本任务只做协议层 + 单测**；真实联调需要 LNS 账号（账号到了由本机联调）。

## 现状

- LK 适配器已在本项目落地（`lib/features/novel/data/lk/`，双轨注册的
  `builtinAdapters` 机制可复用——LNS 作为第二个内置适配器挂同一机制）。
- 统一模型：`MediaItem / Chapter / ChapterContent`（`lib/core/models/`）；
  能力契约 `lib/core/source/source_api.dart`（LNS 需实现
  `DiscoverProvider / SearchProvider / DetailProvider / ContentProvider /
  AccountProvider`）。
- WebSocket：Dart 原生 `WebSocket`（dart:io）即可，不需要新插件。

## 协议规格（从 Mixn 提取，照此实现即可）

### 传输
- Hub：`https://api.lightnovel.life/hub/api`；备用（Cloudflare）：
  `https://cf-api.lightnovel.life/hub/api`（主端网络错误时降级一次）。
- WebSocket 连接参数：登录后带 `?access_token=<token>` 且加
  `Authorization: Bearer <token>`。
- **SignalR JSON 协议**：帧以 `\u001e`（record separator）分隔；
  握手：连上后服务端发 `{}` + `\u001e` 即成功（带 `error` 字段即失败）；
  请求帧：`{"type":1,"invocationId":"<递增字符串>","target":"<方法名>",
  "arguments":[<params>, {"UseGzip": true}]}` + `\u001e`；
  完成帧按 `invocationId` 匹配（type 1，含 `result` 或 `error`）。
  超时：握手 15s、调用 30s；断线 `reset()`（取消全部 pending 并重连）。
- **响应解码**：`UseGzip` 时 result 是 Base64(GZIP(JSON))，先 Base64 解码
  再 gzip 解压再 JSON.parse（Dart 用 `GZipCodec`，dart:io 内置）。
- **限流**：9 请求 / 5.5 秒滑动窗口（超出排队等待，不是报错）。

### Hub 方法（target 与参数，照 Mixn Protocol.kt）
| 方法 | 参数 | 说明 |
|---|---|---|
| `GetBookList` | `{Page, Size(≤50), Order: latest/new/view, KeyWords?, IgnoreJapanese, IgnoreAI}` | 发现（三频道=三个 Order）与搜索共用 |
| `GetRank` | `{Days}` | 排行 |
| `GetBookInfo` | `{Id}` | 详情；目录字段优先非空数组：`Chapters/chapters/Chapter/chapter/ChapterList/chapterList`（重复 SortNum 视为解析错误） |
| `GetNovelContent` | `{Bid, SortNum, Convert?}` | 正文（Convert: `t2s`/`s2t`/null）；返回含 `fontUrl`（B7 专用字体）与 `chapterTitles` |
| `SaveReadPosition` | `{Bid, Cid, XPath}` | 进度回传 |
| `GetBookShelf` | 无参 | 远端书架快照（version + items，item 有 BOOK/FOLDER 两种） |
| `SaveBookShelf` | `{data: [...], ver}` | 保存书架 |
| `GetBooksByIds` | `{Ids: [..]}` | 批量取书籍 |
| `GetReadHistory` | 无参 | 阅读历史 |
| `GetMyInfo` | `{}` | 资料（coin / signInStreak / signedToday） |
| `SignIn` | `{}` | 签到 |
| 登录 | 见 Mixn `LightNovelShelfAuth.kt`（email/password → token） | 会话管理照搬 Auth 类 |

## 实现规格

### 文件（新建 `lib/features/novel/data/lns/`）
1. `lns_hub_connection.dart`：`LnsHubConnection` 抽象（`invoke(target, params)` /
   `reset()`）+ WebSocket 实现 + `FallbackLnsHubConnection`（主端 NETWORK 错误
   降级备用端一次）。**连接抽象必须可注入**（单测用假连接）。
2. `lns_gateway.dart`：把 hub 调用映射成领域对象（`LnsBook / LnsBookPage /
   LnsBookDetail / LnsNovelContent / LnsRemoteSnapshot / LnsProfile`），
   字段解析沿用 LK 的多候选键宽松风格（参照 `lk_client.dart` 的 `_pick` 族）。
   限流器 `ShelfRateLimiter`（9 / 5.5s，可注入时钟便于测试）。
3. `lns_source.dart`：`LnsSource implements DiscoverProvider, SearchProvider,
   DetailProvider, ContentProvider, AccountProvider`，映射到统一模型；
   注册进 `builtinAdapters`（参照 `source_providers.dart` 里 LK 的挂法）。
4. 专用字体（B7）只做**数据通道**：`ChapterContent` 无法承载字体地址，
   在 `lns_source.dart` 内做进程内缓存（fontUrl → 下载字节 →
   `UserFontStore` 同款 FontLoader 注册），正文字体接入归本机集成；
   **取不到字体时返回来源错误，绝不显示混淆正文**（B7 红线）。

### 错误分类
连接/超时 → network；服务端 error 帧 → server；解析缺字段 → parse；
登录失败 → auth（消息透出）。

## 测试要求（test/t4_test.dart）

1. 帧协议：用假 WebSocket 验证握手（`{}` 分隔帧 = 成功）、invocationId
   匹配、乱序帧按 id 正确配对、`\u001e` 粘包拆包。
2. GZIP 解码：手工 gzip+base64 的夹具数据 → 正确 JSON。
3. 限流器：注入假时钟，10 次调用中第 10 次等待 ≥500ms。
4. 降级：主端 invoke 抛 NETWORK 时切备用端且只切一次；非 NETWORK 错误不切。
5. GetBookInfo 目录解析：Chapters 为空时回退 Chapter；重复 SortNum 抛 parse。
6. LnsSource 映射：详情/正文 → 统一模型（fontUrl 被记录，正文 html 进
   `ChapterContent.html`）。

## 验收标准

- analyze 零问题；测试全绿；**不注册到 builtinAdapters 的默认启用列表**——
  LNS 未联调前作为「内置但默认停用」来源（`sources` 表 enabled=0），
  联调通过后再翻转（翻转由本机做）。
- 凭据（token/email/password）不落日志。

## 后续集成点

- 本机：拿到 LNS 账号后联调（登录/发现/详情/正文/书架/签到）、把
  fontUrl 的字体注册接到阅读器、翻转默认启用、模拟器 E2E。
