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

## D13：原生播放器状态机测试 seam（本机草稿完成，待外部模型复核）

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
