# GLM / DPSK 可直接接手的工作单

> 当前执行入口为 [GLM_BATCH_D47_D58.md](GLM_BATCH_D47_D58.md)，共 12 项。D39-D46 已交付并经 Codex 修复审核，下方旧批次只作历史，不重复派发。审核见 [REVIEW_2026-10-02_D39_D46.md](REVIEW_2026-10-02_D39_D46.md)。

## 第三轮：当前可派发任务 D15–D26（2026-10-01 扩展）

用户手动分配给 GLM。上一轮 D11–D14/P2 已完成，正文第二轮保留作历史记录。
先读 REVIEW_2026-10-01_ROUND3.md；当前修复以工作区为准，禁止覆盖已有未提交改动。
本轮不需要账号或设备，不新增 UI、不升级生产依赖、不变更数据库结构。
任务完成后仅在各自交付文档记录结果，公共计划状态由 Codex 审核后维护。

**本轮扩大为 12 项任务，一次交给 GLM 连续执行。** D15–D17 详见本页，D18–D26
见 [GLM_BATCH_D18_D26.md](GLM_BATCH_D18_D26.md)。先核对已有覆盖再补缺口，
不凑测试数量；生产缺陷保留复现交 Codex，不影响继续其他独立任务。

可以直接给 GLM 的提示：

> 执行 triomi/docs/GLM_DPSK_WORK_ORDERS.md 第三轮 D15–D17，以及
> triomi/docs/GLM_BATCH_D18_D26.md 的 D18–D26，共12项，按顺序持续完成。
> 开始先读当前计划与 REVIEW_2026-10-01_ROUND3.md，保留已有未提交修改。
> 每项读取生产代码与既有测试，补真实覆盖缺口并写 docs/delivery/Dxx.md。
> 发现不允许修改的生产缺陷，留下最小失败回归、准确记录，继续后续独立任务。
> 不要逐项询问是否继续，也不要提前停在计划或口头总结；全部处理后执行最终
> 检查并写 docs/delivery/BATCH_D15_D26_SUMMARY.md。按文档限制修改，不自动提交。

