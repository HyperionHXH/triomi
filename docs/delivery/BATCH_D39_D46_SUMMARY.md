# D39–D46 全批交付汇总

> Codex 已复核，D40-1 修复、TTS 插件与阅读器接线、JS 异步取消已落地。下文保留 GLM 原始交付数据；最新结果与未完成边界以 `docs/REVIEW_2026-10-02_D39_D46.md` 为准。下一批为 D47-D58。
> Codex 最终复验：Flutter 529/529、Python 79/79、analyze 零问题、Android debug 构建成功；交付扫描 0E/0W、漂移扫描 0E/0W/1I。外部设备发声/Windows 出画没有完成。

> 日期：2026-10-02。执行：GLM。依据 `docs/GLM_BATCH_D39_D46.md`；
> 前置阅读 `docs/AFTER_M5_PLAN.md` 与 `docs/REVIEW_2026-10-02_D27_D38.md`。
> 逐项明细见 `docs/delivery/D39.md`–`D46.md`；本文件只留接收与修复排序所需证据。

## 汇总表

| 任务 | 交付文件 | 新增覆盖（已有覆盖引用） | 实际命令 | 通过/失败/跳过 | 发现 |
|---|---|---|---|---|---|
| D39 | `test/detail_export_page_test.dart` | 详情页真实导出流程 widget 回归：SAF 取消回退私有目录、EPUB `application/epub+zip` / TXT `text/plain` MIME、写入失败回退提示；D29 的 service 级 4 例与 T7-4 设备记录不重复 | `flutter test test/detail_export_page_test.dart` | 4/0/0（3 次运行稳定） | 回退路径的真实文件 IO 在 FakeAsync 区需 `runAsync` 交替推进（经验已记录） |
| D40 | `test/scheduler_wifi_test.dart` | 调度器级停泵/恢复：多任务非 WiFi 停泵、WiFi 全执行、单任务 WiFi、`resume()` 恢复；d30 service 级用例不重复 | `flutter test test/scheduler_wifi_test.dart` | 4/1/0 | **D40-1（P1）单任务 + 非 WiFi 时 `_pump` 纯微任务层无限自旋（守卫 `pending.length > 1` 短路），饿死全部定时器 → UI 卡死** |
| D41 | `test/d41_tts_callback_race_test.dart` | TTS 回调竞态：token 配对推进、seek/stop 后迟到完成丢弃（带/不带 token）、旧文本回调文本校对、speak 抛错收口（start 与中途）；d31 合同 14 例不重复 | `flutter test test/d41_tts_callback_race_test.dart` | 6/0/0 | 无缺陷；旧插件形态下「同文本重复段」误推进为合同层已知取舍 |
| D42 | `test/error_text_sanitization_test.dart` | 错误文本脱敏契约：wrap 的 query/userinfo/fragment 剥离、内嵌 URL、无 URL 原样、真实 dio 连接失败（127.0.0.1:1）、导出/WebDAV 入口 userMessage | `flutter test test/error_text_sanitization_test.dart` | 10/0/0 | Codex 的 D22-1 修复在三条入口全部生效；原 d22 回归随修复转绿（已验证） |
| D43 | `test/platform_channel_mime_test.dart`、`docs/SAF_WRITE_CONTRACT.md` | 通道层 MIME 契约（备份缺省 zip / EPUB / TXT）+ 错误传播；Kotlin 侧静态契约文档（参数/错误码/回退/边界） | `flutter test test/platform_channel_mime_test.dart` | 4/0/0 | **旧备份 zip 调用兼容确认**：Dart 与 Kotlin 两侧 mime 缺省一致（`application/zip`） |
| D44 | `tools/delivery_consistency_scan.py`、`tools/test_delivery_consistency_scan.py` | 仓库一致性扫描：工作单任务 ↔ 交付文档 ↔ 批次汇总（合并汇总认可）↔ 引用完整性（error）+ 模板段（warning）；真实仓库自检入 unittest | `python -m unittest discover -s tools`；scanner | 8 例全过 | 首扫 0 失效引用；4 个 error 为批次进行中状态（本批收尾即清零）；D33/D35 模板缺口为 warning 交 Codex |
| D45 | `docs/ACCEPTANCE_MATRIX.md`、`docs/PLATFORM_DEPENDENCY_AUDIT.md`、`README.md` | 矩阵补第四轮 D39–D46 证据（含 D40-1 待修）、D 组证据补 SAF 注入与三个新测试、F1 补 D42；audit 的 media_kit 行改为「已锁入 1.0.11」、TTS 结论改为「合同层落地待 D37」；README 命令块补 Python 工具链 | `ui_doc_drift_scan --json` → 0E/0W/1I | 文档任务 | 未把 D27/D29/D31/D33 写成完成；外部阻塞原文保留 |
| D46 | `docs/delivery/D46.md`、本汇总 | 全量检查与环境限制记录；随批把 D18 的过时现状固化测试更新为 D35 补偿契约（更严格：库 0 行、设置无残留） | 见下方「全批最终验证」 | 517/1/0 | 唯一失败 = D40-1 缺陷回归 |

