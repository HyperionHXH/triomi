# 平台能力与依赖盘点（D26）

## R192 Windows修订2（已发布核验）

移除旧`media_kit_libs_windows_video 1.0.11`的2023 DLL，改应用构建固定mpv `a61f6c3abd/20261110`与ANGLE归档SHA256，包含WASAPI跨线程COM热插拔租约修复；media_kit API/原生ANGLE渲染与Android Media3不变。平台/UI线程保持Flutter正常合并，不依赖上游将移除的独立UI线程措施。WebView按当前导航序列和入口文档完成串行，页面no-referrer及每媒体HLS格式正确传递/清除；不关闭TLS或清Cookie。真实来源/公开包/远端1982回归、2项原生生命周期与完整Windows发布、外部CDN路线限制均以[当前状态](CURRENT_STATUS.md)和R191综合JSON的R192追加段为准。

## R191 桌面播放复查

来源浏览器初始化与视频解码是不同失败阶段；深层来源目录已在本机复现WebView2控制器创建失败，原始HRESULT现在保留。来源环境共享、同目录Windows扩展路径启动和取消所有权不改变登录/下载隔离，不依赖磁盘8.3短名。每个媒体独立stop/open/就绪，不能复用controller一次性首帧Future。与只读Kazumi的具体对照、实跑及未证实范围见[当前状态](CURRENT_STATUS.md)。

## 当前增量：W189 Windows 功能对齐（0.15.3+188，Windows 修订1）

以下依据本轮当前源码与运行证据；下方2026-10-02的依赖/能力盘点是历史，不再表示当前Windows支持状态。主线版本与Android构建号不变，不重发Android/iOS。

| 用户能力 | Android | Windows本轮实现/真实边界 |
|---|---|---|
| 应用更新 | 启动检查、下载验签、确认系统安装 | 启动及手动检查含独立Windows修订；核验完整ZIP/成员/PE后明确确认、等待原进程退出、事务替换/失败回滚/重启；可保留手动ZIP入口 |
| 待安装包/空间清理 | 原生租约与待安装恢复 | 持久待安装包重开复验、活跃安装保护、成功安装暂存回收；统计不冒称0字节 |
| 内容自动更新 | JobScheduler | 当前用户Task Scheduler每12小时及登录触发；关闭应用时独占配置运行，打开时复用同一容器检查；非计费有线/Wi-Fi及电量实测约束 |
| 内容提醒 | 系统通知 | 原生Shell串行通知队列；实际呈现确认后才提交去重代次，勿扰/拒绝保持可重试，不把提交成功当送达 |
| 本地字体/评论图片/保存插图 | SAF/MediaStore | 原生COM选择器、限额读入、Pictures/Triomi真实落盘；取消中立，显示实际文件位置 |
| 小说导出/本地漫画 | 系统目录/文件选择 | 实际目录选择与EPUB/TXT写入、本地文件/目录选择与原有导入器；保留原文件与同名导出 |
| 阅读/播放常亮 | 窗口标志/播放服务 | 独立reader/player/download/update租约；显示与系统执行请求分开，最小化释放显示请求，完成释放对应租约 |
| 媒体控制/下载反馈 | MediaSession/前台通知 | 同一个media_kit播放器接公开SMTC与媒体键；曲目与相邻剧集状态、嵌套播放器归属；任务栏进度复用当前队列，最小化继续不等于退出继续 |
| 网页播放登录态 | 来源WebView Cookie | 原生WebView2按来源+origin独立Profile；播放/下载控制器各自拥有，精确媒体/分片URL Cookie由原生读取，不接页面凭据 |
| 字幕/备份/规则更新/插件设置 | 原有功能 | 已有等价实现保留，不再重复造服务或隐式清数据 |

仍保留的系统/宿主差异：Windows不伪造Android系统PiP、屏幕亮度或前台服务；关闭桌面进程不承诺继续下载。Windows插件使用独立JVM，其网站WebView会话不自动成为JVM登录态，仍通过插件实际提供的设置管理；没有未经验证的跨宿主Cookie桥。真实账号、付费/验证码、物理媒体硬件及系统通知呈现按实证分层，不扩大承诺。

Windows同版本交付规则：语义版本/构建号保持0.15.3+188，PE资源与Windows清单带独立修订。旧客户端不认识修订协议，首次可能需手动安装本轮MSI/ZIP；此后同版本较高Windows修订可正常检查和安装，不放宽Android同构建拒绝变更字节规则。发布仅替换Windows ZIP/MSI/清单和公共摘要，Android APK身份/字节与iOS资产保留，release tag不移动，修订源码提交由清单记录。

