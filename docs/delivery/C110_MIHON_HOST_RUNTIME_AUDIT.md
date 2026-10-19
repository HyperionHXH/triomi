# C110：Mihon 1.6 宿主审计与安全边界

日期：2026-10-06。负责人：Codex。当前状态：**已完成首批真实 APK 闭环；扩展全量兼容仍未宣称**。

## 本轮确认

真实 MangaDex 1.6 APK 已从仓库下载并通过包名、版本、签名和 DEX 检查。`apkanalyzer` 显示它定义 45 个扩展包、约 22,107 个类，但引用宿主提供的 `eu.kanade.tachiyomi.source`、`source.model`、`source.online`、`okhttp3`、Kotlin 协程/序列化、Injekt、Preference 等 API。APK 只有 `classes.dex`，不包含这些完整宿主实现。

参考 Komikku 的 `source-api` 后确认，`extensions-lib` AAR 不能直接作为运行时：其默认 `CatalogueSource` 方法包含 `Stub!`，并且 `HttpSource` 依赖 `NetworkHelper`、Cookie、请求协程桥接和 Injekt DI。仅新增 OkHttp、协程或 `DexClassLoader` 都不足以执行来源。

## 本轮代码变化（历史调查记录）

当时的 `MihonHost.inspect` 仅执行只读的 APK 元数据、签名、DEX 和工厂探测，返回：

- `ok: false`
- `factoryLoaded: true/false`
- `executable: false`
- `capabilities: []`

这阻止 UI 把 `createSources()` 反射成功误报为可搜索或可阅读。该历史结论已被后续运行时实现替代。

## 可复验命令

工作目录：`D:\noval_and_manga\triomi`

```text
& 'C:\Android\sdk\cmdline-tools\latest\bin\apkanalyzer.bat' dex packages --defined-only 'C:\Users\MiunaH\AppData\Local\Temp\mangadex-1.6.0.apk'
& 'C:\Android\sdk\cmdline-tools\latest\bin\apkanalyzer.bat' dex code --class eu.kanade.tachiyomi.extension.all.mangadex.MangaDex 'C:\Users\MiunaH\AppData\Local\Temp\mangadex-1.6.0.apk'
```

本轮结果：命令退出码 0；定义扩展类存在；类继承 `HttpSource`，包含 suspend 的列表、搜索、更新和页面方法，并调用 OkHttp 请求。上述证据是 APK 静态分析，不是联网、模拟器或真实阅读验收。

## 当时未完成与下一步（历史记录）

当时仍需实现 Android-only `mihon-runtime`。该缺口已在后续实现并由本文件的模拟器证据补验；此历史段落不代表当前 executable 状态。

下一阶段的目标是用真实 MangaDex 1.6 APK 完成搜索→详情→章节→页面图片闭环，再验收第二个中文扩展和 1.4 边界；该目标已在下方模拟器证据中完成首批验证。

补充：诊断边界要求 APK 位于 Triomi 私有 staging 目录，并返回 APK SHA-256；扩展页持久化最近一次宿主诊断。

## 2026-10-06 Android 模拟器闭环证据

设备：`emulator-5554`。构建前设置 `ANDROID_SDK_ROOT=C:\Android\Sdk` 与 `ANDROID_HOME=C:\Android\Sdk`，安装当前 debug APK 后通过 `run-as` 将 APK 放入应用私有 `files/mihon-staging`。设备证据使用真实 APK 执行，不使用规则 fixture 或 Dart/API 替代。

MangaDex 1.6（包 `eu.kanade.tachiyomi.extension.all.mangadex`，versionCode `106000`，APK SHA-256 `12FDE77601D48C8B231340694DB8446FBA5A555CED4109B231C9D2E3000915FB`，签名 `9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`）返回 `factoryLoaded=true`、`executable=true`、`abi=1.6`、61 个来源。此前已在同一宿主完成真实 `search → detail → chapters → pages → image`：页面由扩展生成，图片响应返回 bytes，URL 与 Referer/Origin 等请求头来自扩展 `imageRequest`；停用后请求被拒绝，force-stop/restart 后启用偏好恢复并可继续请求。

