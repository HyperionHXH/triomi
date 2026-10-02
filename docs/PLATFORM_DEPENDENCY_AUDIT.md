# 平台能力与依赖盘点（D26）

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