本轮已运行的证明：1975项Flutter通过、5平台条件跳过，analyze零问题，118项Python通过；正常WindowsRelease与ZIP/MSI成功；实际MSI条件引擎验证修订降级/卸载；独立helper验证替换、回滚与失败提示；隐藏Flutter后台进程运行并跨进程读回两类空书架完成时间；两条Shell通知均收到呈现确认；原生文件落盘、字体注册、本地漫画原文件保留、媒体键及WebView2来源会话隔离通过。任务栏仅确认原生API，未冒称视觉检查；powercfg未观察到常亮请求，保留未验收；未执行真实账号或物理硬件验收。完整分层见[交付证据](delivery/evidence/W189-windows-parity-acceptance.json)。


## 历史依赖审计（2026-10-02）

> 最新增量：D37 已锁入 flutter_tts 4.2.5，前台段落朗读与阅读器代码/mock 验收完成；Android debug 构建以最新审核报告为准，真实发声未验收。Windows 缺 Visual Studio C++ 工具链及插件符号链接支持，D38 阻塞。JS 只有异步取消落地，原生同步强隔离未完成，见 ADR 001。

> 日期：2026-10-02。范围：只读盘点（pubspec.lock / 平台工程 / 插件平台实现 /
> 官方公开页面），不升级、不安装、不实现。在线资料查阅日期 2026-10-02
> （pub.dev 的 wakelock_plus / media_kit / flutter_tts 页面已核实；其余包的
> changelog 细节标「未逐一核实」）。

## 1. 平台能力矩阵（Android / Windows）

证据缩写：A=Android 工程（`android/app/src/main/…`），W=Windows 工程
（`windows/runner/…`），P=`lib/core/platform/platform_channel.dart`。

| 能力 | Android | Windows | 证据 |
|---|---|---|---|
| 番剧播放 | ✅ 原生平台视图（TextureView+MediaPlayer），模拟器动态帧已验收 | ⚠️ 走 media_kit 桌面路径，`media_kit_libs_windows_video` **1.0.11 已随 D28 加入锁文件**；Windows 构建/出画仍**未验证**（需 Visual Studio 工具链，本机没有；属 Codex 自留 D38） | `NativeVideoPlatformView.kt`；`player_page.dart` `_useNativeAndroidVideo`；`pubspec.lock`（media_kit_libs_windows_video 1.0.11） |
| JS 规则沙箱 | ✅ quickjs（本机 probe OK，D22 真实引擎验证） | ✅ 同 flutter_js dart-ffi（Windows 侧 DLL 由 `tools/setup_quickjs_dll.py` 安装，js_engine_probe_test 有不可用降级） | `js_runtime_factory_io.dart`；`js_engine_probe_test.dart` |
| 安全存储 | ✅ flutter_secure_storage 9.2.4（Android 实现内嵌于主包） | ✅ flutter_secure_storage_windows 3.1.2（DPAPI）——**包已 discontinued**，功能可用 | `lns_auth.dart`、`lk_client.dart`；`pubspec.lock:326-374` |
| 字体导入 | ✅ SAF `pickFontFile` → 拷入 `cacheDir/picked-fonts` | ❌ 通道在 Windows 未实现（`MethodChannel` 调用会抛 MissingPluginException → 静默降级为不可用） | `MainActivity.kt:31`、`platform_channel.dart:28`；W 工程无对应 MethodChannel 注册 |
| SAF / 导出 | ✅ `pickDirectory`/`writeToTree`/`pickImage`（T7-4 设备验收） | ❌ 同上，未实现 | `MainActivity.kt:47-54`；`backup_page.dart` |
| 后台更新提醒 | ✅ JobScheduler（12h、仅 WiFi、persisted；RECEIVE_BOOT_COMPLETED 权限在位） | ❌ 非 Android 平台只保存偏好（`background_update_check.dart`） | `BackgroundUpdateCheckJobService.kt`；`AndroidManifest.xml:10` |
| 音量键翻页 | ✅ Flutter 键盘事件（`LogicalKeyboardKey.audioVolumeDown/Up`，分页模式 + 开关） | ✅ 同一 Dart 路径（桌面键盘事件可用；未真机/桌面实测） | `novel_reader_page.dart:378-391` |
| 屏幕常亮 | ✅ `keepScreenOn` 通道（FLAG_KEEP_SCREEN_ON） | ⚠️ 通道未实现 → 调用被捕获降级（桌面默认常亮由系统决定） | `MainActivity.kt:35`；`novel_reader_page.dart:93-109` |
| 漫画/小说阅读、书库、追踪、备份 | ✅（模拟器 E2E 记录） | ⚠️ 代码同源可运行（纯 Dart + drift/Hive），但 Windows 构建**本机未验证** | CHECKPOINT_2026-10-01.md |
| 弹幕发送 | ✅ 设备验证（夹具） | 同 Dart 层；真实弹弹play 凭据待审核 | handoff/README |

**静默降级清单**（Windows 上当前会「无声不可用」的能力）：字体导入、SAF 导出、
屏幕常亮。原生播放的库依赖已补（D28），但桌面构建/出画本身未验证（D38）。
建议后续在设置页对未实现通道给出显式提示，而不是静默失败。