| 顺序 | 工作单 | 目标 | 允许修改 | 交付记录 |
|---|---|---|---|---|
| 1 | D15 | Python 验收进入 CI，明确扫描范围与编号语义 | .github/workflows/build.yml、tools/requirements-dev.txt、tools/ui_doc_drift_scan.py、tools/test_ui_doc_drift_scan.py | docs/delivery/D15.md |
| 2 | D16 | 真正执行 v1→v2 升级并证明用户数据保留 | test/database_migration_test.dart、test/fixtures/migration/** | docs/delivery/D16.md |
| 3 | D17 | 规格 2.4 全量证据对照、文档漂移收口 | docs/ACCEPTANCE_MATRIX.md、docs/PROJECT_SPEC.md、README.md | docs/delivery/D17.md |
| 4 | D18 | 备份/WebDAV 导入完整性 | 新回归测试与夹具 | docs/delivery/D18.md |
| 5 | D19 | 下载失败/重试/离线状态 | 新回归测试与夹具 | docs/delivery/D19.md |
| 6 | D20 | 追踪并发/同步标记 | 新回归测试与夹具 | docs/delivery/D20.md |
| 7 | D21 | LNS 生命周期/协议恢复 | 新回归测试与夹具 | docs/delivery/D21.md |
| 8 | D22 | JS 桥/运行时异常边界 | 新回归测试与夹具 | docs/delivery/D22.md |
| 9 | D23 | 阅读解析/分页/续读 | 新回归测试与夹具 | docs/delivery/D23.md |
| 10 | D24 | TXT/EPUB 产物验证 | 新回归测试与夹具 | docs/delivery/D24.md |
| 11 | D25 | 夹具 HTTP 接口契约 | 新 tools 测试/助手与契约文档 | docs/delivery/D25.md |
| 12 | D26 | 平台/依赖盘点与 TTS 资料 | 两份调研文档 | docs/delivery/D26.md |

D18–D26 详细允许路径与验收方式以扩展文档为准，不得据本表扩大生产代码修改范围。

## 第四轮：D27-D34

D15-D26 已由 Codex 接收并修复。下一批范围、统一限制和可复制提示见 [GLM_BATCH_D27_D34.md](GLM_BATCH_D27_D34.md)。本轮不涉及真实设备、账号、审核凭据或站点写入。

### 第四轮交付状态（2026-10-02，GLM 交付完毕，待 Codex 审核接收）

| 任务 | 内容 | 交付记录 | 状态 |
|---|---|---|---|
| D27 | C2 发布管理页面（列表/分页/错误空态 + `LkWorksRepository` adapter seam + 路由） | docs/delivery/D27.md | ✅ 已交付（真实端点契约留给 Codex） |
| D28 | Windows 播放依赖：`media_kit_libs_windows_video 1.0.11` 锁入 | docs/delivery/D28.md | ✅ 已交付（桌面构建验证 = D38） |
| D29 | SAF 导出注入（`NovelExportService` 目录 URI + writeToTree 注入，私有目录回退） | docs/delivery/D29.md | ✅ 已交付（导出页接线留给 Codex） |
| D30 | WiFi 检测 seam：注入解析器 + WiFi/非WiFi/异常/开关 10 例 | docs/delivery/D30.md | ✅ 已交付（含本机 Dart 管道补丁事件记录） |
| D31 | TTS 合同与纯 Dart seam：`TtsPlan`/`TtsEngine`/`TtsController` 14 例 | docs/delivery/D31.md | ✅ 已交付（插件接线 = D37） |
| D32 | G1 更新提示边界：删除/重排/`markAllRead` 5 例 | docs/delivery/D32.md | ✅ 已交付 |
| D33 | 备份可靠性审计：histories 缺时间戳/设置部分提交窗口 5 例 + 事务缺口记录 | docs/delivery/D33.md | ✅ 已交付（跨存储原子性 = D35） |
| D34 | 依赖与文档收口：平台矩阵/验收矩阵/工作单状态/扫描器范围 | docs/delivery/D34.md | ✅ 已交付 |

批次汇总：`docs/delivery/BATCH_D27_D34_SUMMARY.md`。Codex 审 diff、重跑全量
检查后再决定进入 D35-D38。

### D15：CI 与扫描器执行边界（P1）

现状：build.yml 只有 Flutter 分析/测试与两端构建，Python 47 例、媒体自检、漂移
扫描均不在 CI。扫描器现在自动读父目录 _e2e_* /含 video 的脚本，干净 checkout
没有这些文件；summary.files_scanned 也不包含这些外部文件，容易误读覆盖范围。

实现要求：

1. 增加独立 Python CI job：setup-python 3.12 或经验证兼容版本，安装明确版本范围
   的 numpy/opencv-python-headless（不装 GUI OpenCV），跑 unittest discover、
   check_fixture_media、ui_doc_drift_scan --json。Flutter job 保持原行为；禁止伪造
   GitHub Actions 已通过的结论，本机验证与远端 CI 结果分开记录。
2. 扫描器默认只读仓库；支持显式 --device-script PATH（可重复），本机命令传入
   活跃 _video_pixel_verify.py，不默认扫描历史/废弃脚本。输出实际扫描文件数与
   外部文件数，输出不得暴露绝对路径。路径不存在时明确 warning，不静默忽略。
3. 区分「旧工作单 D1–D5」与「规格 2.4 下载要求 D1–D5」；按文档路径/章节上下文
   识别，不因编号相同认定已完成。补 tempdir 回归：干净 checkout、显式外部脚本、
   未提供的父目录脚本不影响扫描、文件数、编号歧义、JSON 与退出码。
4. 保留已有 G1/D14 接收修正。不得改播放器、APK、sample.mp4、根目录历史规格。

验收（仓库根目录执行）：

```text
python -m pip install -r tools/requirements-dev.txt
python -m unittest discover -s tools -p "test_*.py" -v
python tools/check_fixture_media.py
python tools/ui_doc_drift_scan.py --json
```

交付说明必须记录 Python/OpenCV 版本、测试数量、媒体摘要、扫描范围与摘要、
本机是否实际安装依赖；不为单纯测试任务引入生产 Flutter 依赖。

### D16：数据库升级数据保留（P1）

现状：AppDatabase.schemaVersion=2，onUpgrade 为 media_items 与 chapters 新增 url。
既有表结构测试只证明新建库正确，不能证明已有 v1 数据可升级。

实现要求：

1. 根据 M0/M1 历史提交确认 v1 实际 DDL；提供版本来源，不把当前 v2 建库后删列
   冒充历史结构。用现有 drift/sqlite3 在临时目录创建 v1 SQLite，设置 user_version=1。
2. 写入两来源相同 remoteId 的作品/章节、书架、历史/阅读位置、离线正文和追踪绑定。
   用 AppDatabase.forTesting 打开触发真实 onUpgrade，验证 url 默认值符合历史迁移
   契约（旧数据无法凭空恢复 URL）、其他字段/复合键/关联数据保留、版本为2。
3. 关闭并再次打开，验证幂等、记录数量不变、不再次执行 ALTER；覆盖空 v1 升级。
4. 优先手写有历史来源的小型 v1 DDL 夹具；不要求新增 schema 工具链或生成文件。
   若发现生产迁移错误，交付可重现失败测试与建议，由 Codex 修改 app_database.dart；
   不自行 bump schemaVersion，不改表、生成代码、仓储或备份逻辑。

验收：flutter analyze；flutter test test/database_migration_test.dart --reporter compact；
flutter test --reporter compact。临时数据库 teardown 清理，不改真实 triomi 数据。

### D17：规格逐项验收证据（P1）

现状：规格 2.4 多数 checkbox 仍未勾选；README 仍称 JS 待设备验证，而 handoff
已有完成记录。README 也把真实弹弹play写入笼统写成通过，与 Invalid AppId 阻塞冲突。

实现要求：

1. 建立 A1–G2 每项证据表：要求、生产代码入口、相关用例、既有设备/账号记录链接、
   判定（完成/部分完成/待验证/明确关闭）、具体缺口。记录可核查证据，不猜测通过。
2. 不依据 handoff 的一句“全完成”机械打勾；阅读相关实现与测试，对复合要求拆开
   核对。同书版本、分页到底、专用字体、后台排程、付费权限、安全存储重点复核。
3. 证据充分才更新规格勾选；已有代码缺设备证据时明确分开两层状态。真实账号/
   写入限制引用既有记录，不索要账号，不请求真实站点。修正 README 的过期描述与
   Android/桌面播放路径、环境能力、追踪/弹幕真实写入结论。保留历史复查文档。
4. 对缺口仅记录复现/原因/建议，不改生产代码；交 Codex 决定是否插入修复任务。
   不把只读私信等已明确范围擅自扩成需求，不把 Anime4K/额外系统版本重新列待办。

验收：证据表覆盖规格全部编号；链接存在；python tools/ui_doc_drift_scan.py --json；
git diff --check。文档任务不需要新增镜像实现的测试。

### 第三轮交付模板

```text
任务：D15–D26 中当前工作单编号
完成范围：文件列表与实际行为
验证：实际命令、环境版本、退出码、测试数量/摘要
未完成/发现：准确描述，失败测试不得改成跳过
后续：Codex 要决定/修复的事项
```

交付后 Codex 审 diff 与证据，运行相关检查再更新状态；禁止把任务交付自评写成
Codex 审核通过。全批 D15–D26 接收与关键缺陷修复后，再拆首个 M6/TTS 实现工作单。

---

## 第二轮工作单（历史交付，勿重复开发）

更新时间：2026-10-01（第二轮：G1–G3 / P1 / P2 已交付，交付记录见
`CHECKPOINT_2026-10-01.md` 文末「外部模型交付记录」）

这份文档把纯代码、纯测试和文档扫描工作交给 GLM / DPSK。每个模型只改工作单允许的文件，
完成后按交付模板回复并追加检查点。单测结果不得写成真机通过；不得索要、写入或提交真实
token、密码、AppId、AppSecret。

## 分工

| 工作单 | 建议模型 | 内容 | 本机后续 | 状态 |
|---|---|---|---|---|
| G1 / D11 | GLM | 播放验证日志与像素摘要解析 | 接入设备脚本抽样复验 | ✅ 已交付 |
| G2 / D12 | GLM | sample.mp4 元信息和动态帧自检 | 重跑媒体摘要 | ✅ 已交付 |
| G3 / D13 | GLM | 原生播放器状态机契约测试 | 对照 Kotlin 和 logcat | ✅ 已交付（含 3 条 Kotlin 偏差报告） |
| P1 / D14 | DPSK | UI 语义定位与文档漂移扫描 | 运行最终扫描 | ✅ 已交付（首扫 0 error） |
| P2 | DPSK | 测试质量和凭据边界审计 | 跑全量检查 | ✅ 已交付（四项全过，无需改动） |

G1、G2、P1、P2 可并行；G3 只需读 Kotlin，不需要设备。

## G1 / D11：播放器验证数据解析复核

本机已有 tools/video_verify_metrics.py 和 tools/test_video_verify_metrics.py。解析目标是
NativeVideoPlatformView.kt 的 TriomiNativeVideo 日志与截图采集器的 non_black、delta、
changed 字段。动态播放证据必须同时满足 prepared、无原生 error、时间轴推进、中央画面
非黑和相邻帧变化。

任务：审查只解析 TriomiNativeVideo 的正则；确认 query/token 不会进入输出；补空日志、
多个 prepared、位置回退、只有首帧和 changed 全为 None 的测试；不引入新依赖。

允许修改：tools/video_verify_metrics.py、tools/test_video_verify_metrics.py，以及检查点文档 D11 段落。

禁止修改：android/**、lib/features/player/player_page.dart、仓库外设备脚本和任何凭据。

验收：python -m unittest discover -s tools -p "test_*.py" -v

交付格式：任务名、文件列表、测试命令与数量、设备限制、交给本机的复验步骤。

## G2 / D12：视频夹具元信息自检复核

tools/fixture_media/sample.mp4 当前本机摘要为 720 帧、24 fps、30.0 秒、640x360，抽样
最大平均帧差 29.329。脚本是 tools/check_fixture_media.py，单测是 tools/test_check_fixture_media.py。

任务：审查 OpenCV 读取失败、零 FPS、截断文件和静态视频；保持 JSON 字段稳定且不依赖绝对
路径；增加坏文件或过短视频测试（使用临时文件或可注入函数，不覆盖真实夹具）。

允许修改上述两个 tools 文件和检查点 D12；禁止修改 sample.mp4、Android/Flutter 播放器、
真实站点配置和凭据。

验收：python tools/check_fixture_media.py；python -m unittest discover -s tools -p "test_*.py" -v

## G3 / D13：原生播放器状态机契约复核

本机准备了 lib/features/player/data/native_video_state_machine.dart 和
test/native_video_state_machine_test.dart。Kotlin 正式实现是 NativeVideoPlatformView.kt：
TextureView + MediaPlayer.setDataSource(String)。Surface 销毁保存 position 和 playing intent，
重新可用后重新 prepare；setUrl 必须清除旧 position/duration。

任务：对照 Kotlin 审查 prepared 自动播放、pause/play、seek clamp、completion、error、Surface
detach/attach 和换 URL；补“暂停后重建不自动播放”“duration=0 seek 不崩”测试。发现 Kotlin 偏差时
只报告，不改 Kotlin。

允许修改：状态机 Dart 文件、对应测试、检查点 D13。禁止修改 Android、播放器 UI/桥接、Gradle、
设备脚本和凭据。

验收：设置 ANDROID_HOME/ANDROID_SDK_ROOT 后运行 flutter analyze 和
flutter test test/native_video_state_machine_test.dart --reporter compact。

## P1 / D14：语义 UI 定位与文档漂移扫描

旧仓库外脚本曾按“第 2 个标签”固定索引，当前已改为按语义文本和横向滚动寻找来源。历史
文档有 docs/NEXT_PLAN.md；当前真相是 docs/AFTER_M5_PLAN.md 与 docs/handoff/README.md；
根目录 D:\noval_and_manga\PROJECT_SPEC.md 是历史副本，不能静默覆盖。

任务：新增纯 Python tools/ui_doc_drift_scan.py 和单测，扫描 Dart/测试/设备脚本中的固定
tab/chip 导航索引（只匹配导航/点击上下文，不能误报普通循环）；检查当前文档是否残留旧的
待开发 T1-T7/D1-D5 断言；检查两份 PROJECT_SPEC 并输出历史副本提示；--json 输出机器可读
结果，只有真正脆弱定位命中才非零。文档只补当前状态，不删除历史记录。

允许修改：扫描器、单测、检查点，必要时 AFTER_M5_PLAN 的命令说明。禁止修改根目录历史副本、
Android/Flutter UI、模拟器、APK、账号和凭据。

验收：python tools/ui_doc_drift_scan.py --json 与 tools 单测。

## P2：纯测试质量审计

审查 G1/G2/G3/P1 是否依赖绝对路径、在线站点或真实凭据；查找把时间轴推进当画面变化的
断言；只改相关测试和小型纯函数，不做大重构。禁止修改 Android 播放器、APK、设备脚本和凭据。

## 本机专属工作

- API 35 模拟器构建、安装、动态帧采样，必要时调整 Kotlin/Flutter 桥接。
- 真实 Android 手机上的首播、暂停/继续、seek、倍速、换线路、旋转、后台恢复和退出重进。
- 真实 Bangumi token、弹弹play 审核凭据和用户站点写入。
- 每项设备/凭据联调追加机型、API、请求链、logcat 和画面证据；不记录 token、密码或 AppSecret。

## 外部交付后的本机接收顺序

1. 审 diff，确认没有越界修改、APK 或凭据。
2. 跑 flutter analyze、全量 flutter test --reporter compact 和 Python tools 单测。
3. 重跑 D12 摘要与 D14 扫描并追加检查点。
4. 构建 debug APK 安装到 emulator-5554，用动态帧断言复跑，最后安排物理真机。
