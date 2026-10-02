# D47–D58 全批交付汇总

> 日期：2026-10-02。执行：GLM。依据 `docs/GLM_BATCH_D47_D58.md`；
> 前置阅读 `docs/REVIEW_2026-10-02_D39_D46.md`、`docs/adr/001-js-execution-isolation.md`。
> 状态：**GLM 交付完毕，待 Codex 审核接收。** 未提交、未推送；工作区全部
> 未提交修改（Codex D39-D46 修正与本批叠加）原样保留。

## 汇总表

| 任务 | 交付文件 | 覆盖 / 实际命令 | 结果 | 发现 |
|---|---|---|---|---|
| D47 | `test/novel_reader_tts_lifecycle_test.dart` | 4 例真实页面 + fake engine：换章/退出/后台/繁简切换停止朗读、迟到完成事件不刷新已销毁页面 | 4/0/0 | 两例初稿失败均为测试交互缺陷（弹层 chip 在视口外、FakeAsync 零延时 Timer 残留），生产代码四条停止路径本就完备，未改 |
| D48 | `lib/features/novel/tts/tts_controller.dart`（TtsVoiceInfo + 引擎选项默认实现）、`flutter_tts_engine.dart`（语速/音色应用与 getVoices 防御解析）、`novel_reader_settings.dart`（ttsRate/ttsVoice 持久化）、`novel_reader_page.dart`（朗读设置小面板 + 会话前应用选项）、`test/d48_tts_settings_test.dart` | 10 例：插件 mock 语速/音色/降级、面板三档语速、无音色提示、重启恢复、已存音色不可用、开关变更即停当前朗读 | 10/0/0 | 未动状态机代次逻辑；Dropdown 对已保存但系统不再返回的音色显示「（不可用）」 |
| D49 | `platform_channel.dart`（SafTreeWriter typedef）、`backup_service.dart`、`novel_export_service.dart`、`detail_page.dart`、`backup_page.dart`、三个测试文件 | 73 例相关测试全过：SAF writer 返回**系统真实 document URI**，删除合成 `treeUri/fileName` 路径；系统改名场景钉住；null/空 URI 回退；zip MIME 缺省保持 | 73/0/0 | 合成路径在系统改名时是错的——真实 URI 才是唯一事实 |
| D50 | `novel_export_service.dart`（savedToAuthorizedDirectory）、`backup_service.dart`（BackupSummary.savedToSaf）、两个页面三分支提示、`detail_export_page_test.dart` 断言 | 38 例相关测试全过：授权目录成功/取消选择/写入失败回退三种提示互不相同，回退仍是「导出完成」 | 38/0/0 | 顺带清理了 backup_page 一段重复的状态赋值块 |
| D51 | `tools/dev_fixture_server.py`（Range 解析重写）、`tools/test_fixture_http_contract.py`、`docs/FIXTURE_CONTRACTS.md` | 15 例契约测试（新增 7 种非法 Range 形态统一 416） | 15/0/0 | 修复中曾把 helper 插进 do_GET 体导致视频处理器失效，已修正为类级方法 |
| D52 | `test/d52_backup_compensation_test.dart`（新增 5 例） | 第 2 类行（libraryEntries）与第 3/4 类行（histories/chapterRows）类型错误 → 事务内此前写入**整体回滚**；「旧值为 null」与「键不存在」在补偿中的区别；零设置导入；restoreSubset 必抛（补偿自身失败）可终止复现 → **D60** | 5/0/0 | 断言全部落在真实 MemBox/drift 内存库状态；未重复 D33/D35 已有两例 |
| D53 | `test/scheduler_wifi_test.dart` | 6 例：单任务缺陷回归改用「resolver 调用数封顶」确定性停泵信号（**消除固定 5 秒等待**，现约 0.5 秒）；新增「wifiOnly 关闭 + 明确 resume 恢复队列（非 WiFi 也执行）」；熔断器保留、无自旋断言保留 | 6/0/0 | 未用放宽断言换速度 |
| D54 | `test/d54_js_lifecycle_test.dart`（新增 4 例，真实 quickjs 宿主） | 同运行器并发乱序不串号、一个超时另一个成功且互不影响、JSON 不可序列化参数报错且运行器无损、重复 load 状态重置 | 4/0/0 | 无同步无限循环（纯 Promise 微任务链）；dispose 多 pending 复用既有用例 |
| D55 | `tools/delivery_consistency_scan.py`（`_mentions_task` 边界断言）、`tools/test_delivery_consistency_scan.py`（+2 例） | 36 例扫描器测试全过；真实仓库扫描 0E/0W | 36/0/0 | 修复 `D1`/`D10` 子串误匹配——汇总内容只提 D10 不再算覆盖 D1 |
| D56 | `SAF_WRITE_CONTRACT.md`、`TTS_RESEARCH.md`（第 6 节）、`PLATFORM_DEPENDENCY_AUDIT.md`（三层证据）、`ACCEPTANCE_MATRIX.md`（第五轮索引）、`README.md` | 文档证据分层：代码层 / 构建层 / 设备层；**JS 异步取消 ≠ 同步隔离完成；运行期补偿 ≠ 崩溃原子性完成** | 文档 | — |
| D57 | `docs/RELEASE_READINESS.md`（新增） | 发布前检查表：Android TTS / 权限与集成 / Windows / 回归门槛四组，每项「步骤→预期→证据位置」，附「明确不在发布门槛内」清单 | 文档 | — |
| D58 | 本文件 + `docs/delivery/D58.md` | 全量检查实测（见下表） | 全绿 | — |

