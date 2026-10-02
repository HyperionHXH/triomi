# 2026-10-01 检查点：Android 视频动态帧复验

## 已完成

- 启动 `triomi_api35_clean`（API 35、x86_64、host GPU），设备序列号 `emulator-5554`。
- 以 `ANDROID_HOME=C:\Android\Sdk` 重新执行 `flutter build apk --debug`，构建成功并安装。
- 保持夹具服务 `tools/dev_fixture_server.py` 监听 `0.0.0.0:8123`；请求日志确认播放器取到
  `/play/51-1`、完整 `/video/sample.mp4` 和 `/danmaku/51-1.json`。
- 新增临时验证脚本 `D:\noval_and_manga\_video_pixel_verify.py`：按语义控件导航，等待
  `TriomiNativeVideo` 的 `prepared`，采集 12 帧并计算非黑比例、平均帧差、变化像素比例。
- 在 `NativeVideoPlatformView.kt` 增加 `TriomiNativeVideo` 调试日志，记录 Surface、prepared、
  position、duration、completed 和 error，便于区分画面合成、解码和采样时序问题。
- 日志只在可调试 APK 生效，URL 只保留 scheme/host/path，自动去掉 query/token；release 包不写
  播放地址。脱敏改动后再次 `flutter build apk --debug` 成功。

## 证据

- `sample.mp4`：720 帧、24 fps、约 30 秒；不是 4 秒静态片段。
- `MediaPlayer`：`prepared duration=30023`；位置 `1116 → 7363 ms` 连续增长，`playing=true`，
  未出现播放器 error。
- 12 帧截图：中央视频区域非黑 **85.45%–86.22%**；相邻帧平均绝对差 **3.36–5.92**；
  变化像素比例 **8.54%–11.53%**。
- 结论：API 35 模拟器上的正式 Flutter 播放器已经显示并持续播放真实视频帧。旧的 `0:04 / 0:04`
  截图是在媒体播放结束后采集，不能作为时长证据。
- 脱敏日志改动后的最终 APK 已再次安装并复跑：中央视频区域非黑 **85.45%–86.22%**；
  相邻帧平均绝对差 **3.12–5.79**，变化像素比例 **8.56%–11.53%**；日志中的 URL
  已只保留 `scheme://host/path`，没有 query/token。

## 失败与修正

- 旧 `_video_check.py` 依赖“第 2 个标签”，当前 UI 文案改变后无法导航；新脚本改用语义标签和
  横向滚动查找来源。
- 新脚本第一次运行时夹具来源尚未加载，页面显示“这个来源没能取到内容”；确认 8123 服务、
  请求日志和来源播种后重跑成功。
- 构建第一次因 shell 未设置 `ANDROID_HOME` 失败；使用项目 `local.properties` 对应的 SDK 环境
  重跑成功。
- 本轮没有把时间轴前进当作画面变化，也没有把夹具验证写成真实站点验证。

## 自动化检查

- `flutter analyze`：No issues found。
- `flutter test --reporter compact`：All tests passed，343 个非隐藏用例，0 失败。
- 测试输出中的 Drift 多数据库 warning 是既有测试夹具警告，本轮未改变行为。

## 下一步边界

## 2026-10-02 D15-D26 接收复核

- D18-B1/B2、D19-1、D21-1、D22-1、D24-1 已修复；D23 与 D24 的失败断言经核对属于测试判定错误并已校正。
- 全量 Flutter 测试 444/444 通过，详见 `docs/REVIEW_2026-10-02_D15_D26.md`。
- 下一步先由用户决定 G1、C2、Windows 播放依赖和 M6 方向；本检查点不自动创建新的 GLM 工作单。

- 本机必须完成：一台真实 Android 手机的首播、暂停/继续、seek、倍速、换线路、旋转/后台
  恢复、退出重进；真实 Bangumi token、弹弹play 审核凭据和用户站点写入。
- GLM / dpsk 可完成：D11 验证数据解析、D12 夹具元信息自检、D13 原生状态机测试 seam、
  D14 UI 定位与文档漂移扫描。纯代码结果交付后，本机负责设备复验并在本文件追加检查点。

## D11：播放器验证数据解析（已完成）

- 新增 tools/video_verify_metrics.py：把 TriomiNativeVideo 的 prepared/state/error 日志
  解析成结构化事件，并计算播放位置推进量；把截图的非黑比例、平均帧差和变化像素整理成
  可比较摘要。
- assert_dynamic_playback 同时要求 prepared、无原生错误、时间轴推进、画面非黑和相邻帧
  变化，避免再次只看进度条就判断“视频正常”。
