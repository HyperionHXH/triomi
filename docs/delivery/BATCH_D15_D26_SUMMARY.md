# D15–D26 全批交付汇总

> 日期：2026-10-02。执行：GLM（12 项连续执行包）。
> 交付明细见 `docs/delivery/D15.md`–`D26.md`；本文只保留接收与修复排序所需的证据。

## 汇总表

| 任务 | 交付文件 | 新增覆盖（已有覆盖引用） | 实际命令 | 通过/失败/跳过 | 发现 |
|---|---|---|---|---|---|
| D15 | `.github/workflows/build.yml`（python-tools job）、`tools/requirements-dev.txt`、`tools/ui_doc_drift_scan.py`、`tools/test_ui_doc_drift_scan.py` | 扫描范围显式化（`--device-script`）、编号语义区分、CI；既有 D14 用例全保留（17 例） | `python -m unittest discover -s tools`；scanner `--json` | 22/0/0（Python tools 合计 67/0/0） | 干净 checkout 不再扫描仓库外脚本；规格 2.4 需求清单不再误报 |
| D16 | `test/database_migration_test.dart`、`test/fixtures/migration/v1_schema.dart` | v1（M1 提交 de6bff6）真实 onUpgrade 升级 + 数据保留 + 幂等 + 空库；既有库结构断言（library_repository_test）不重复 | `flutter test test/database_migration_test.dart` | 4/0/0 | 无生产缺陷；升级路径此前零覆盖 |
| D17 | `docs/ACCEPTANCE_MATRIX.md`、`docs/PROJECT_SPEC.md`（2.4 勾选）、`README.md` | A1–G2 逐项证据表；22/24 勾选，C2/G1 记录缺口 | `python tools/ui_doc_drift_scan.py --json`（0 error / 0 warning / 1 info） | 文档任务 | **G1 真实缺口**（unread_count 无写入方）；**C2 缺发布管理页** |
| D18 | `test/backup_import_boundary_test.dart` | 拒绝路径、合并方向四分支、离线往返、WebDAV 分类；既有 m5/d10/t7 引用 | `flutter test test/backup_import_boundary_test.dart` | 10/2/0 | **B1(P1)** 重复导入倍增历史；**B2(P1)** 导入侧不过滤敏感键；B3(P2) 缺时间语义；ensureDirectory 吞异常(P3) |
| D19 | `test/download_boundary_test.dart` | run() 状态机、重试、离线一致性、竞态空操作；m5/video_download/hls 引用 | `flutter test test/download_boundary_test.dart` | 13/1/0 | **D19-1(P1)** 目录缺失时 run 标 done 但正文静默丢失；仅 WiFi 非 WiFi 分支不可注入（记录限制） |
| D20 | `test/fixtures/d20/tracking_gateway.dart`、`test/tracking_concurrency_test.dart` | 门控并发时序、markSynced 时机（401/429/超时）、解绑/清 token 竞态、进度映射；t1/d8 引用不重复 | `flutter test test/tracking_concurrency_test.dart` | 11/0/0 | 无缺陷；drift 秒级时间精度已在测试内处理 |
| D21 | `test/fixtures/d21/lns_fake_socket.dart`、`test/lns_lifecycle_boundary_test.dart` | 握手超时/重连/reset/旧连接隔离、迟到与重复帧、二进制帧、type-7；t4/d9 引用不重复；**非幂等调用重发契约已明确记录** | `flutter test test/lns_lifecycle_boundary_test.dart` | 9/1/0 | **D21-1(P2)** `_failConnection` 从不 close socket（连接泄漏） |
| D22 | `test/js_runtime_lifecycle_test.dart`、`test/js_bridge_boundary_test.dart` | **真实 quickjs**：乱序并发、reject 恢复、dispose 竞态、请求头合并、选择器容忍；t2（假引擎/真引擎基础）引用 | 两个 focused 文件 | 13/1/0 | **D22-1(P2)** 连接错误文本携带 URL query 凭据；timeout 只覆盖异步 promise（同步死循环不可中断，静态证据已交） |
| D23 | `test/reader_resume_boundary_test.dart` | 解析边界（实体/https/坏尺寸插图/混排）、分页（内容不丢/位置合法/跨样式稳定）、续读隔离；reader_pagination 等引用 | `flutter test test/reader_resume_boundary_test.dart` | 13/1/0 | **D23-1(P3)** 分页边界切半 emoji 代理对；末章回调缺 controller 接缝（记录） |
| D24 | `test/export_artifact_boundary_test.dart` | EPUB 严格结构（mimetype STORED/四向对应/封面/去重/转义）、TXT UTF-8、服务层文件行为；m4b 引用不重复 | `flutter test test/export_artifact_boundary_test.dart` | 10/1/0 | **D24-1(P2)** OPF 章节 href 带 OEBPS/ 前缀，不符合 EPUB 3 规范；小说导出无 SAF 注入点（记录） |
| D25 | `tools/fixture_contract_helpers.py`、`tools/test_fixture_http_contract.py`、`docs/FIXTURE_CONTRACTS.md` | 全夹具端点契约（漫画/小说/番剧/弹幕/弹弹play/追踪/LK/WebDAV）在 127.0.0.1 随机端口实测；Range/416/后缀区间 | `python -m unittest discover -s tools` | 15/0/0 | 夹具粗糙点：非整数 Range 掐断连接；收藏 upsert 204（官方 202）；LNS 无 HTTP 夹具（已声明，不伪造覆盖） |
| D26 | `docs/PLATFORM_DEPENDENCY_AUDIT.md`、`docs/TTS_RESEARCH.md` | 平台能力矩阵（8 能力×2 平台，文件证据）、依赖盘点与升级顺序、TTS 候选比较与接口问题清单 | 纯文档（引用文件已核实在） | — | **Windows 缺 `media_kit_libs_windows_video`**（桌面播放不可能出画）；Windows 通道未实现的静默降级清单；TTS 候选 flutter_tts 4.2.5，6 个接口问题待 Codex 拍板 |

