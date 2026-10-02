# GLM 批次 D39-D46：可验证的收口工作

本批给 GLM 一次性处理简单但繁琐的纯代码、测试和文档工作。保留所有工作区未提交修改；不得猜测真实站点端点、不得索要或写入账号凭据、不得把夹具测试写成真机验收。每项新增 `docs/delivery/Dxx.md`，最后写 `docs/delivery/BATCH_D39_D46_SUMMARY.md`。

| 任务 | 工作 | 验收 | 禁止/交接 |
|---|---|---|---|
| D39 | 为 D29 导出页面 seam 增加 widget 测试：SAF 取消、EPUB/TXT MIME、写入失败回退提示 | 相关 Flutter 测试 + analyze | 不改 Android 真机流程 |
| D40 | 为 D30 调度器增加注入 resolver 的多任务停泵/恢复测试，覆盖 1 条与多条 pending | Flutter 测试 | 不读取真实网卡作断言 |
| D41 | 为 D31 TTS 增加带 token 的迟到完成回调测试、seek/stop 后回调丢弃测试、speak 抛错测试 | Flutter 测试 | 不接插件；插件由 Codex D37 |
| D42 | 审计导出、备份、WebDAV 错误文本，补充路径/URI/凭据脱敏回归 | Flutter/Python 测试 | 不打印真实凭据 |
| D43 | 补 `PlatformChannel.writeToTree` 的 MIME 契约测试与 Android Kotlin 静态文档，确认旧备份 zip 调用兼容 | 测试 + 文档 | 不声称 Android 设备通过 |
| D44 | 扩大 fixture contract 扫描：D27-D35 交付文档、测试命名、状态表一致性 | Python unittest | 不改业务行为 |
| D45 | 更新 `ACCEPTANCE_MATRIX.md`、`PLATFORM_DEPENDENCY_AUDIT.md`、README 的状态和命令，清理把 D27/D29/D31/D33 写成完成的旧句子 | 文档漂移扫描 0 error | 保留外部阻塞原文 |
| D46 | 跑全量 analyze/test/Python 工具，汇总失败分类、耗时和环境限制 | 批次汇总 | 不修改 Flutter SDK 二进制 |

## Codex 自留

- D36：设计并实现可杀死的 QuickJS worker 边界；若当前插件无法提供，写 ADR 与最小可替换接口，不做假 Timer 修复。
- D37：选择并接入 TTS 插件，实现 `TtsEngine` 适配器与阅读器前台控制，锁定章拒绝朗读；Linux 与无词级标记平台按合同降级。
- D38：在工具链恢复后做 Windows 构建与桌面播放出画验证；当前先记录 doctor 阻塞。
- D27：获得真实、可审计的接口契约后实现 adapter，并恢复入口。
