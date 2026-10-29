# Triomi iOS 端适配改动说明与自签安装指南

## 当前交付边界

源码已补齐 iOS 15.0+ 工程、原生桥与未签名 IPA 流水线。本轮按用户授权在 `feat/ios` 开发、验证、提交并推送。Windows 本机不能执行 Xcode 或 iPhone 场景；云端构建结果和下载入口以 [CURRENT_STATUS.md](CURRENT_STATUS.md) 中记录的具体运行及 GitHub Actions 日志为准。不把静态检查或 Windows 测试称为「iOS 所有模块 100% 正常」。

沿用 `pubspec.yaml` 的版本和现有应用图标；当前各端图标仍为仓库原有 Flutter 图案，没有另造 Triomi 美术资源。Bundle ID 为 `io.github.hyperionhxh.triomi`。

## 依赖审计与实现

| 组件 | iOS 路径与兼容性 |
| --- | --- |
| Flutter / Dart | 从原 Android、Windows 工作流读取相同的精确 Flutter 版本，目前 3.47.5；校验 Dart 满足 `^3.13.4`，不自动升级依赖 |
| JS 来源规则 | 新增 `IosJsRuntime`，规则在非持久 WKWebView 的独立内容世界中经系统 JavaScriptCore 执行；不在应用进程申请 JIT、动态代码或私有 entitlement |
| `flutter_js` | 保留 Android/Windows worker 用途；iOS 生产规则由独立 WebKit 适配器执行，不直接进入插件的同步 FFI 执行路径 |
| 视频 | iOS 使用系统 AVPlayer/AVPlayerLayer，内嵌、后台音频与原生 PiP 共用一个播放器；不加载 iOS libmpv。网页地址通过 WKWebView 解析，Cookie 按域名/路径/Secure 作用域取回，取消释放所属解析器 |
| SQLite / Hive | 实际使用 drift / drift_flutter、SQLite native assets 和 Hive CE；项目未使用 sqflite 或 isar。持久业务数据库、规则源码、正文及偏好沿用应用 Documents |
| 文件路径 | path_provider Foundation 支持 iOS；持久媒体、本地漫画、数据库与设置写入 Documents/Application Support，目录设置 `isExcludedFromBackup=true` 排除 iCloud 备份；仅可重建的导入副本使用 Library/Caches |
| 账号凭据 | flutter_secure_storage 使用 iOS Keychain；LK/LNS、Bangumi/AniList 沿用现有 Dart 服务，不把登录态写入 IPA |
| 网络 / WebDAV | Dio、HTML/XPath、crypto、archive 等复用 Dart 实现；ATS 允许 HTTP，局域网 WebDAV 有网络用途说明。证书验证保持开启 |
| Windows 专属库 | webview_windows、Windows 解码库仅在所属平台生效；iOS 使用原生 WebKit 和 AVFoundation |
| Mihon 扩展 | Android APK/DEX 与 Windows JVM/Suwayomi 不是 iOS 可执行格式。iOS 的“JS / API 漫画来源目录”在 Triomi 内校验、保存并运行兼容规则；不需要另外安装扩展 App、配置 JIT 或授予侧载权限。现有 APK 仓库不会自动转换为 JS 规则；旧 APK 只作为备份字节留存，绝不执行 |

JS 的 HTTP 和 HTML 选择器继续通过 Dart 宿主桥执行，保留来源权限和取消归属。调用 ID、会话 ID 和 Dart Zone 防止旧响应污染新调用；取消、超时、WebContent 终止、超限消息会撤销会话，下次请求重新加载。WebKit 公共 API 不提供立即杀死 PID 或固定内存预算，不能冒称具有 Android/Windows worker 的相同强杀保证。


### iOS 添加漫画来源：输入一个仓库网址

从 **0.12.0+176** 开始支持持久保存兼容仓库，不必逐个粘贴 JSON。先安装此版本或更新的 iOS 包，再按以下步骤操作；175及更早的版本没有“管理兼容仓库”功能。