十八漫画 1.6（包 `eu.kanade.tachiyomi.extension.zh.eighteenmanhua`，versionCode `106003`，APK SHA-256 `B34764ED4E9CE8448258310E7E22EFFA9DD5C8F2A5C3A204760AA4BD5CEE5121`，签名 `9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`）的 `keiyoushi.source.Generated` 是单个 `HttpSource` 而非 `SourceFactory`。宿主已兼容该形态，inspect 返回 `executable=true`、`abi=1.6`、来源 `18漫画 (zh)`。真实搜索请求确实进入插件并访问 `18mh.org`，本次模拟器连接 IPv4/IPv6 均在 30 秒超时；这是外站网络失败，不记为搜索成功。

拷贝漫画 1.4（包 `eu.kanade.tachiyomi.extension.zh.copymanga`，versionCode `85`，APK SHA-256 `0A208F10B4F8FA3F3F0FAE7704935E1A487C6EE342722C7E7818A02AD8C8DD6A`，签名 `896d1ca35175c42baf61b1a157e4354df9568beed4ccc82a03762d1167005e79`）无 `SourceFactory`，宿主通过 DEX 扫描实例化具体 `CopyManga : HttpSource`，inspect 返回 `executable=true`、`abi=1.4`、来源 `拷贝漫画 (zh)`。真实搜索“海贼王”返回多条中文结果，证明 1.4 Rx 请求/解析桥、`NetworkHelper.getCloudflareClient` ABI 和旧扩展默认网络路径可执行。

以上证明首批 1.6 工厂、多形态 1.6 单源和 1.4 中文扩展可执行，不代表仓库全部 2489 来源兼容。扩展的站点登录、Cloudflare 挑战和站点自身可用性仍按实际错误返回。

## 2026-10-06 本地回归补验

本轮仅补充离线解析/边界测试，没有修改 Android 宿主、source-api ABI 或 Dart 生产协议。新增回归覆盖：

- Mihon 64 位来源 ID 按字符串保留，不转换成 Dart number；
- 兼容索引顶层 `extensions` 形式并保留 `contentWarning`；
- 空 `sources` 扩展不推导漫画/小说类型或来源能力；
- 非 HTTPS 仓库地址在发出网络请求前被拒绝。

验证环境：工作目录 `D:\noval_and_manga\triomi`，Flutter SDK 来自本机 Android 构建配置（local.properties 不随仓库提交；SDK 为 `C:\Users\MiunaH\.workbuddy\binaries\flutter\sdk`），命令前设置 `ANDROID_SDK_ROOT` 与 `ANDROID_HOME`。

```text
flutter test --no-pub test/mihon_repository_test.dart --plain-name "解析 Mihon extensionList 并按中文和类型筛选"  # 退出码 0，1 项
flutter test --no-pub test/source_boundary_guard_test.dart                                      # 退出码 0，6 项
```

完整运行 `test/mihon_repository_test.dart` 时，文件中并发加入的两个 widget 用例失败：它们期望“宿主已执行/不可用”文案，但测试初始化的下载/宿主状态与当前异步仓库加载不一致；该失败不能证明 APK 执行能力，也没有通过删除断言或修改生产逻辑处理。该测试夹具缺口保留并单独记录。

## 宿主桥聚焦检查（2026-10-06）

当前宿主改动已提供 `mihonInspect`、`mihonSetEnabled` 和 `mihonRequest` 三个 MethodChannel 方法，并在 Android 侧编译通过；此前没有 Dart 通道契约测试。本轮新增 `test/mihon_platform_channel_test.dart`，只验证：

- 非 Android/无宿主环境下 inspect、enable、request 返回明确失败结果而不抛出；
- 搜索请求保留 `operation`、页码、64 位字符串 `sourceId` 和 query，并能接收结构化结果。

命令与结果：

```text
android\gradlew.bat :app:compileDebugKotlin --no-daemon  # 退出码 0，BUILD SUCCESSFUL
flutter test --no-pub test/mihon_platform_channel_test.dart # 退出码 0，2 项
flutter test --no-pub test/mihon_repository_test.dart --plain-name "客户端在网络请求前拒绝非 HTTPS 仓库地址" # 退出码 0，1 项
flutter test --no-pub test/source_boundary_guard_test.dart # 退出码 0，6 项
```

这些是桥协议、解析和边界证据；上面的模拟器日志补充了 APK 工厂/单源/1.4 加载与真实 HTTP 证据。当前仍缺正式 instrumentation 测试文件，设备闭环由可复查 logcat 命令记录。

## 2026-10-08 收尾验证

新增安装后启用语义：首次安装默认保持停用；若包已有保存的 `mihon.enabledPackages` 偏好，安装/更新通过 executable probe 后会调用 `mihonSetEnabled` 同步 native 状态，Android 拒绝时回滚 Dart 偏好。