## 2. 依赖盘点（锁文件版本 → 已知影响 / 升级风险）

| 包 | 锁定版本 | 最新（查阅日） | 已知影响 | 将来升级风险 |
|---|---|---|---|---|
| flutter_js | 0.8.7 | 未逐一核实 | Android 构建需 `kotlin.jvm.target.validation.mode=warning`（已配置）；传递依赖 `js 0.6.7` **已 discontinued** | flutter_js 自身的 KGP/AGP 兼容迁移（构建告警点，见下）；js 包停止维护不影响运行 |
| flutter_secure_storage | 9.2.4（windows 3.1.2 / linux 1.2.3 / macos 3.1.3） | 未逐一核实 | **windows/linux/macos 实现包 discontinued**（pub outdated 明确标注）；当前功能正常 | 升级到 10.x 需要迁移（Android 实现拆分为独立包 `flutter_secure_storage_android`），涉及 Keystore 行为，须真机回归 |
| wakelock_plus | 1.5.2（传递，经 media_kit_video） | **1.8.1**（活跃，BSD-3，全平台） | 无（我们未直接调用，走 media_kit 的常亮） | 低风险；可随手升 |
| package_info_plus | 9.0.1（传递） | 10.2.1 | 无 | 主版本升级需过一遍 API |
| media_kit / media_kit_video | 1.2.6 / 2.0.1 | **同版**（已最新，最后发布 ~9 个月前） | 维护节奏放缓（9 个月未发版）但仍是最成熟的 Flutter 播放方案；Windows 解码库 `media_kit_libs_windows_video` **1.0.11 已随 D28 锁入**（构建/出画验证待 D38） | 库包「不可混用」；升级 libs 必须与 media_kit 同步 |
| drift | 2.35.0 | 未逐一核实 | 无（D16 升级路径已有回归） | schema 工具链在 D10/D16 已列为可选建议 |
| dio / archive / crypto / riverpod / go_router / hive_ce | 5.11.1 / 4.3.0 / 3.0.7 / 3.4.3 / 18.0.1 / 2.20.0 | 见 pub outdated | 无 | 常规 |

**构建告警（来自第三轮构建记录）**：flutter_js、package_info_plus、
wakelock_plus 使用旧 Kotlin Gradle Plugin，将来 Flutter 升级会强制迁移；
当前构建成功，不阻塞。

### 升级顺序建议（供 Codex 排期，本任务不执行）

1. ~~补 `media_kit_libs_windows_video`~~ **已完成（D28）**：`^1.0.11` 已锁入
   pubspec/lock（工作单原写 `^1.2.8` 无可解析版本，pub 建议线为 1.0.11）；
   剩余步骤是 Windows 构建/播放真实验证（D38，需 VS 工具链）；
2. wakelock_plus 1.5.2 → 1.8.1（传递，低风险，顺手消化 KGP 告警之一）；
3. flutter_secure_storage 9 → 10（需 Android 真机回归 Keystore 行为，安排在
   有真机窗口时）；
4. flutter_js / package_info_plus 的 KGP 迁移跟随上游发版，不主动升；
5. dio/archive 等纯 Dart 包按 pub outdated 常规处理。

## 3. TTS 实现资料与当前证据（D56 分层更新）

选型与约束见 `docs/TTS_RESEARCH.md`（含第 6 节实现进度后记）。当前分层：

- **代码层**：flutter_tts 4.2.5 已锁定；插件适配器（`flutter_tts_engine.dart`）
  与阅读器接线、回调竞态（token/代次）、生命周期（退出/换章/后台/繁简停止）、
  语速 0.3/0.5/0.7 与系统音色选择均已落地并有测试（D31/D37/D41/D47/D48）。
  Android 侧 manifest 已加 TTS_SERVICE 查询；Android debug APK 构建通过。
- **构建层**：Android debug 构建成功（D39-D46 复核记录）；Windows 侧
  flutter_tts 插件随依赖解析可用，但 **Windows 构建未在本机验证**
  （无 Visual Studio 工具链，见 D38）。
- **设备层（未验收）**：真实系统发声、来电音频焦点回收、后台/锁屏表现、
  Windows 语音输出——均未冒充完成，属发布前设备验收（见
  `docs/RELEASE_READINESS.md`）。

JS 沙箱措辞校准（D56）：**异步 Promise 的取消/超时已完成**（D36/D41，
job pump + dispose 拒绝）；**同步执行的强隔离未完成**（ADR 001 记录
可终止进程路线，Codex D59）——不把 Promise 取消写成同步隔离完成。
备份补偿措辞校准：**运行期异常补偿已完成**（D33/D35/D52）；**崩溃恢复、
补偿自身失败后的持久恢复与并发导入串行化未完成**（Codex D60）——
不写成「崩溃原子性完成」。