- 新增 tools/test_video_verify_metrics.py，覆盖正常动态播放、无关 logcat 噪音和静态黑屏
  拒绝路径；python -m unittest discover -s tools -p "test_*.py" -v：3 例通过。
- 本项是纯数据层，可交给 GLM / dpsk 维护；它不替代 API 35 模拟器或物理手机验收。

## D12：视频夹具元信息自检（已完成）

- 新增 tools/check_fixture_media.py：离线读取 sample.mp4 的帧数、帧率、时长、分辨率，
  并抽样计算相邻帧平均差；默认执行还会拒绝无帧、异常短片段或静态视频。
- 当前摘要：720 帧、24 fps、30.0 秒、640x360，抽样最大平均帧差 29.329，dynamic=true。
- 新增 tools/test_check_fixture_media.py；与 D11 单测合计 4 例通过。
- 该检查可交给 GLM / dpsk 接入 CI；它只证明夹具文件本身可解码且有变化，不证明 Android
  合成、网络 Range 或真实站点播放。

## D13：原生播放器状态机测试 seam（已完成：本机草稿 + 外部复核，见文末 D13 交付）

- 新增 lib/features/player/data/native_video_state_machine.dart，把 setUrl、prepared、播放/
  暂停、seek、completed、error 与 Surface 销毁/重建的行为整理成纯 Dart 状态转换模型。
- 新增 test/native_video_state_machine_test.dart，覆盖自动首播、暂停继续、位置保留、Surface
  重建恢复、完成/错误停播、换线路重置和 seek 边界，共 4 例通过。
- flutter analyze：No issues found；focused Flutter test：4 例通过。
- 该模型目前是行为契约测试 seam，不直接驱动 Kotlin MediaPlayer。应交给 GLM 复核它与
  NativeVideoPlatformView.kt 是否存在语义漂移；任何 Kotlin/设备行为变化仍由本机复验。

## 工作分配记录

- 用户要求把适合外部模型的工作明确拆出；已新增 docs/GLM_DPSK_WORK_ORDERS.md。
- G1/D11、G2/D12、G3/D13 和 P1/D14/P2 均写明了背景、允许/禁止文件、验收命令和交付模板。
- 当前分配：GLM 优先复核 G1、G2、G3；DPSK 实现 P1/D14 扫描器并做 P2 测试审计。
- 本机保留 APK 构建、模拟器/真机动态画面、真实网络和真实凭据联调；外部模型不得把纯
  代码测试写成设备验收。

---

# 外部模型交付记录（GLM + DPSK，2026-10-01 第二轮）

> 按 GLM_DPSK_WORK_ORDERS.md 的分工，G1/G2/G3（GLM）与 P1/P2（DPSK）已全部交付。
> 每项独立 commit；单测结果不写成设备验收；未索要、写入或提交任何真实凭据。

## D11 交付：播放器验证数据解析复核（G1）

- **完成范围**：`tools/video_verify_metrics.py` 收紧三处——①解析层对 URL 做
  二次脱敏（剥 query/fragment 后才进数据类，Kotlin 已脱敏是第一层，这里是
  第二层）；②`progressed_ms` 从 max-min 改为相邻样本正增量累加，位置回退
  （Surface 重建 seek 回旧点）与换线路重置（旧片尾 → 新片头）不再被算成推进；
  ③动态断言像素判定从 max 改为均值 + 变化采样占比（默认 ≥50%），
  「首帧动过、之后冻结」的截图不能再用单点尖峰蒙混。
- **测试**：`python -m unittest discover -s tools -p "test_*.py" -v`，
  D11 组 3 → 14 例（空日志、query/token 不进输出、多 prepared、位置回退、
  跨线重置、首帧冻结、changed/non_black 全 None、原生 error 拒判、
  时间轴推进≠画面变化）。未引入新依赖。
- **设备限制**：纯数据层，不验证真实播放；10.0.2.2 等地址只是被解析的
  日志字符串，测试从不发起网络请求。
- **本机复验步骤**：用设备脚本采一组新 logcat + 12 帧，跑
  `assert_dynamic_playback`；重点看换线路场景下 `progressed_ms` 是否只计
  新线路增量。

## D12 交付：视频夹具元信息自检复核（G2）