1. 打开「漫画 → 浏览 → JS / API 漫画来源目录」，或漫画右上角齿轮进入同名入口；在来源管理点「添加漫画来源 → JS / API 漫画来源目录」。
2. 点目录右上角「管理兼容仓库」（或「管理仓库 · 添加 JS / API 来源」）。可以点「添加官方兼容仓库」，也可以粘贴下面一个网址后点「添加仓库」：

   ```text
   https://raw.githubusercontent.com/HyperionHXH/Mihon-Extensions/main/repo/triomi/index.json
   ```

   同一仓库的 `repo/repo.json` 和现代 `repo/index.json` 也声明了 `triomi.indexUrl`，新版 Triomi 会读取它后打开兼容目录；旧版 APK 索引、GitHub 网页、任意 APK 地址不能自动转换。建议使用上面更小的直接兼容索引。
3. 关闭仓库管理，等待目录显示仓库名称和兼容来源。点所需来源的「安装」；新规则默认启用，更新保留原启用状态。已安装同版本显示「已安装」，有新版显示「更新」。同 ID 存在于多个仓库时，必须确认具体仓库，不静默选择覆盖。
4. 关闭目录，返回「漫画 → 浏览」，点已启用的来源进入热门/更新列表或搜索，点作品→章节开始阅读；加入书库后从「书库」继续阅读。xkcd只支持编号或官方作品URL搜索，不提供标题搜索。
5. 仓库地址和启用状态会保存，重启无需重填。仓库「停用/移除」只停止从它加载目录，不卸载规则、不删除书库/历史/下载；要停用已安装来源，需在来源列表关闭该来源的「启用」。

远程索引及规则仅允许 HTTPS，逐跳检查重定向并限制为2MiB；远程条目必须提供SHA-256，安装前还校验规则id、类型、版本、能力。浏览目录不执行规则，明确点击安装才初始化代码。随包离线目录保留，单个远程仓库失败不隐藏已安装来源或其他目录。哈希证明下载内容与索引一致，不等于任意第三方仓库可信；只添加自己信任的仓库。

### 兼容规则不等于 APK 整库转换

`HyperionHXH/Mihon-Extensions` 中的 `triomi/rules/` 是逐站移植的 JS/API 实现，`repo/triomi/` 是带哈希的生成分发物。当前移植包含 MangaDex、Komiic、xkcd、漫画柜和 WEBTOON 繁中；各站代码/匿名网络/图片读取证据与限制分开记录于当前交付状态，不把静态schema、离线夹具或接口可达当作全部实站功能通过。

- MangaDex 保留中文目录和低流量设置；xkcd是英文科学条漫和编号搜索。
- Komiic按官方游客/已保存网站会话与图片额度读取，不包含Android插件的邮箱密码登录/自动续期，不绕过额度。
- 漫画柜只读取公开章节，对受限/隐藏章节明确报错；不执行网页脚本。
- WEBTOON只处理繁中公开网页章节，登录/付费/仅App/年龄门槛不绕过。站点停机、地区网络与TLS/DNS限制会显示实际错误；不能保证任何网络下都能读取。
- 拷贝漫画本轮公开接口返回HTTP/API210，要求官方App解除访问限制；网页也未提供可读章节/图片。因此没有把只会列作品的半成品发布成可安装规则，Android原APK继续保留。

整个APK库不能仅改文件后缀或统一包装成JSON：公共HTML/API、加解码、原生库、图片变换、账号、付费/验证流程各不相同。仓库的 `repo/triomi/compatibility.json` 只把显式移植的包标为 `ported`，其余为 `manual_port_required`；`ported`也不承诺各项账号功能对等。相同站点框架可以共享移植方法，但站点仍需独立验证与维护。应用沙盒只保存规则和下载，不是Android虚拟机，不会获得执行APK的能力。

手动导入仍接受Triomi JS/API规则JSON或JSON直接地址；仓库网址应填写在「管理兼容仓库」，不是「手动导入规则」文本框。后续在同一仓库增加兼容规则，用户刷新目录即可看到，不必重新安装Triomi；需要新宿主能力的规则除外。


## 系统集成

