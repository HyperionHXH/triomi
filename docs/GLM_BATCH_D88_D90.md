# GLM 批次 D88-D90：发现优先与阅读书架收口

状态：Codex 已审核并补缺（2026-10-05）。D88 导航、D89 阅读过滤、D90 安全回归通过；D89 原「去追番」误指远端账号页及缺少本地收藏的问题已由 D91 修正。最终审核见 [批次总结](delivery/BATCH_D88_D91_SUMMARY.md)，下一批见 [D92-D98](GLM_BATCH_D92_D98.md)。下面是原分配要求，执行结果以总结和更新后的 ADR 为准。

目标：让用户打开应用先看到可探索的新内容，并把漫画、小说统一到一个阅读书架；动画追踪继续使用独立入口。一次完成下面整批工作，完成后逐项写入对应 delivery 文档。

## D88：主导航与默认首屏

允许修改：`lib/core/router/app_router.dart`、`lib/features/shell/adaptive_shell.dart`、相关导航 widget 测试和 `docs/PROJECT_SPEC.md` 的当前规格段落。

- 将 `initialLocation` 改为 `AppRoutes.discover`。
- 将手机底部栏、中屏 rail、桌面侧栏统一调整为“发现、书架、追番、我的”。
- 保持每个分支的返回栈和重复点击回到根页面行为。
- 更新可访问性标签、图标语义和导航测试；测试必须断言顺序和默认路由，不要只断言控件存在。
- 不改数据库、来源规则和详情页业务。

验收：`app_shell_test.dart` 或新增等价测试能证明四栏顺序、发现选中态和启动路由；`flutter analyze` 通过。

## D89：阅读书架范围与番剧兼容

允许修改：`lib/features/library/library_page.dart`、`lib/features/library/data/library_providers.dart`、必要的 repository 查询测试和详情页入口测试。

- 书架默认显示漫画和小说，页面标题和空状态明确表达“漫画与小说”。
- 保留漫画/小说筛选与阅读进度、未读角标、历史入口、来源失效缓存展示。
- 不删除 `MediaType.anime` 数据；提供兼容查看方式，或在代码中明确可审计的旧数据迁移入口。
- 动画详情的新收藏动作必须进入追番/追踪工作流，不能把新番剧写入阅读书架。若跨模块改动超出本批次，记录为 Codex D91 缺口，不要伪造完成。
- 不能通过修改测试夹具来掩盖番剧条目边界。

验收：repository/widget 测试覆盖默认过滤、漫画/小说切换、旧番剧数据不丢失和空状态文案；已有书架移除、进度、历史测试继续通过。

## D90：回归、编码与交付记录

允许修改：本批次新增/更新的测试、`docs/delivery/D88.md`、`docs/delivery/D89.md`、`docs/delivery/D90.md`，以及必要的 UTF-8 检查记录。

- 运行 `flutter analyze`、相关 focused tests 和全量 `flutter test`；命令不可用时如实记录环境阻塞。
- 运行仓库现有编码检查，不能把乱码输出或失败测试改成跳过。
- 记录实际修改文件、测试命令、通过/失败数量和剩余 Codex 缺口。
- 不修改 `assets/rules/bangumi-anime.json` 的资料源边界，不把 fixture 证据写成真实网络通过。

## 交付格式

完成后回复每项的文件列表、验证命令与结果、未完成原因。若 D89 发现需要数据库迁移或详情页跨模块重构，保留现状并在 `docs/delivery/D89.md` 标记为 Codex D91，不要扩大范围。