## 全批最终验证（本机实测）

| 检查 | 退出码 | 结果 | 耗时 |
|---|---|---|---|
| `flutter analyze --no-pub` | 0 | No issues found | 15.9 s |
| `flutter test --no-pub --reporter compact` | 0 | **553 passed / 0 failed** | 45.4 s |
| `python -m unittest discover -s tools -p "test_*.py"` | 0 | **81 passed** | 8.2 s |
| `python tools/ui_doc_drift_scan.py --json` | 0 | 0E / 0W / 1I（根目录历史副本） | 0.5 s |
| `python tools/delivery_consistency_scan.py --json` | 0 | 0E / 0W | 0.3 s |
| `python tools/check_fixture_media.py` | 0 | 720 帧 / 24 fps / 30 s / dynamic | 0.6 s |
| `git diff --check` | 0 | 通过 | — |

**明确回答：本批交付后全量测试确实全绿**（553 Flutter + 81 Python），
无保留失败用例、无 skip 伪装。

## 证据分层声明（诚实边界）

- 本批全部测试使用内存库 / tempdir / 127.0.0.1 / mock 通道；D54 的 JS 用例
  跑在宿主真实 quickjs 上（可用性证据链：`js_engine_probe_test` +
  `tools/setup_quickjs_dll.py`）。
- **未冒充完成**：TTS 真实发声/来电焦点/后台、Windows 构建与语音、SAF 真机
  复验——全部保留在 `docs/RELEASE_READINESS.md` 设备验收表中；
  JS 同步强隔离（D59）与备份崩溃恢复（D60）明确标为未完成。
- 环境事件：本机解释器缺 numpy/cv2，已按 `tools/requirements-dev.txt`
  装入托管 venv（未动 SDK/Pub 缓存）后 Python 全量通过。

## 交给 Codex 的后续

1. 审查本批 diff、重跑全量检查（本机实测数字见上表）；
2. D59：JS 同步死循环的可终止进程隔离（ADR 001）；
3. D60：跨 Hive/SQLite 的持久恢复日志、崩溃恢复、并发导入串行化
   （D52 的「补偿自身失败」复现是入口）；
4. D61：TTS 长段落超输入长度切分、同块锚映射、精准滚动定位；
5. D27 真实发布管理契约接入、D38 Windows 工具链恢复后的构建/桌面播放；
   外部设备与凭据项按 `docs/RELEASE_READINESS.md` 执行。