- CocoaPods 为项目级依赖管理方式；Podfile 最低 iOS 15.0，禁用 Bitcode，Runner 与测试使用同一部署边界。
  iOS 14.0 与当前固定 Flutter 3.47.5 不兼容：SDK `packages/flutter_tools/bin/podhelper.rb` 中 Flutter Pod 的 `s.ios.deployment_target` 为 `15.0`。单独降低 Podfile 会造成不一致，因此保留 15.0，不借本次任务降级 Android/Windows 共用的 SDK。
- `UIFileSharingEnabled`、`LSSupportsOpeningDocumentsInPlace` 开启。安装后通过「文件 → 浏览 → 我的 iPhone → Triomi」访问 Documents。不要手动删除/改写数据库和正在下载的文件；卸载应用会删除其沙盒，升级前可导出备份。
- 补齐照片添加/读取、局域网用途说明；保存漫画图片调用系统照片授权与 Photos API。文件、图片、字体和漫画导入使用系统文档选择器，读取受安全作用域保护的 URL，再复制到应用私有目录；导出用书签保留所选文件夹授权。
- `NSAllowsArbitraryLoads=true` 支持 HTTP 来源和 WebDAV；HTTP 内容及凭据没有 TLS 保护，敏感账号节点应选 HTTPS。
- `UIBackgroundModes` 包含 `audio`、`fetch`；AVPlayer 持有独立音频会话租约，使用 `.playback/.moviePlayback`。播放设置开启后台音频后，切后台时脱离视频层而保留同一个播放器的音频；回前台重新挂接。未开启时挂起并保留用户播放/暂停意图，退出播放器释放会话。锁屏、系统中断及实际蓝牙设备仍需真机验证。
  Apple 的 [allowBluetooth](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetooth) 与 [allowAirPlay](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowairplay) 显式选项针对录音类别，不能照搬到 `.playback`；系统为播放类别提供相应输出路由。
- 播放菜单中的「画中画」通过 `AVPictureInPictureController` 共用原有 AVPlayerLayer，不另开媒体流；PiP 不含 Flutter 自绘弹幕。AVPlayer 回报真实已缓冲进度并请求向片尾预载，内存由系统管理，不承诺 Android/Windows 的严格128MiB字节预算。iOS17+可使用公开MIME覆盖选项，15/16仍依赖系统格式识别。
- 活跃下载拥有独立常亮租约；完成、暂停、后台或销毁释放，不能关闭阅读器/播放器持有的常亮。系统挂起仍会停止Dart下载；回前台/冷启动恢复生命周期中断与排队任务，不恢复手动暂停、删除、完成或停用来源任务，`fetch`不承诺无限后台执行。
- 缓存页支持系统WebKit HTTP响应缓存手动清理，保留Cookie/DOM和离线内容；公共API无法测量准确字节和最早写入时间，因此显示未知，不套用Android/Windows容量/年龄自动策略。显式应用代理优先，否则Dart来源网络通过CFNetwork读取目标URL的系统代理/PAC。
- 开启 `CADisableMinimumFrameDurationOnPhone`；是否达到 120Hz 仍由设备、系统节能策略及帧耗时决定。
- 严格文件校验只接受 iOS 的精确 `/var/...` → `/private/var/...` 系统别名，不允许任意符号链接重定向。

弹幕沿用主线B站、Animeko、Gamer三个独立只读池，支持匹配纠正、各源偏移、即时显示与安全屏蔽设置；旧弹弹play凭据入口/发送客户端和来源danmakuUrl消费已移除，既有安全存储不主动删除。详见 [DANMAKU.md](DANMAKU.md)。模拟器巡检使用loopback夹具客户端及真实生产会话/渲染，不等于线上服务或所有作品可达。

主线174新增公共网络加速与`ech_http`原生资产：公开资料/规则镜像及官方评论ECH沿用主线策略，不改道账号、私有请求或原始视频；显式代理优先。iOS和Android播放器音量使用设备媒体音量读回，iOS通过公开`MPVolumeView`/`AVAudioSession.outputVolume`实现，不恢复桌面应用增益；Windows仍保留独立应用增益。模拟器无实际输出路由时如实报告不可调节，不能据此宣称硬件音量键已验收。

