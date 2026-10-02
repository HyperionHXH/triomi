# M3 复查记录（追番闭环）

**日期**：2026-10-01（原始 M3 交付记录 + Android 播放收口） ｜ **提交**：见 git log

## 交付内容

### 播放器（桌面 media_kit / Android 原生 TextureView）
- `PlayerPage`：桌面端 media_kit/libmpv、Android 端原生 TextureView + MediaPlayer + 自绘控制层。播放/暂停、±10 秒（两侧单击）、
  双击切换播放、进度拖动、倍速接口、上一集/下一集、剧集抽屉、多线路切换、
  全屏（沉浸式 + 横屏，返回键先退全屏）、每 5 秒落一次进度与历史。
- 番剧内容解析走规则引擎：`content.playSources`（同一元素取线路名 + 地址），
  弹幕地址由规则 `content.danmaku` 模板声明（`{id}` 渲染为章节 remoteId），
  返回弹弹play 格式 JSON，由 `DandanplayClient.parseCommentsBody` 统一解析。
- 真实弹弹play 接入保留：填了 AppId/AppSecret 后走签名接口（`crypto` SHA1）。

### 弹幕层
- `DanmakuOverlay` + `DanmakuController`：全部计算在**视频时间轴**上——
  控制器记录「(视频时间, 挂钟时间)」锚点，播放时按挂钟流逝推进虚拟时间，
  **暂停时整层冻结**，seek 后清屏重定位光标（二分），不补放历史弹幕。
- 滚动弹幕分航道（优先空闲最久的航道，挤不上就丢弃），顶部/底部各最多 3 条；
  文本宽度预测量，绘制走 Ticker + CustomPainter；`IgnorePointer` 不挡播放器手势。

### 追番页
- Bangumi `/calendar` 每日放送：星期 chips（今天高亮、默认选今天、今天没数据
  则选第一个有条目的日子）、条目卡片（封面/评分/首播日期/ID）、响应式列表。
- 调试覆盖：`--dart-define=TRIOMI_SCHEDULE_BASE=http://10.0.2.2:8123/calendar`
  把数据源指到本地夹具服务（**必须带 `/calendar` 路径**，见下面教训）。

### 夹具服务（tools/dev_fixture_server.py）
- 新增：`/calendar`（Bangumi 格式放送表）、`/anime/list|/anime/{id}|/anime/search`
  （番剧站）、`/play/{ep}`（播放线路页）、`/danmaku/{ep}.json`（弹弹play 格式）、
  `/video/sample.mp4`（ffmpeg 生成的 30 秒彩条+正弦音，支持 **206 Range**）。
- 请求日志已开启（`[fixture] ...`），方便排查"请求到底发没发出来"。

## 验证结果

| 检查 | 结果 |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | 46 passed（+7：放送解析、弹幕解析、番剧规则全链路） |
| `flutter build apk --debug` | 成功（含 media_kit 原生库） |
| 模拟器 E2E（原始 M3） | 发现页三源 → 夹具番剧详情（简介+3集）→ 播放器（进度 0:14→0:29 推进、
  线路切换入口、剧集抽屉、**弹幕多航道滚动**）→ 追番页（放送表按星期分组、今天高亮） |
| Android 视频画面收口（2026-10-01） | API 35 x86_64 `emulator-5554` 正式 Flutter 播放器显示并持续播放真实帧；12 帧复验中央视频区域非黑 85.45%–86.22%，相邻帧平均绝对差 3.36–5.92，变化像素 8.54%–11.53% |

## 模拟器 E2E 发现并修复的问题

1. **`dispose()` 里用 `ref`（Riverpod 3 禁止）**：退出播放器写最后一次进度时
   直接崩溃，破坏元素树导致后续导航卡死。修法：initState 里把仓储存进字段，
   dispose 路径不再碰 ref/invalidate。
2. **夹具规则缺 `discover.feeds`**：声明了 discover 能力却没有 feeds 数组，
   被规则自检拒绝 → 来源直接消失。补充 feeds。
3. **播种失败的路径被记入"已播种"集合**：坏规则修好后永远不会再出现。
   改为 seedBuiltins 返回**实际成功**的路径集合，调用方只记录成功的。
4. **夹具视频服务不支持 Range**：mpv 先发 Range 请求，收到 200 全量后一直缓冲。
   实现 206 Partial Content。
5. **dart-define 少了 `/calendar` 路径**：请求打成了 `GET /` → 404 →
   Riverpod 3 自动重试无限循环（转圈不止）。用夹具服务的请求日志定位。
6. **Kotlin 增量编译跨盘符崩溃**（`this and base files have different roots:
   C:\...Pub\Cache...` vs `D:\...`）：`gradle.properties` 加 `kotlin.incremental=false`。
7. **AndroidManifest 缺 `usesCleartextTraffic`**：夹具是 http，API 28+ 默认拦截明文。

## 环境与构建备忘（本机）

- media_kit 的 libmpv jar 从 GitHub Releases 下载，代理 502、直连偶尔抖动；
  已预下载到 `build/media_kit_libs_android_video/v1.1.7/`（MD5 校验通过），
  Gradle 下载任务见到同 MD5 文件会跳过下载。清理 build/ 后需重新预下载。
- Gradle 残留锁文件（`~/.gradle/caches/9.7.0/**.lock`）会导致构建报
  "拒绝访问"，构建失败后先清锁再重试。Gradle init 脚本镜像方案与
  flutter-plugin-loader（PREFER_SETTINGS）冲突，**不可用**，依赖直连可解。
- 构建含原生插件的 APK 时沙箱会干扰 Gradle 写锁/strip，需要以非沙箱方式运行。

## Android 黑屏根因与修复（2026-10-01）

- MP4、HTTP Range/206、Android 解码器和独立原生 `VideoView` 均正常；问题集中在
  `media_kit/libmpv` 外部纹理与 API 35 x86_64 模拟器的合成。
- 原生 `VideoView` 嵌入 Flutter 时还会因 URI 方式报 `No content provider`；
  `TextureView + MediaPlayer.setDataSource(String)` 消除了该路径问题。
- 正式 Android 播放路径改为 `PlatformViewLink` + `initExpensiveAndroidView`（Hybrid
  Composition）+ `TextureView`。`NativeVideoPlatformView.kt` 在 Surface 重建时保存位置/
  播放状态并恢复；桌面端仍使用 media_kit。
- 临时原生诊断页只用于定位，正式播放器不依赖它；物理 Android 手机兼容性仍待一次实测。
- dandanplay 凭据尚未有设置页入口（M5 一并做），目前规则声明的弹幕数据源已可用。
- 弹幕发送、屏蔽词、透明度设置未做（对齐 Kazumi 的完整弹幕体验属 M5 增强）。
- 播放倍速、seek、播放/暂停和线路/章节控制已接入 Android 原生桥接；物理真机回归待做。
- `schedule_providers.dart` 的 dart-define 覆盖仅调试用，正式包默认 Bangumi。

## 动态帧复验补充（2026-10-01）

- `sample.mp4` 经 OpenCV 核对为 720 帧、24 fps、约 30 秒；播放器原生日志报告
  `prepared duration=30023`，位置从 `1116 ms` 连续推进到 `7363 ms`。
- 新增临时脚本 `D:\noval_and_manga\_video_pixel_verify.py`，按语义控件导航并等待
  `TriomiNativeVideo` 的 prepared 事件后采集 12 帧；验证细节与失败修正见
  `docs/CHECKPOINT_2026-10-01.md`。
- 旧截图中的 `0:04 / 0:04` 属于媒体已结束时的采样状态，已从“时长/动态帧证据”中剔除。
