# BATCH D75-D83 汇总

> 日期：2026-10-05。执行：GLM（D75、D76、D77、D78、D83）；D79-D82/D84 为
> Codex 范围。依据 `docs/CORE_FEATURE_RECOVERY_PLAN_2026-10-05.md` 与
> `docs/GLM_BATCH_D75_D83.md`。

## 汇总表

| 任务 | 交付文件 | 新增覆盖 | 实际命令 | 通过/失败/跳过 | 发现 |
|---|---|---|---|---|---|
| D75 | `docs/SOURCE_CAPABILITY_MATRIX.md`、`test/source_boundary_guard_test.dart` | 6 例边界守卫：Bangumi 无 content、夹具命名/baseUrl 只本地、kDebugMode 门卫结构、夹具闭环能力完整、schema 全量校验 | `flutter test test/source_boundary_guard_test.dart` | 6/0/0 | 生产/夹具边界已有 `kDebugMode` 门卫（结构性固化） |
| D76 | `lib/core/source/source_catalog.dart`、`test/source_catalog_test.dart` | 索引协议：`{"sources":[...]}`/裸数组、必填校验、重复 id 拒绝（一次报全）、版本比较、未知能力/type 拒绝 | `flutter test test/source_catalog_test.dart` | 10/0/0 | hash 算法与大小限制留 D82 |
| D77 | `lib/features/sources/catalog_sheet.dart`、`test/source_catalog_page_test.dart` | 目录 UI 六态（加载/失败重试/空/安装中/失败原因/已安装）、分组与能力标签；安装走既有 importFromText | `flutter test test/source_catalog_page_test.dart` | 5/0/0 | 随包目录索引内容待 Codex（合法授权条目） |
| D78 | `test/manga_fixture_contract_test.dart` | 漫画夹具闭环：发现/搜索/详情/章节/正文全链路 + 离线缓存落盘（manifest+4 图+done）；loopback 随机端口 dart:io 服务器复刻夹具形状 | `flutter test test/manga_fixture_contract_test.dart` | 2/0/0 | `TestWidgetsFlutterBinding` 劫持 HttpClient——须在 `ensureInitialized()` 前捕获真实 client（经验已记录） |
| D83 | `lib/features/discover/discover_page.dart`（类型过滤）、`test/discover_empty_filter_test.dart`、`tools/test_text_encoding.py` | 发现页 4 例（无来源/仅资料源/多来源切换/类型过滤）+ 来源页 1 例（能力标签可见性=无播放能力可见）；编码回归 2 例（全量 UTF-8 + 合成坏字节必抓） | `flutter test test/discover_empty_filter_test.dart`；`python -m unittest tools.test_text_encoding` | 5/0/0 + 2/0/0 | 仅资料源在发现页的合同是「可搜索资料、无榜单」提示 |

## 全批最终验证

| 检查 | 结果 |
|---|---|
| `flutter analyze --no-pub` | **No issues found** |
| `flutter test --no-pub --reporter compact` | **575 例全部通过**（含本批新增 18 例 Dart） |
| Python `unittest discover` | **83 例全过**（79 既有 + 编码 2 + 一致性扫描相关） |
| 媒体自检 | 720 帧 / 24 fps / 30 s / dynamic=true |
| UI/文档漂移扫描 | 0 error / 0 warning / 1 info |
| 交付一致性扫描 | **0 error** / warnings 为 Codex 待补模板段（D79-D82 等） |
| 文本编码扫描 | Encoding check: 0 errors |
| `git diff --check` | 通过 |

## 未完成项（如实）

- 生产可浏览的番剧来源与合法播放线路：**未完成**（Codex D79/D80；本批的
  目录协议与 UI 是前置）；
- 生产默认漫画来源：**未完成**——目录 UI 就绪但没有合法可装的漫画规则条目；
- Android 模拟器 smoke 证据：**未完成**（本机 `adb devices` 为空，Codex D81；
  模拟器验收命令见 CORE 计划）；
- 随包目录索引内容与 loader 的 main() override：待 Codex 提供合法条目；
- 夹具只是 debug 闭环证据，**不构成真实番剧/漫画验收**（守卫测试钉住边界）。

## 交给 Codex 的复杂问题

1. D79/D80：合法番剧 provider 策略与 `content.playSources` 规则契约
   （目录条目 + 播放边界已就绪：`CatalogEntry.url/hash`、`SourceCapability`）；
2. D82：安装安全（hash 校验、大小限制、版本冲突回滚）落地后接目录「更新」
   （`CatalogVersion.isNewerThan` 已备）；
3. D81：模拟器 smoke（CORE 计划的验收命令可直接使用）；
4. D79-D82 交付文档补模板段（一致性扫描 warning）。

## 边界与诚实声明

- 未自动提交/推送；保留接收时的全部未提交修改；
- 未操作 SDK/Pub 缓存；未运行无 watchdog 的无限循环；
- 全部测试只用内存库 / tempdir / 127.0.0.1 / 注入替身；未访问真实站点；
  夹具证据未被宣传成真实内容。