- **完成范围**：`tools/check_fixture_media.py` 收紧三处——①frames/duration
  改按**实际解码帧数**计算：截断文件的元数据仍声称完整时长，逐帧解码后
  时长骤减即被拒；②`validate_fixture` 帧率判 `not (fps > 0)`，0 与 NaN
  （部分损坏文件会让 OpenCV 回 NaN）都拦得住；③JSON 摘要改为
  `to_json_dict()`：字段集合稳定、只带文件名不带绝对路径（摘要要进检查点
  与日志，机器布局不该外泄）。另设 20000 帧解码上限防误传大文件。
- **测试**：D12 组 1 → 8 例（真实夹具回归、JSON 形状稳定且无绝对路径、
  坏文件 RuntimeError、截断文件拒判、零帧/零 FPS/NaN FPS、过短视频、
  静态视频、动态临时视频）。临时视频用 tempdir + MJPG 合成，
  **不触碰真实夹具文件**（sample.mp4 全程只读）。
- **设备限制**：只证明夹具文件可解码且有变化，不证明 Android 合成、
  网络 Range 或真实站点播放。
- **本机复验步骤**：重跑 `python tools/check_fixture_media.py`（当前摘要
  720 帧 / 24 fps / 30.0 s / 640x360 / 抽样帧差 29.6 / dynamic=true），
  与检查点上的旧数字对齐即可。

## D13 交付：原生播放器状态机契约复核（G3）

- **完成范围**：对照 `NativeVideoPlatformView.kt` 逐条复核后，修正
  `native_video_state_machine.dart` 三处与 Kotlin 的语义漂移：
  ①`play`/`pause` 在未 prepared 时只记录意图、不再把相位谎报成
  prepared/paused（Kotlin 是翻转 shouldPlay + `if (prepared)` 才动作），
  duration=0 的流（直播/未知容器）也能在 prepared 后进入 playing；
  ②`seek` 未 prepared 时忽略（Kotlin 同款守卫），Surface 释放后同样无效；
  ③换 URL 后旧时长不再残留影响 seek 上界。
- **测试**：`flutter test test/native_video_state_machine_test.dart`，
  4 → 9 例，新增「暂停后 Surface 重建不自动播放」「duration=0 seek 不崩
  不钳死」「prepared 前 play/pause 只记意图」「prepared 前 seek 忽略」
  「换线路旧时长不残留」。`flutter analyze` 零问题。
- **Kotlin 偏差报告（按工作单只报告不改）**：
  1. `setRate`（0.25–4 钳位、prepared 后重放）未建模；UI 档位 0.5–3.0
     无实际冲突，但 seam 覆盖不了倍速回归——真机清单须保留倍速项（已在）。
  2. Dart `seek` 在已知时长时上钳到 duration，比 Kotlin（只下钳 ≥0、上界
     交 MediaPlayer 内部裁剪）更严，方向安全，建议保持。
  3. `onCompleted` 的 position 取 durationMs；Kotlin 记录实际最后位置，
     个别容器元数据可能差几百 ms，影响可忽略。
- **设备限制**：seam 是纯 Dart 契约模型，不驱动真实 MediaPlayer；
  Kotlin/设备行为变化仍由本机复验。
- **本机复验步骤**：真机清单已有项之外，补充验证「暂停 → 旋转/后台 →
  回来不自动播放、位置保留」与「直播/未知时长流 seek 不崩」两条。

## D14 交付：UI 定位与文档漂移扫描器（P1）

- **完成范围**：新增 `tools/ui_doc_drift_scan.py`（纯 Python，无新依赖）：
  ①脆弱定位检测——导航/点击上下文里的字面下标（`chips[2]` 这类）与
  「第 N 个…」式位置标签，循环变量、`[0]`、语义文本与无导航上下文的
  数据断言不误报，支持 `# drift-scan: allow` 抑制；②文档漂移——当前
  真相文档里残留未勾选的 T1-T7/D1-D5 旧工作单条目（warning）；历史声明
  必须是显式自指（本文件…历史/标题含「历史记录」），仅引用「历史」二字
  的当前文档不误伤；③双 PROJECT_SPEC 对比——根目录历史副本带弃用标记 →
  info，缺失 → warning；历史只报告不改写；④`--json` 机器可读输出
  （相对路径，无绝对路径泄漏），**只有 error 级别才非零退出**。
- **测试**：D14 组 16 例（固定索引/循环变量/[0]/数据断言/位置标签/语义
  文本/抑制标记/相对路径/单测自排除/生成代码跳过/旧待办警告与退出码/
  历史文档/双规格对比/JSON 输出）。
