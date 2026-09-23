# M4 复查记录（小说闭环 · 第一阶段）

**日期**：2026-09-23 ｜ **提交**：feat(M4)

> M4 按 Mixn 功能全量对齐的验收清单（PROJECT_SPEC 2.4 A~G）体量很大，
> 本阶段先落**核心阅读闭环 + LK 适配器主干**；LNS（SignalR）、评论/私信/福利中心、
> EPUB/TXT 导出、字体管理归 M4b（见文末清单）。

## 交付内容

### 小说阅读器（对齐 Mixn ReaderScreen 的核心能力）
- **双模式**：分页（TextPainter 逐段排版、跨页段落按行切分、首行缩进用全角
  空格参与测量）与滚动（ListView + 滚动进度估算）。
- **分页引擎**移植自 Mixn 的 `ReaderContentParser` + `ReaderPagination`：
  HTML 块级解析（p / h1-h6 / img，HTML 实体解码、`[res]` 标记占位）、
  插图块按宽高比预留高度、块序号贯穿分页结果供进度回传定位段落。
- **阅读设置**独立持久化（与漫画阅读器、界面外观互不影响）：
  模式 / 主题（洁白·羊皮纸·夜间）/ 字号 / 行距 / 页边距，设置 sheet 即改即生效。
- **进度**：分页按页码、滚动按滚动比例折算段落下标；防抖 3 秒落库；
  退出时补写最后一次（沿用 M3 的「dispose 不碰 ref」模式）。
- **付费章节**：锁定章节显示官方解锁入口，走 `ChapterUnlockProvider`
  （服务端确认成功才记本地已解锁标记，绝不绕过、不伪造）。
- 登录来源（LK）在章节打开时**回传阅读进度到站点**（尽力而为）。

### 轻之国度（LK）内置适配器
- `LkClient`：pc-proxy 信封解析（code/data 剥壳）、会话（security_key 存
  Preferences，凭据不落日志）、宽松字段解析（多候选键兼容站点改版）。
- 已实现端点：home 系列榜单、book-rank-list（固定 30 条快照截断）、
  apk-search、get-book-detail、get-book-volumes、get-volume-chapters（分页聚合）、
  get-chapter-detail、auth-password-login / auth-session-v1（恢复）、
  bookshelf、toggle-book-shelf、save-book-history、unlock-chapter。
- `LkSource` 实现能力契约：Discover / Search / Detail / Content / Account /
  ChapterUnlock；卷→章两级目录展开为带 volumeTitle 的章节列表。
- **真实站点验证**：宿主直连 `lightnovel.fun` home-feed-v1 成功（code 0、
  5 本书、标题/作者字段与解析器吻合）。
- 来源管理页对有账号能力的来源显示「账号」入口（登录/登出对话框）。
- 注册表支持**内置适配器双轨**：`builtinAdapters` 注入，ruleText 为空的
  行按适配器解析（替代"尚未实现"的失败占位）。

### 夹具与测试
- 夹具服务新增小说站（/novel/list、/novel/{id}、/novelchapters、/novelread，
  正文含 24 段 + 插图）与 `local-fixture-novel.json` 规则（仅 debug 播种）。
- 13 个新测试：正文解析（HTML/纯文本/实体/协议相对地址）、分页器
  （跨页不丢字、插图顺延、块序号保序）、LK 客户端（信封错误、评分折算、
  解锁覆盖、解锁业务失败不落标记、登录会话）、卷章映射、正文映射。

## 模拟器 E2E 发现并修复的问题

1. **分页器每段只取半行**：`getPositionForOffset` 的命中点 x 用了行中
  （`pageWidth / 2`），命中行中间字符——改为命中**最后一行右端**
  （`Offset(pageWidth, lastLine.baseline)`）。这是从 Compose `getLineEnd`
  翻译到 TextPainter 时的语义错译，用探针测试定位。
2. **页码行高度没算进分页**：渲染区比分页区矮 22px → 每页底部溢出
  16px（黄黑条纹）。contentHeight 扣除页码行高并给页码固定 SizedBox。
3. **控制条吞掉全屏点击**：`ColoredBox` 的命中测试是 opaque，全屏遮罩
  让阅读器所有 tap 失效（播放器没事是因为它用显式手势层）。遮罩改为
  GestureDetector（点空白收起控制条，按钮优先命中）。
4. **夹具服务 `/novel/` 路由复制粘贴错误**：调成了 `anime_detail_page`，
  详情页显示番剧简介——靠服务端请求日志 + 直接 curl 定位。
5. **Dart RegExp 与 Kotlin 的差异**：`[^]]` 在 Dart 不是"非 ]"字符类
  （Kotlin/JS 是），`[res]` 标记正则静默失配——改为 `[^\]]` 并注释。
6. LK 列表接口的 `rating_score_10` 可能为 0（详情才有），解析器已兜底不误报。

## 验收状态

| 检查 | 结果 |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | **59 passed**（+13） |
| `flutter build apk --debug` | 成功 |
| 模拟器 E2E | 夹具小说源 → 详情（简介/卷章目录）→ 阅读器分页
  （羊皮纸主题、首行缩进、跨页段落、1/6→2/6 翻页、控制条收起） |
| 真实 LK 接口 | 榜单直连解析通过（正文/账号需登录，留待有账号环境验证） |

## M4b 待办（Mixn 全量对齐的剩余部分）

- **LNS（轻书架）适配器**：SignalR 实时协议（`signalr_netcore`）、
  服务端下发专用字体的缓存与加载——需要登录账号调试。
- **LK 站点功能页**：评论区（浏览/发布/点赞/评分/表情/图片上传）、
  消息中心、私信、福利中心签到、关注/粉丝、发布管理。
- **下载与导出**：按卷离线下载（仅 WiFi 开关）、EPUB 3 / TXT 导出
  （参照 Mixn `core/epub/`、`core/txt/`）。
- **字体外观**：可下载字体、阅读字体选择（参照 Mixn `core/reader/`）。
- **远端书架 UI**：聚合书架显示远端收藏与未读数（接口已就绪）。
- 繁简转换、后台更新提醒、书架迁移导入器。