## GitHub Actions 获取 IPA

工作流：[build-ios.yml](../.github/workflows/build-ios.yml)。无需 Apple 证书、Team ID、描述文件或签名 Secret。

1. 本次改动推送到 `feat/ios` 会自动触发；也可在 GitHub「Actions → build-ios → Run workflow」选择该分支手动运行。`on.push.branches` 明确包含 `feat/ios`、`master`、`main`，另保留 PR 和 `v*` Tag 触发。
2. Runner 使用 `macos-latest`，从现有 build/release 工作流解析 Flutter 精确版本，运行 `flutter pub get`、缓存 CocoaPods、`pod install`。
3. 执行 `flutter build ios --release --no-codesign`。`tools/package_ios.py` 检查 device arm64 Mach-O、版本、嵌入框架和未签名边界，将 `Runner.app` 复制进临时 `Payload/`，通过 `zip -r -y` 保留执行权限和框架链接。
4. 运行 iPhone 模拟器 XCTest，以及 JS、持久化、原生网络与真实视频 integration_test。`tools/run_ios_video_smoke.py` 启动仅监听 loopback 的夹具服务，让生产 PlayerPage 实际解码 30 秒视频并验证播放/暂停/跳转及三源弹幕会话开关；测试视频不进入 IPA。Dart测试经官方`FLTIntegrationTestRunner`的XCTest通道返回结果，不依赖VM Service自动发现；模拟器ad-hoc签名仅为真实Keychain访问，真机IPA仍未签名。模拟器通过不替代真机PiP、锁屏音频、音量键、照片权限及第三方账号验收。
5. 全部成功后，在该次运行底部 **Artifacts → triomi-ios-unsigned** 下载外层 ZIP，解压取得 `Triomi-iOS-Unsigned.ipa`。不要把 GitHub 下载的外层 artifact ZIP 当成 IPA。
6. 新 `v*` Tag 的成功构建会把同名 IPA 附加到该 Tag 的 Release；不会替换既有同名但不同摘要的资产。手动运行和普通分支不会发布 Release。打包日志包含 IPA SHA-256，可在 Windows 用 `Get-FileHash .\Triomi-iOS-Unsigned.ipa -Algorithm SHA256` 对照。

### 云端全页面视觉巡检

`tools/run_ios_visual_tour.py --device <明确的模拟器UDID>` 运行生产 TriomiApp 的路由巡检。宿主只监听127.0.0.1，收到已完成渲染的页面握手后调用同一UDID的 `simctl screenshot`；原生AVPlayer画面不会被Flutter截图漏掉。每张截图记录页面、顺序、尺寸与SHA-256，拒绝缺失、重名及相同帧。录屏由 `simctl recordVideo --codec=h264` 创建，结束发送SIGINT并等待封装，再用ffprobe解码核验。失败时保留截图、日志、manifest与录屏以定位，不把中间材料称为通过。

视觉产物为 `triomi-ios-visual-tour`，包含 `screenshots/*.png`、`ios_ui_tour.mp4`、`manifest.json` 和日志；测试夹具不写进release IPA。当前清单56个独立状态：保留53状态，新增录入兼容仓库、远程规则目录、下载并在真实iOS WebKit初始化后的启用来源。目录URL为逻辑HTTPS并由测试传输严格映射到loopback，不放宽生产HTTPS校验；账号保持未登录，不输入真实秘密。