- **真实仓库首扫**：**0 error / 5 warning / 1 info，exit=0**。
  warning 是 `docs/PROJECT_SPEC.md:113-117` 的 D1–D5 旧勾选——按
  handoff/README 记录这些功能均已交付并设备验证，属真实文档漂移；
  工作单未授权改 PROJECT_SPEC，留待本机更新规格时打勾或标注。
  info 是根目录 PROJECT_SPEC.md 历史副本提示（弃用标记在位）。
- **设备限制**：无（纯静态扫描）。
- **本机复验步骤**：`python tools/ui_doc_drift_scan.py --json` 纳入每次
  交付前检查；若未来出现 error，说明有脚本/测试退回固定索引导航。

## P2 交付：纯测试质量审计

四项检查覆盖 G1/G2/G3/P1 全部交付物（grep + 逐文件核对）：

| 检查项 | 结果 |
|---|---|
| 绝对路径 | 无。夹具路径全部 `__file__` 相对或 tempdir；扫描器 JSON 断言无绝对路径 |
| 在线站点 | 无真实域名请求。所有 URL 是占位符或被解析的日志字符串 |
| 真实凭据 | 无。唯一 token 是伪造的 `super-secret`，且被断言不进入任何输出 |
| 时间轴≠画面 | G1 断言同时要求推进+非黑+帧变化，并有「只有推进没有像素变化必须失败」「首帧冻结必须失败」两条专门测试；`progressed_ms` 正增量累加防回退虚报 |

- **写入边界**：所有写操作都在 tempdir；真实夹具 sample.mp4 只读。
- **结论**：G1 硬化时已把上述保障内建，本轮无需再改测试或纯函数。

## 第二轮验收汇总

- `python -m unittest discover -s tools -p "test_*.py" -v`：**38 例全过**
  （D11 14 + D12 8 + D14 16）。
- `python tools/check_fixture_media.py`：720 帧 / 24 fps / 30.0 s /
  640x360 / 抽样帧差 29.6 / dynamic=true（与首轮一致）。
- `python tools/ui_doc_drift_scan.py --json`：0 error / 5 warning /
  1 info，exit=0。
- `flutter analyze`：No issues found。
- `flutter test --reporter compact`：**352 例全过**（343 + D13 新增 9）。

## 仍需本机/真机的部分（不变 + 新增两条真机项）

- 原有：物理真机全链路（首播/暂停/seek/倍速/换线路/旋转/后台恢复/退出重进）、
  真实 Bangumi token、弹弹play 审核凭据、用户站点写入。
- 本轮新增进真机清单：①暂停 → 旋转/后台 → 恢复后不自动播放且位置保留
  （D13 契约的设备侧验证）；②直播/未知时长流的 seek 行为（duration=0 契约）。

## 第三轮 Codex 接收（2026-10-01）

- 接收基线 712890e，保留原有四个 tools 文件的未提交修改。
- D11 修复同 URL 重载沿用旧播放证据、精确 tag 过滤、无效像素拒判与 userinfo 脱敏；
  D13 修复暂停 Surface 重建期间提前允许 play/seek；Android 倍速后恢复暂停意图，
  未知时长重建保留位置。详情见 REVIEW_2026-10-01_ROUND3.md。
- 最终 analyze 零问题、Flutter 354 例通过、Python 47 例通过、媒体自检正常；
  漂移扫描 0 error / 0 warning / 1 info，git diff --check 通过。
- 重新构建 debug APK 并安装 emulator-5554；正式播放器 12 帧断言 PASS：non_black
  85.45%–86.22%，帧差 3.346–5.574，变化像素 8.686%–11.362%，推进 6280 ms。
- 本轮设备验证为夹具首播/动态帧；暂停/倍速/旋转组合与未知时长仍需设备复验。
- 上一批代码接收通过；下一批 D15（CI/扫描范围）、D16（数据库升级）、D17（验收证据）
  已在 GLM_DPSK_WORK_ORDERS.md 顶部待用户手动派发。无自动提交或模型派发。

## 用户追加：扩大 GLM 连续任务包

- 原 D15–D17 扩为 D15–D26 共12项，新增备份/下载/追踪/LNS/JS/阅读/导出边界
  回归、夹具 HTTP 契约及平台依赖/TTS资料，细则见 GLM_BATCH_D18_D26.md。
- 允许 GLM 按序连续执行，不逐项等审核；生产缺陷留下失败复现后继续独立任务。
- 每项 docs/delivery/Dxx.md，全批 BATCH_D15_D26_SUMMARY.md，Codex 统一审核修复。
- 本次仅扩展规划文档，未把新增工作写为完成，未自动分配模型、提交或修改生产代码。
