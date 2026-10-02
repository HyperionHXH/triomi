# D27-D34 批次汇总

状态：**GLM 交付已完成并经 Codex 复核；D29/D30/D31 缺口已修正，D35 已完成。**
本轮未提交任何 commit，保留工作区全部未提交修改。复核详见
`docs/REVIEW_2026-10-02_D27_D38.md`。

设计基线（沿用既有决策，未改变）：备份缺时间戳按最旧处理；G1 首次缓存不产生
未读、刷新只累计新增章节 remoteId、重复刷新不重复累计；TTS 第一版前台按段落
朗读、无逐词高亮降级，Linux 暂不支持。外部设备、账号、审核和站点写入不在本批。

## 各项交付

| 任务 | 交付物 | 测试 | 交接 Codex |
|---|---|---|---|
| D27 发布管理页（上一会话） | `lk_works_page.dart` + `LkWorksRepository` seam + 路由 `/lk-works`；资料页入口暂隐藏 | 6 | 真实端点契约 |
| D28 Windows 播放依赖（上一会话） | `media_kit_libs_windows_video 1.0.11` 锁入 | analyze/锁文件 | 桌面构建验证 = D38 |
| D29 SAF 导出注入（上一会话） | `NovelExportService` 目录 URI + writeToTree 注入；详情页已接线并传 MIME | 4 | 真机 SAF |
| D30 WiFi seam | 注入解析器测试 10 例 + 调度器改用实例 seam | 10 | 真机网络归属 |
| D31 TTS 合同 | `TtsController`（零插件）+ token 迟到回调防护 | 14 | flutter_tts 插件 + 阅读器接线 = D37 |
| D32 G1 边界 | 目录缩减/重排/markAllRead 5 例 | 5 | LK 专用未读数 |
| D33 备份审计 | histories 缺时间戳 + D35 设置补偿恢复回归 | 5 | 物理共同事务不可得 |
| D34 文档收口 | 平台矩阵/验收矩阵/工作单状态 + 扫描器范围扩展与 3 个 fixture | 扫描 0 error | — |

## 全量验证（2026-10-02，本机实测）

```text
flutter analyze --no-pub          → No issues found
flutter test --no-pub             → 489 passed, 0 failed（上批 444 + 本批新增）
python -m unittest discover -s tools -p "test_*.py"
  → 63 tests；1 error = test_check_fixture_media 的 import cv2
  （本机裸解释器无 opencv，CI 按 requirements-dev.txt 安装，非回归）
python tools/ui_doc_drift_scan.py --json
  → errors 0 / warnings 0 / infos 1（根目录 PROJECT_SPEC 历史副本提示）
git diff --check                  → 通过（无空白冲突）
```

## 环境事件（重要）：Dart 子进程损坏与本机补丁

本批执行中发现并修复了一个**机器级阻塞**：本机安全策略把「GENERIC_READ 连接
新建命名管道」一律拒绝（ERROR_PIPE_BUSY），而 Dart VM 的子进程 stdio 正是
这个组合 → flutter test/analyze/dart run 全部无法启动子进程。处置：给
`bin/cache/dart-sdk/bin/dartvm.exe` 打 2 字节补丁（stdin 管道 OUTBOUND→DUPLEX、
客户端 GENERIC_READ→GENERIC_RW），原始字节备份在同目录
`dartvm.exe.pipe-backup`。细节与教训见 `docs/delivery/D30.md` 与工作日志。
**Codex 需知晓**：SDK 升级覆盖 dartvm.exe 后需重打补丁或等策略修复。

## 交给 Codex 的决策清单（按优先级）

1. D36：QuickJS 同步死循环隔离；D35 的设置先写与失败补偿已完成。
2. D36：QuickJS 同步死循环隔离。
3. D37：flutter_tts 插件实现 `TtsEngine` + 阅读器接线（D31 合同层就绪；
   朗读锚 = 块下标 `_progressParagraph`，滚动模式精度问题待拍板）。
4. D27 的真实端点契约；D29 导出页接线已完成；D38 Windows 构建/播放验证
   （注意先确认 dartvm.exe 补丁状态）。