历史基线运行：[39547378733](https://github.com/HyperionHXH/triomi/actions/runs/39547378733)，源码 `9d4a5ff`，35张PNG逐张检查、191.021667秒录屏完整解码1041帧；它不是本轮173同步的验收证据。本轮按精确提交和run下载到独立的 `release_ios/<RUN_ID>/`，不得用旧图片代替53状态巡检。最终运行、产物摘要与逐张验收结果见 [CURRENT_STATUS.md](CURRENT_STATUS.md) 当前请求段。

## AltStore / SideStore / TrollStore 安装

未签名 IPA 不能直接点开安装；安装工具必须完成自己的签名或受支持的安装处理。请使用官方工具，不需要为 Triomi 启用 JIT。

| 工具 | 操作与限制 |
| --- | --- |
| AltStore Classic | 按[官方安装说明](https://faq.altstore.io/altstore-classic)在 Windows 安装 AltServer 和 AltStore；在 iPhone 的 AltStore「My Apps」点 `+`，选择解压得到的 IPA，以自己的 Apple 账号签名安装。免费账号一般 7 天到期并受活跃 App 数限制，需按[官方刷新说明](https://faq.altstore.io/altstore-classic/your-altstore)定期刷新；按系统提示信任开发者、启用开发者模式 |
| SideStore | 先完成[官方安装及配对/VPN 前提](https://docs.sidestore.io/docs/installation/prerequisites)；官方当前要求 iOS 15+。开启所需本机 VPN，在 SideStore 导入 IPA 并使用自己的 Apple 账号签名；安装、更新与刷新均遵循该版本 SideStore 的网络/配对要求及免费签名期限 |
| TrollStore | 仅适用于[官方列出的系统版本](https://github.com/opa334/TrollStore)：14.0 beta 2–16.6.1、16.7 RC (20H18)、17.0；Triomi 本身另要求 iOS 15+。设备已正确安装 TrollStore 时，通过系统分享或 TrollStore 的安装入口选择 IPA。不要据此认为 iOS 17.0.1+ 或任意新系统均支持；实际安装兼容性尚未由本轮真机验证 |

覆盖升级请沿用同一安装工具、Apple 团队和稳定 Bundle ID；改换签名身份可能无法覆盖或失去原 Keychain 访问。先在「我的 → 备份与恢复」导出备份到沙盒外；恢复不会迁移账号秘密，需要重新登录。不要通过卸载来解决更新问题后才考虑备份。

## 历史基线验证（不替代本轮173同步）

- `flutter analyze --no-pub`：零问题。
- `flutter test --no-pub`：1279 项通过，3 项跳过；包括 iOS 冷队列重建/回前台与手动暂停竞态、Android/iOS 弹幕切集迟到响应及开关、iOS APK 入口降级，以及本轮规则导入面板退出动画控制器生命周期回归。
- Python 工具测试：109 项通过；夹具媒体检查通过。
- UI 文档扫描：0 error / 0 warning；交付文档扫描：0 error / 35 个历史模板 warning。
- Swift 语法树、plist、工作流 YAML 可解析；这不等于 Xcode 编译或 Apple API 类型检查通过。
- Windows 原生烟测：实际构建并启动 `triomi.exe`；Documents 内 SQLite/本地漫画/规则/Hive 重开、封面读取、凭据存储及备份互斥通过，iOS 网页解析用例按平台跳过。该证据不外推为 iOS 通过。
- Windows 生产 PlayerPage 实际编译启动，以 loopback HTTP 解码现有 30 秒 MP4，位置推进/暂停保持、跳转、来源弹幕开关及恢复播放通过；这不是 iOS 原生 PiP 或真机目视证据。
- Android 普通调试 APK 编译通过（未安装到设备）；本机初始解码库/SQLite 下载超时通过既有且摘要匹配的缓存解决。插件有现存 KGP 迁移 warning，未改动版本或关闭校验。
- iOS 云端运行39547378733全部通过：Release真机无签名构建与IPA校验、原生XCTest10项、真实JS/存储/视频集成5项、生产UI巡检35张截图及录屏上传。本地IPA SHA-256为 `cacfaaf55fc133aec2b0c6e28e7143e20e10621ad0dfabcd4dc01ab693a8c47b`，与云端打包日志一致。
- 实体iPhone侧载、真实LK/LNS登录、追踪/WebDAV远端实写、锁屏音频、真机PiP、120Hz和照片授权尚未验证；模拟器与夹具通过不等于这些场景已通过。首次VM Service等待根因未证实，保留有界诊断，不宣称确定性根治。
