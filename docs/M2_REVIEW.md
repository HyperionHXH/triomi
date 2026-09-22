# M2 复查记录（漫画闭环：阅读器 + 书架 + 历史）

日期：2026-09-22 ｜ 对应任务：M2 ｜ 状态：**已完成**

## 1. 本轮交付

| 模块 | 文件 | 说明 |
|---|---|---|
| 书架 / 历史数据层 | `features/library/data/library_repository.dart` | 书架增删查、目录缓存（整作品覆盖式写入）、进度、历史（同章去重）、作品快照缓存 |
| 状态管理 | `features/library/data/library_providers.dart` | 书架列表（含筛选）、历史、单作品是否在书架 |
| 漫画阅读器 | `features/reader/manga_reader_page.dart` | **四种模式**（LTR / RTL / 上下翻页 / 条漫滚动）、点击分区翻页、中间呼出控制条、键盘方向键、鼠标滚轮、缩放、章内进度条、章节目录、阅读设置面板、相邻章预取 |
| 阅读设置 | `features/reader/reader_settings.dart` | 模式 / 图片适配 / 背景色，独立于界面外观设置持久化 |
| 书架页 | `features/library/library_page.dart` | 真实数据网格/列表、内容形态筛选、进度角标、长按移出 |
| 历史页 | `features/history/history_page.dart` | 相对时间、章节标题、清空历史 |
| 详情页改造 | `features/detail/detail_page.dart` | 「加入书架 / 已在书架」真实可用；章节点击进阅读器（漫画）/给出里程碑提示（番剧、小说） |
| 数据库 | `core/db/app_database.dart`、`tables.dart` | **schemaVersion 2**：作品与章节补 `url` 列 + 迁移步骤 |

## 2. 验收结果

| 检查项 | 结果 |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test` | **39 passed**（M0/M1 的 21 个 + 本轮 18 个） |
| `dart format` | 0 变更 |
| `flutter build web` | 成功 |

**本轮新增的测试覆盖**（都断言行为，不是"能编译"）：

- **数据库（11 个）**：v2 表结构含 `url` 列、加入书架会缓存作品快照（含 url/标签/评分）、重复加入不产生第二条、按内容形态筛选、进度写回、目录覆盖式保存与排序、历史记录带章节标题、同章去重、`lastReadOf`、清空历史、目录未缓存时降级不崩
- **书架页（4 个）**：空状态与入口、渲染 + 筛选切换、进度角标、长按移出（含确认框与数据库核实）
- **阅读设置（3 个）**：默认值、持久化后重建仍生效、恢复默认不影响界面外观设置

## 3. 复查中发现并修复的问题

| # | 问题 | 性质 | 处理 |
|---|---|---|---|
| 1 | **`context.palette` 在主题缺少 `AppPalette` 扩展时直接抛 null 检查错误** | 健壮性缺陷（测试立刻暴露） | 改为按亮度回退到默认色板，单测/嵌入场景少配主题也能画出可用配色 |
| 2 | 作品与章节表**没有 `url` 列** —— 从书架点进详情、阅读器取正文都会因为丢地址而失败 | 数据模型缺漏 | 补列，schemaVersion 1→2，并写了迁移步骤（这是本项目第一次真实改表） |
| 3 | `PageController` 在换章/切模式时**同步 dispose 后仍被树上的 PageView 引用** | 崩溃隐患 | 改为先替换、再 `addPostFrameCallback` 释放旧控制器 |
| 4 | 书架/搜索/发现三处各写列表卡片的迹象（角标、长按） | 重复实现 | 卡片统一到 `media_item_card.dart`，`MediaItemCollection` 暴露 `onTapItem` / `onLongPressItem` / `badgeOf` 回调 |
| 5 | 阅读器 `_error` 用 `Object?` 承载字符串，错误 UI 传参类型不匹配 | 类型问题 | 收敛为 `String?` |
| 6 | 外壳测试未隔离数据库 → 页面加载动画让 `pumpAndSettle` 超时 | 测试设计 | 注入内存库；同时给书架页测试套上真实主题 |
| 7 | 阅读器的「图片重试」只 `setState` 而不清缓存，失败图会一直失败 | 功能缺陷 | 先 `NetworkImage.evict()` 再重建 |

## 4. 已知缺口

1. **阅读器交互没有真机/真窗口验证**。逻辑（模式切换、翻页边界、进度写入）由单测覆盖，
   但手势手感、图片预取效果、沉浸式全屏行为需要**在 Android 或 Windows 上实测**——本机无 VS / Android SDK。
2. **进度写入较频繁**：每次翻页都写一次历史。数据量大了以后应加节流（例如停止翻页 1 秒后写）。
3. **每章都会请求一次正文**，没有章节内容缓存；M5 的下载功能会一并解决。
4. **条漫模式的页号是估算的**（按滚动比例换算），进度条在超长章节里会有偏差。
5. **没有 migration 自动测试**：drift 的 schema 工具链（`drift_dev schema dump`）可以生成版本快照做升级测试，
   本轮只靠 `library_repository_test` 断言目标结构。
6. Web 预览仍只能看壳（drift 需要 sqlite3 WASM 资源）。

## 5. 下一步

- **M3（追番闭环）**：media_kit 播放器、弹幕（弹弹play）、Bangumi 时间表。
  注意：播放器是原生插件，**会破坏 Web 预览通道**，需要提前确认；届时必须在一台能跑 Android/Windows 的机器上验证。
- **M4（小说闭环）**：小说阅读器 + LK/LNS 适配器移植（Mixn 功能全量对齐）。
- 长期：JS 沙箱（T2b）、进度写入节流、章节内容缓存。