本机执行的 Flutter 回归：

```text
工作目录：D:\noval_and_manga\triomi
flutter test --no-pub test/mihon_reading_test.dart test/mihon_repository_test.dart test/mihon_platform_channel_test.dart test/reader_restart_test.dart test/source_boundary_guard_test.dart test/source_first_launch_test.dart
退出码：0；25 项通过
```

本机首次尝试执行重启阶段时模拟器未连接，随后启动已有 `triomi_api35_clean` AVD 并重新执行成功：

```text
flutter test --no-pub integration_test/mihon_apk_reading_test.dart -d emulator-5554 --dart-define=MIHON_PHASE=resume --no-uninstall
退出码：0；1 项通过，设备 emulator-5554（triomi_api35_clean）。
```

本次 `MIHON_EVIDENCE`：

```json
{"phase":"resume","sourceId":"mihon:eu.kanade.tachiyomi.extension.all.mangadex:5148895169070562838","popularCount":0,"keywordSearchCount":20,"title":"烙印勇士","chapterCount":8,"pageCount":23,"persistedPage":3.0,"imageBytes":1975643,"imageWidth":2000,"imageHeight":2824,"disabledRejected":true,"failedUpdateKeptOldPlugin":true,"status":"passed"}
```

这证明重启后 APK 不重新下载，source registry 从 Preferences 恢复，阅读器回到第 4 页，插件图片请求仍可用。此前首次 install 阶段的 APK 下载、签名/DEX 校验和启用状态证据与本次 resume 证据共同构成完整闭环。

Android 构建收尾（2026-10-08）：

```text
工作目录：D:\noval_and_manga\triomi\android
环境：ANDROID_SDK_ROOT=C:\Android\Sdk，ANDROID_HOME=C:\Android\Sdk
.\gradlew.bat :app:assembleDebug --no-daemon
退出码：0；BUILD SUCCESSFUL；app-debug.apk 已生成
```

## 2026-10-08 第二个中文扩展完整阅读补验

使用真实拷贝漫画 APK `1.4.85`（extensionLib `1.4`，包 `eu.kanade.tachiyomi.extension.zh.copymanga`，APK SHA-256 `0a208f10b4f8fa3f3f0fae7704935e1a487c6ee342722c7e7818a02ad8c8dd6a`，签名 SHA-256 `896d1ca35175c42baf61b1a157e4354df9568beed4ccc82a03762d1167005e79`）在 `emulator-5554` 完成下载、签名/版本校验、私有 staging、加载、启用和真实站点请求。搜索“海贼王”返回 21 条，详情标题为“海贼王”，章节 399 条，章节页面 209 张；通过插件生成的图片请求返回并解码 135,795 bytes 图片（800×1222）。停用后搜索被拒绝，错误更新被拒绝且旧版本仍可搜索。

安装阶段使用 `--no-uninstall` 保留数据；随后执行 `adb shell am force-stop io.github.hyperionhxh.triomi`，以 resume 阶段重新启动。持久化来源重新注册，页面恢复为索引 3（第 4 页），搜索、章节和插件图片再次成功。完整机器记录见 [`C113-copymanga-live.json`](evidence/C113-copymanga-live.json)。验收入口是参数化后的 `integration_test/mihon_apk_reading_test.dart`；参数未提供时仍执行默认 MangaDex 1.6 路径。

此证据使第二个中文扩展达到真实阅读与重启闭环；不代表整个仓库兼容。十八漫画 1.6 仍是宿主加载成功、目标站点请求超时，未计为搜索成功。当前 Mihon CookieJar 持久化已有实现，但 Cloudflare interceptor 仍为透传，挑战解决与登录站点仍在 S4。

## 2026-10-08 Cloudflare 错误边界第一步

默认 OkHttp 网络栈现在会对 403/503 响应检查 Cloudflare server/challenge header 和 challenge HTML 标记；识别到挑战时关闭响应并抛出明确的 `Cloudflare challenge required` 错误，避免把挑战页送进扩展解析器后伪装成空目录。Dart Mihon 来源将 challenge/captcha 分类为权限错误，超时、401/403、429、404 保持各自分类。`test/mihon_reading_test.dart` 3 项通过，`:app:compileDebugKotlin` 成功。

这只是挑战识别与错误呈现，不会自动求解挑战；本轮没有真实 Cloudflare 站点设备证据，Cookie 跨重启也尚未单独验证。