## 全批最终验证（本机，Windows，Python 3.14.3 / Flutter 3.47.5，代理已清）

> **Codex 2026-10-02 接收复核：** 原始 437/7 结果是修复前快照。D18-B1/B2、D19-1、D21-1、D22-1、D24-1 已修复；D23 与 D24 的部分失败断言分别是测试 helper 和文件名期待错误，已校正。当前全量 Flutter 为 **444/444 通过**，详见 `docs/REVIEW_2026-10-02_D15_D26.md`。

| 检查 | 命令 | 结果 |
|---|---|---|
| 静态分析 | `flutter analyze --no-pub`（ANDROID_HOME 已配） | **No issues found**（dart fix --apply 32 项 + 手工 2 项后） |
| 全量 Flutter 测试 | `flutter test --no-pub --reporter compact` | **437 passed / 7 failed**——7 条全部是下表 P0–P2 缺陷回归（期望行为断言），无意外回归 |
| Python 工具 | `python -m unittest discover -s tools -p "test_*.py" -v` | **67 例全过**（D11/D12/D14 既有 52 + D25 新 15） |
| 媒体自检 | `python tools/check_fixture_media.py` | 720 帧 / 24 fps / 30.0 s / 640×360 / 抽样帧差 29.604 / dynamic=true |
| 漂移扫描 | `python tools/ui_doc_drift_scan.py --json` | errors 0 / warnings 0 / infos 1（根目录历史规格提示）；files=155 |
| 提交卫生 | `git diff --check` | 通过（无空白错误） |

**明确回答：全量 Flutter 测试确实因 7 条新缺陷回归未全绿**——这是按工作单
「保留最小复现、失败不要改成 skip」的预期结果，不是既有功能回归。
除这 7 条外全绿。

## 缺陷清单（P0/P1/P2/P3，交 Codex 修复排序）

| 优先级 | 编号 | 一句话 | 最小复现测试 |
|---|---|---|---|
| P1 | D18-B1 | 重复导入同一备份倍增历史记录（_apply 不先删后插） | backup_import_boundary_test「重复导入…历史不倍增」 |
| P1 | D18-B2 | 备份导入侧不过滤敏感键（securityKey/token 可被外来包注入） | backup_import_boundary_test「导入侧敏感键过滤」 |
| P1 | D19-1 | 章节目录缺失时 run() 标 done 但正文静默丢失 | download_boundary_test「目录缺失时 run 标 done…」 |
| P2 | D21-1 | `_failConnection` 从不 close socket（重置后连接泄漏） | lns_lifecycle_boundary_test「旧 socket 未被 close」 |
| P2 | D22-1 | 宿主连接错误把 URL query 凭据透传进来源失败列表（SourceException.wrap 含 url） | js_runtime_lifecycle_test「连接失败的错误文本不携带…」 |
| P2 | D24-1 | OPF 章节 href 带 OEBPS/ 前缀，不符合 EPUB 3（严格阅读器会拒绝） | export_artifact_boundary_test「container 指向 OPF…」 |
| P3 | D23-1 | 分页页面边界把 emoji 代理对切成半截（显示乱码，内容不丢） | reader_resume_boundary_test「带 emoji 的长段落…」 |
| P3 | D18-B3 | 缺 updatedAt 的备份行按「当前时间」合并（可能覆盖较新本机进度） | 现状断言（通过），待决策 |
| P3 | D25 | 夹具非整数 Range 掐断连接；收藏 upsert 204 vs 官方 202 | 现状固化（通过），仅开发工具影响 |

## Codex 后续（按建议顺序）

1. 修 D18-B2（导入侧复用 `_isSensitive`，一行改动）与 D18-B1（历史导入
   先删后插）→ 2 条回归转绿；
2. 修 D19-1（run 拒绝无目录任务或 saveChapterContent upsert）、D22-1
   （SourceException.wrap 拼 url 前剥 query）、D24-1（OPF href 用 basename）、
   D21-1（_failConnection 补 socket.close）、D23-1（safeEnd 代理对对齐）；
3. 决策项：D18-B3 缺时间语义；C2 发布管理页做/裁；G1 书架更新基线设计；
   小说导出 SAF 注入点；TTS_RESEARCH 第 4 节 6 问；
4. 升级顺序：`media_kit_libs_windows_video`（解锁桌面播放）→ wakelock_plus
   → flutter_secure_storage 9→10（真机窗口）→ KGP 迁移跟随上游。

## 边界与诚实声明

- 未自动提交/推送；保留了接收时的全部未提交修改（Codex 第三轮修正与
  本轮交付叠加在工作区）。
- 所有测试只使用 FakeHttpClient / 内存库 / tempdir / 127.0.0.1 随机端口；
  未访问真实站点、未使用真实凭据、未修改 `lib/**`、`android/**`、
  `pubspec.*` 与生成代码（D15 的 workflow 与 D17 的文档按工作单允许范围修改）。
- 设备验收边界不变：物理真机、真实 Bangumi 搜索、弹弹play 审核凭据仍是
  外部条件，本轮未写为通过。