## 全批最终验证

| 检查 | 结果 |
|---|---|
| `flutter analyze --no-pub` | **No issues found** |
| `flutter test --no-pub --reporter compact`（~36 s） | **517 passed / 1 failed**——唯一失败为 D40-1 缺陷回归（有意保留，修复归 Codex）；QuickJS dispose 抖动本轮两次全量未复现（风险保留给 D36） |
| Python `unittest discover`（~1.3 s） | **78 例全过**（67 既有 + 一致性扫描 8 + 结构修正） |
| 媒体自检 | 720 帧 / 24 fps / 30 s / dynamic=true |
| `ui_doc_drift_scan --json` | 0 error / 0 warning / 1 info |
| `delivery_consistency_scan --json` | 0 error / 3 warning（D33/D35 模板缺口，Codex 文档不改写） |
| `git diff --check` | 通过 |

**明确回答：全量测试确实因 1 条新缺陷回归未全绿**——按工作单「保留最小
复现」的要求有意为之；除 D40-1 外全绿。

## 缺陷清单（交 Codex）

| 优先级 | 编号 | 一句话 | 最小复现 |
|---|---|---|---|
| P1 | D40-1 | `wifiOnly` + 非 WiFi + 队列剩 1 条任务时 `_pump` 在纯微任务层无限自旋（守卫 `pending.length > 1` 短路），事件循环定时器全部饿死 → UI 卡死 | `scheduler_wifi_test.dart`「1 条 pending…泵必须停住而不是自旋」（熔断器保证测试可终止） |

修复建议：停泵守卫改 `pending.length >= 1`，或 `run()` 抛 WiFi 异常后直接
break（两种修法都让回归转绿；用例 1/5 守住多任务语义）。

## Codex 后续（按建议顺序）

1. 修 D40-1 → 全量 518/518；
2. 决策 D33/D35 交付文档是否补模板段（warning 级）；
3. 决定 `delivery_consistency_scan` 是否进 CI python-tools job（一行命令）；
4. 自留任务照旧：D27 真实契约、D36 QuickJS 隔离、D37 TTS 插件接线、
   D38 Windows 构建（工具链恢复后）。

## 边界与诚实声明

- 未自动提交/推送；保留了接收时的全部未提交修改（Codex D27–D38 修正与本批叠加）。
- 全部测试只用内存库 / tempdir / 127.0.0.1 / mock 通道；未访问真实站点、
  未使用真实凭据、未声称任何真机/桌面/真实站点验收；SAF Kotlin 侧为静态文档。
- 随批仅一处测试语义更新（D18 现状固化 → D35 补偿契约），方向更严格、有
  复核文档背书，非放宽。
