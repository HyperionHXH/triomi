# GLM / DPSK 可直接接手的工作单

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
