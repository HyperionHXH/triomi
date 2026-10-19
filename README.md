# Triomi

追番、漫画、小说聚合客户端，支持 Android 与 Windows。当前测试版包含真实播放、阅读、离线下载和来源管理；来源可用性取决于第三方站点，不能保证所有插件和站点兼容。

追番 · 漫画 · 小说 三位一体的聚合客户端。

> 随包包含来源适配器与规则；正文、图片和视频由对应来源提供，应用可按用户操作缓存或下载到本机。来源声明能力不等于内容授权，使用范围以各来源权限为准。

## 下载与安装

到 [GitHub Releases](https://github.com/HyperionHXH/triomi/releases/tag/v0.11.0-test.164) 下载 **v0.11.0-test.164**：

| 文件 | 用途 |
| --- | --- |
| `triomi-android.apk` | Android 正式证书签名包，普通使用下载这个；Android 7.0 / API24 起 |
| `triomi-windows.zip` | Windows x64 完整绿色包，完整解压后运行 `triomi.exe`，不要只取 EXE |
| `triomi-windows.msi` | Windows x64 安装包，当前用户安装、开始菜单入口、覆盖升级及系统卸载 |
| `triomi-windows.update.json` | 与 Windows ZIP 配套的文件完整性清单，不是发布者签名 |
| `SHA256SUMS.txt` | 下载文件 SHA-256 校验值 |

已有同签名版本可覆盖安装，勿卸载或清除数据；建议先在「我的 → 备份与恢复」导出本地备份。开发/Actions 验收包使用另一证书，不能直接覆盖正式包，遇到签名冲突不要通过卸载丢弃原数据。当前为测试版，不宣称完整全平台验收；详情见 [当前状态](docs/CURRENT_STATUS.md)。

Windows 可任选 ZIP 或 MSI，不需要两个都装。MSI 默认安装到 `%LOCALAPPDATA%\Programs\Triomi`，不自动导入/删除旧 ZIP 目录；两种形式沿用同一应用数据目录。升级 MSI 前退出 Triomi，再运行新 MSI；卸载只移除安装文件和快捷方式，保留收藏、账号、设置及下载。MSI 目前没有 Windows Authenticode 发布者签名，系统可能提示未知发布者；请从本仓库 Release 下载并核对 SHA-256，Android 签名证书不能用于 Windows 签名。

R164 修复手机本地漫画库空状态贴边和长句换行：统一居中图标、标题及说明，整页可滚动并避让底部导入按钮。弹幕调查更正为多条独立路径：来源自带弹幕、用户自己的文件、自托管兼容服务均不等于复用官方应用密钥；当前实际能力和未实现部分见[弹幕接入说明](docs/DANMAKU.md)，本版不展示不可用入口。

R163 修复小说发现/详情简介字段兼容与账号入口自动弹窗；修复坚果云首次同步在父目录不存在时返回`409 AncestorsNotFound`而被误判为连接失败，保留Triomi独立同步目录，并用本机Kazumi配置完成只读联调；调整WebDAV表单间距、小说账号与本地漫画文件库文字边界。弹幕本版暂隐藏，接入调查与恢复条件见[弹幕暂缓说明](docs/DANMAKU.md)。

R161（0.11.0+161）移除我的混合账号卡片，设置按追番、漫画、小说拆分；三类详情和菜单分别组织，漫画连续懒章节列表、小说真实分卷，三类均可显式选章下载。小说发现/书架增加卡片间距及边界，保留正常小说解锁和换源。专项Review闭合，最终Flutter1150项通过/3跳过、Python89项通过、静态检查零问题；Android保数据、200%暗色及Windows真实在线发现/宽窄窗口范围见[当前状态](docs/CURRENT_STATUS.md)。

R160 修复「我的 → 账号与设置」顶部卡片无法点击；漫画已安装插件整行/齿轮进入多来源详情，支持插件提供的真实设置、外部浏览器与应用内会话分离。在线列表长按提供作品操作，书库长按单选可编辑本地标题、作者、简介，刷新不覆盖修改且可恢复来源资料。最终Flutter1107项通过/3项跳过、Python89项通过、静态检查零问题；Android原设备及Windows新版本实操范围见[当前状态](docs/CURRENT_STATUS.md)。

R159 进一步优化追番公开日历和封面直连；漫画书库改为四页签筛选与长按上下文操作，修复搜索框遮挡；移除小说书架刷新按钮，并修复LNS账号WebSocket端口与站点连接回退。完整Flutter1077项通过/3项跳过，最后边界46项定向通过、Python89项通过；本人LK/LNS无代理资料读取、Android实际筛选/选择及Windows真实窗口已验证，完整平台限制见[当前状态](docs/CURRENT_STATUS.md)。

R158（0.11.0）补齐追番推荐、时间表、搜索与关联作品的手机三列；当前季直接读取完整日历，资料缓存优先、刷新真实联网。漫画搜索改为独立页面，本地查询可继续全局搜索并按插件分别展示结果。最终1056项Flutter通过/3项跳过、89项Python通过、静态检查零问题；参考Kazumi与Android Komikku，实测范围见[当前状态](docs/CURRENT_STATUS.md)。

R157 修正 Bangumi/WebDAV 职责与单本地收藏同步、时间表完整加载、追番三列、紧凑播放器、漫画顶部搜索、MixN 左右翻页和 GitHub 版本管理。完整 Flutter 1041 项通过 / 3 项跳过、Python 89 项通过，静态检查零问题；真实账号及设备验证范围见 [当前状态](docs/CURRENT_STATUS.md)。


R155 已完成 Kazumi / Komikku / MixN 日常交互重做：番剧详情与选源选集、Bangumi 收藏和 WebDAV 追番同步、漫画插件浏览与单一搜索、小说站点收藏及三种阅读模式。小说朗读、应用自定义界面字号和隐私锁产品入口已移除，保留系统字号与原有数据。1004 项 Flutter / 89 项 Python 通过、3 项跳过，静态检查无问题；原设备及Windows实际使用、保数据升级与证据边界见 [C155验收](docs/delivery/evidence/C155-final-acceptance.json)。五项资产已发布并完整下载，大小/SHA-256与本地及GitHub摘要全部一致；完整平台验收仍 partial。


## 开始使用

追番、漫画、小说的设置从各自顶部齿轮进入：追番管理追踪账号、WebDAV收藏同步和播放来源；漫画管理扩展、来源、书库和阅读；小说管理轻之国度/轻书架账号、消息、字体、书架和导出。「我的」只保留历史、下载、备份及通用设置，不再显示混合账号大卡片。原账号与数据沿用原存储，不需要重新建立三套凭据。

主导航为 **追番 / 漫画 / 小说 / 我的**，各工作区保留自己的页面与搜索。业务入口的来源、追踪绑定和菜单限定当前媒体类型；外观、通用网络、存储、更新及全应用备份在「我的」进入。

### 番剧：推荐、播放与追番

1. 在「追番 → 推荐」浏览作品资料；推荐、时间表、番剧搜索和关联作品网格在手机均为三列（显式列表模式除外）。「时间表」当前季直接加载七天完整公开日历，包含跨季在播，无需额外整季分页或点击加载更多；历史季度仍完整分页。推荐资料不是视频播放源。
2. 详情以播放来源、播放列表与选集为主，保留概览、吐槽、角色、关联与制作人员资料；分区独立加载、缓存与重试，5分钟内的持久资料缓存直接展示。手动刷新绕过缓存，失败保留资料并明确提示。角色可查看资料，关联动画打开番剧详情而不是播放，书籍/游戏等关联资料不会冒充动画跳转。
3. 点击「开始 / 继续观看」选择站点作品，再选择播放列表和剧集进入播放器；上一集、播放/暂停、下一集集中，字幕、画中画和全屏在同一控制行，其他功能从更多菜单打开。
4. 详情与「我的追番」使用同一个本地收藏夹，窄屏默认三列。点击云同步合并：WebDAV 保存设备间收藏快照，Bangumi 对接想看、在看、看过、搁置、抛弃状态；可选本地/Bangumi/最新修改冲突优先级。先合并 WebDAV，再同步 Bangumi 状态，最后回传合并结果；没有配置账号时仍可本地收藏，不把本地保存宣称为云端成功。
5. 标签可点击进入对应在线题材搜索，筛选项有可见边框。
6. 添加站点：**追番 → 设置齿轮 → 番剧规则与来源 → 添加番剧来源 → 番剧规则仓库**，添加兼容的 Kazumi 仓库并检查/安装规则。

支持范围是兼容的 Kazumi api1–8 XPath/API 子集，不是全部 Kazumi 规则；需要登录或验证码的站点只能通过正常可见流程处理，不绕过挑战。Bangumi/AniList 远端同步需另行配置已有账号并明确确认写入。

### 漫画：仓库、扩展与阅读

1. 漫画有「书库 / 更新 / 浏览」；顶部搜索打开独立页面，不在工作区插入输入栏。书库先按名称查找本地收藏；输入后可点「全局搜索」携带原查询，按各个已启用且支持搜索的插件分别展示结果、加载或错误。返回保留原书库分类和查询，更新/浏览顶部搜索直接查找在线作品。书库不显示题材或“全部”过滤标签，已有命名分类保留。
   书库的筛选、排序、显示和分组集中到顶部筛选面板；长按漫画进入选择模式，再操作已读、未读、分类、下载或移出书库。整本已读／未读只修改本机阅读状态与进度：已读以已有缓存目录为准，未读归零，不虚构未缓存章节，也不改站点收藏或删除实际阅读历史。
   在线来源与搜索结果长按作品可打开快捷操作；书库长按仍用于多选，单选后可从更多进入本地资料编辑。编辑只覆盖标题、作者、简介，保留来源身份和原资料；来源刷新不覆盖本地修改，可恢复来源资料。
2. 更新只需刷新，检查期间显示进度条；没有新增章节则显示空结果，来源失败如实显示，不增加停止/失败重试/待更新控制区。
3. 浏览按插件管理组织，「已安装 / 浏览 / 仓库」各司其职；插件仅按名称查找，作品搜索与插件搜索不混用。
   已安装插件可进入详情并查看各语言来源；可配置来源打开插件提供的原生设置页。来源菜单区分外部浏览器与应用内站点验证，后者保留原有会话处理；不支持配置的插件会明确说明，不伪造设置。
4. 在「仓库」添加 **Mihon / Tachiyomi 兼容 APK 仓库的 HTTPS `index.json`**；Kazumi 地址不能放在这里。Windows 可从规则与来源设置进入 JS/API 来源。
5. 来源页保留在线作品名称/标签搜索、原生来源筛选与分页；点击作品标签进入该来源在线题材搜索。首次安装核对实际发布者，已安装项手动启用后才执行。
6. 作品详情按漫画组织封面、作者、状态、阅读/书架操作和简介标签；章节是带分隔的连续懒列表，正倒序仍保留真实阅读索引，无需通过每50章范围分页。日期、下载状态及上次读到位置仅显示已有真实记录。漫画合并与迁移不混入番剧菜单。

Android 实际执行兼容 APK，不是把 APK 当 JS 规则。已验证部分 MangaDex、拷贝漫画、Webtoons、xkcd 等扩展，不承诺全仓库兼容；Windows **不执行 APK**，请使用漫画规则目录中的 JS/API 来源。GNOME/Linux Komikku 的 server 插件格式不同，不能混装。首次未知发布者需确认，备份不迁移信任；恢复的 APK 默认停用待核验。

阅读器支持作品独立设置、条漫/分页、双页、裁边、滤镜、预载和进度恢复；离线内容跨设备需要明确选择包含媒体的备份。

### 小说：站点、账号与缓存

「小说 → 发现」按站点选择 LK/LNS 与各自频道，只保留顶部搜索入口；「书架」分全部/已下载，全部在线读取已登录站点收藏，最近阅读留在历史页，不把读过的书自动加进收藏。书架不再显示独立刷新按钮，保留下拉刷新、切换页面和账号返回后的必要加载。远端失败明确显示，已有本机收藏和离线正文保留；下载书架无需联网。详情可读取、加入和移除真实站点收藏，取消移除或网络失败不会删除本机正文/历史。

小说详情按书籍信息、来源、简介与真实分卷目录组织；发现与书架的相邻作品有独立轮廓和间距。锁章仍可进入原站点的正常解锁界面，由用户明确决定，不自动解锁。更换来源保持同媒体范围；EPUB/TXT 导出只在实际支持的小说来源中显示。

正文中间点击打开目录、文字样式和阅读设置；支持左右翻页、卡片翻页、上下滚动，以及字体、字号、行距、页边距、背景和方向。已移除朗读与相关停止/设置控件，系统读屏语义保留。LNS 使用来源专用字体；离线缓存不调用官方整书扣币下载接口，不重新打包导出受限整书。

左右翻页对齐 MixN `ReaderScreen.kt` / `SourceReaderScreen.kt` 的 `HorizontalPager(userScrollEnabled = false)`：点击左侧不足 25% / 右侧超过 75% 或按方向键翻页，中间一半显示菜单；两页同向平移，章首/章尾继续翻页会切换相邻章并恢复该章记录。拖动只用于卡片覆盖翻页，上下滚动保持连续正文。R157 修正了原先左右翻页松手才换页、出入页同侧滑动和 30%/70% 点击边界；字号、窗口宽度和模式变化沿用段落内字符锚点，缓存正文、插图和来源专用字体渲染路径保留。

### 选择剧集与章节下载

三类作品都从详情的目录区域选择具体剧集/章节，默认不选中；确认选择后再次确认入队，取消不产生下载。番剧每次只选一个播放列表，切换列表清空选择；漫画/小说可以跨卷选择。锁定章节不进入下载，完整目录不会因只下载一章而被截断；书库批量下载同样逐本选章，跳过没有可下载章节的作品。

轻书架逐章缓存沿用正常在线阅读权限，并保存所需字体以供离线使用，不等于站点整书文件下载；整书下载权限入口单独保留。进度追踪按当前媒体类型管理；Bangumi 将漫画和小说统一归为书籍候选，需要核对版本，AniList 则区分动画、漫画及小说格式。

## 本次改进与已知限制

- 四个独立工作区、固定类型在线搜索、可点击题材标签、番剧独立选源选集、漫画插件浏览，以及真实小说站点收藏。
- SQLite v11 保留原业务身份、进度、缓存与按模块分类，并持久化追番同步删除记录；旧备份继续按同一范围恢复，APK 仍需原签名核验且默认停用。
- Android 使用 Media3；Windows 使用 media_kit。实际站点解析、复杂登录、所有 APK、长时稳定性和完整多平台组合仍有待验范围。
- R157已获授权复用本机Kazumi凭据：真实Bangumi读取119项、已有状态同值写入并读回，隔离双本地库通过真实WebDAV得到一致收藏；不扩算评分/删收藏/多实体设备矩阵。凭据未写入源码、日志或备份。
- 已有功能、真实证据和剩余技术事项见 [CURRENT_STATUS](docs/CURRENT_STATUS.md)、[ROADMAP](docs/ROADMAP.md)；账号/手机环境配合只在 [USER_ASSISTANCE](docs/USER_ASSISTANCE.md) 维护。


## 当前进度

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M0 脚手架** | 工程骨架、设计令牌与主题、自适应外壳、drift 表结构、Hive 设置 | ✅ 已完成（[复查记录](docs/M0_REVIEW.md)） |
| **M1 规则引擎** | 声明式规则（HTML + JSON、CSS/XPath）、JS 沙箱（flutter_js）、来源管理、发现 / 聚合搜索 / 详情 | ✅ 已完成（[复查记录](docs/M1_REVIEW.md)、[T2 交接](docs/handoff/T2-js-sandbox.md)）｜真实 quickjs 在 Android/桌面可用，缺动态库时相关用例按既有机制报告不可用 |
| **M2 漫画闭环** | 阅读器四模式、书架、进度、历史 | ✅ 已完成（[复查记录](docs/M2_REVIEW.md)） |
| **M3 追番闭环** | Android Media3、Windows media_kit、番剧资料与追番；真实范围见当前状态 | 基础使用链路已有实证，完整来源/平台矩阵仍部分验收 |
| **M4 小说闭环** | 小说阅读器、LK/LNS适配器、字体/繁简/远端书架/消息与合法导出 | 基础闭环有双API真实账号证据；LNS没有小说按章购买，整书下载按官方权限处理，应用拒绝LNS整书重打包，不调用扣金币接口 |
| **M5 增强** | 下载恢复、备份/WebDAV、弹幕与追踪 | 生产实现和具体实证见当前主线；R157已验证授权账号状态同值实写和外部WebDAV双本地库同步，完整字段/实体设备矩阵仍不宣称通过；弹弹play官方联调明确暂缓 |

完整需求、方案与任务拆解见 [`docs/PROJECT_SPEC.md`](docs/PROJECT_SPEC.md)；
写来源规则看 [`docs/RULE_FORMAT.md`](docs/RULE_FORMAT.md)。

## 目录结构

```
lib/
├─ main.dart                     应用入口（Hive 初始化 + ProviderScope）
├─ app.dart                      MaterialApp.router、主题与本地化装配
├─ core/
│  ├─ theme/                     设计令牌与主题装配（复刻 libadwaita 观感）
│  ├─ router/app_router.dart     go_router 路由表
│  ├─ db/                        drift 表定义与数据库
│  ├─ models/                    MediaItem / Chapter / SourceDescriptor / SourceException
│  ├─ source/                    规则引擎
│  │  ├─ source_api.dart         来源能力契约（Discover / Search / Detail / Content / Account）
│  │  ├─ selector_engine.dart    CSS 与 XPath 双语法选择器、字段提取
│  │  ├─ rule_schema.dart        声明式规则模型、自检、请求模板渲染
│  │  ├─ declarative_source.dart 规则执行器（HTML / JSON 两种响应）
│  │  ├─ http_client.dart        统一网络层（dio 实现 + 可注入替身）
│  │  ├─ source_registry.dart    注册表：内置规则播种、导入校验、启停
│  │  └─ source_repository.dart  来源表读写
│  ├─ storage/preferences.dart   Hive 设置存储
│  └─ widgets/                   通用组件：AppCard / SettingsGroup / EmptyStateView / PageScaffold
├─ features/
│  ├─ shell/adaptive_shell.dart  三档自适应导航壳
│  ├─ anime/                     推荐/时间表/我的追番工作区
│  ├─ manga/                     漫画书库/更新/插件与独立来源工作区
│  ├─ library/                   共享本地仓储与显式范围分类/批量操作
│  ├─ history/                   按业务模块限定的历史
│  ├─ discover/                  番剧推荐与共用作品卡片
│  ├─ search/                    固定类型的渐进分组搜索
│  ├─ detail/                    详情 + 目录
│  ├─ reader/                    漫画阅读器（四模式）与阅读设置
│  ├─ sources/                   来源与规则管理
│  ├─ schedule/                  番剧季度/星期时间表
│  ├─ downloads/                 下载管理（队列、离线内容、仅 WiFi）
│  ├─ player/                    media_kit 播放器、弹幕层与弹幕设置
│  ├─ novel/                     小说（站点收藏 / 阅读器 / LK与LNS / 导出 / 字体）
│  ├─ profile/                   我的（备份与恢复、云同步、下载管理入口）
│  └─ settings/                  设置与独立外观页面
└─ assets/rules/                 随包分发的示例规则
```

## 开发约定

1. **颜色与尺寸不硬编码**：一律走 `AppSpacing` / `AppRadius` / `AppTypography`，
   语义色走 `context.palette`（`AppPalette`）。换主题时不允许出现漏改的魔法值。
2. **业务键永远是 `(sourceId, remoteId)` 复合键**，禁止只用 `remoteId`
   （缓存、导航、书架、进度、下载均如此）。
3. **来源错误必须分类**（见 `SourceErrorType`），聚合操作允许部分成功，
   失败必须能说明是哪个来源、哪一类错误。
4. **凭据不落日志**：密码、验证码、`security_key` 不得进入缓存、日志或崩溃上报。
5. 新增页面先套 `PageScaffold`，避免各页面自行拼 AppBar 导致桌面端观感不统一。
6. **改动 drift 表结构后必须跑 `flutter test`**：analyzer 排除了生成文件，
   生成代码的编译错误只有在测试编译时才会暴露；改表同时要补 migration。
7. 来源规则的写法见 [`docs/RULE_FORMAT.md`](docs/RULE_FORMAT.md)；
   新增规则记得把示例放进 `assets/rules/`。

## 环境与构建

- Flutter stable（当前验证版本 3.47.5 / Dart 3.13.4）
- JDK 17+、Android SDK 36（当前项目 compileSdk/targetSdk；minSdk24）
- Visual Studio 2022「使用 C++ 的桌面开发」工作负载（构建 Windows 端时需要）
- Python 3.12+ 与 .NET 10 SDK（生成 Windows ZIP/MSI 时需要；WiX 6.0.2 由仓库工具清单自动还原）

```powershell
cd triomi
flutter pub get
dart run build_runner build      # 生成 drift 代码
flutter run -d windows           # 或 -d android
flutter analyze
dart format .

# Python 工具链（tools/，需要 numpy + opencv-python-headless）
python -m pip install -r tools/requirements-dev.txt
python -m unittest discover -s tools -p "test_*.py" -v   # 工具/夹具契约/一致性扫描
python tools/check_fixture_media.py                      # 视频夹具自检
python tools/ui_doc_drift_scan.py --json                 # UI 定位与文档漂移扫描
python tools/delivery_consistency_scan.py --json         # 交付文档一致性扫描
```

Windows 一条龙构建与打包（在仓库根目录运行）：

```powershell
./tools/package_windows.ps1
# 已经构建过当前 release，只重新打包：
./tools/package_windows.ps1 -SkipBuild
```

默认输出在 `build/release/`：`triomi-windows.zip`、`triomi-windows.msi`、`triomi-windows.update.json` 和 `SHA256SUMS.txt`。可用 `-OutputDirectory` 指定输出目录，或通过 `-Flutter`、`-Python`、`-Dotnet` 指定工具路径；脚本失败立即停止，不发布半成品。MSI 使用稳定 UpgradeCode，版本映射为 `major.minor.build`（例如 `0.1.0+153` → `0.1.153`），build 必须持续递增且不超过65535；较旧 MSI 拒绝降级，同版可修复。已有 ZIP 不受 MSI 升级/卸载管理。


> **注意**：本机若设置了 `HTTP_PROXY` / `HTTPS_PROXY` 等代理环境变量，`flutter test`
> 会因 flutter_tester 的 WebSocket 握手失败而报
> `Invalid WebSocket upgrade request`。跑测试前先清除：
> `$env:HTTP_PROXY=''; $env:HTTPS_PROXY=''; $env:ALL_PROXY=''`

本机已有原证书 Android 与 Windows 完整构建及实际运行证据；公开 Release 为测试版。每轮包hash、设备/平台与实跑范围记录在 [CURRENT_STATUS](docs/CURRENT_STATUS.md)，旧轮次证据不冒称新包完整复验。

R156补充：追番标签遵循系统字号，宽度不足时单行横向滚动；状态标签有边框。时间表只显示明确放送星期的作品，未知星期不并入当前日；详情关联作品按可用宽度显示1–3列，资料内容限宽以便阅读。

## 免责声明

- 本项目不运营第三方内容服务、不在发布包中提供书籍正文或视频；客户端可按用户操作缓存、下载或导入文件。随包提供规则/适配器，不代表拥有来源内容授权。
- 请仅用于个人学习、备份与自用，并遵守所在地法律法规与各内容站点的服务条款；
  由此产生的一切后果由使用者自行承担。
- 弹幕能力对接 **弹弹play 开放弹幕网络**：使用时需自行申请应用并遵守其开发者协议，
  展示其数据时须保留完整来源标注（「弹弹play」/「弹弹play开放弹幕网络」）。
- 番剧元数据、放送表与追番进度来自 **Bangumi**、**AniList**，相关版权归各站点所有；
  个人访问令牌只保存在本机（系统安全存储），不写日志、不随备份导出。
- 本地调试夹具默认不启用；正式来源管理不展示旧夹具记录，历史书架与缓存不会因此删除。

## 持续集成

`.github/workflows/build.yml` 在 push / PR / 手动触发时跑四件事：

1. `flutter analyze` + `flutter test`（零问题、全绿是硬门槛）；
2. Python 工具链（`tools/requirements-dev.txt`：tools 单测、夹具媒体自检、文档漂移扫描）；
3. Android release APK；
4. Windows 同源 ZIP + MSI、ZIP更新完整性清单及SHA-256校验文件。

Actions Artifacts 为开发验收包，显式以 `ORG_GRADLE_PROJECT_triomiAcceptanceSigning=true` 使用 debug 证书，不用于覆盖正式签名安装。普通用户从 Releases 下载正式证书签名的 `triomi-android.apk`；缺少生产签名时构建明确失败，不回退其他证书。

生产签名使用原发布者身份，不生成替代密钥。手动 release 工作流需要已有四项私密签名配置，临时文件用后清理；可指定已存在的tag发布，留空只生成Artifacts。未配置远端签名时由维护者在受控本机验签后上传Release，不因push标签触发另一次覆盖资产构建。Windows配套清单记录实际成员大小/SHA-256，不是发布者签名。

Windows job 和本机使用同一个 `tools/package_windows.ps1`；release工作流会将 APK、ZIP、MSI、Windows更新清单一起上传，并生成覆盖四个文件的`SHA256SUMS.txt`。给 release 工作流传入包含这套脚本的新版本tag；旧tag不会自动拥有后来添加的脚本。test.154已使用该入口构建ZIP/MSI；test.153原资产及后补MSI保留，不用新包覆盖旧版本资产。


## 本地数据与在线边界

- 保留普通分类和原分类数据；旧隐藏标记不再隐藏作品，不提供加密书架选择，删除分类保留收藏、历史与下载。
- 「我的 → 本地漫画库」导入 CBZ/ZIP、图片或图片目录，原始文件不修改；CBR、加密/分卷/ZIP64 不支持。离线图片跨设备需显式包含下载媒体的备份。
- 已移除 PIN 隐私锁和无痕产品功能；原凭据、收藏、阅读进度、正文及下载数据不会因此删除。
- 「设置 → 缓存与存储」清理前显示范围并确认，只清非活动图片内存或本机恢复封面；正文、字体、下载和进度保留。
- 来源 HTTP 代理同时用于公开来源目录、封面、漫画图片及小说插图，维持正常 TLS 和现有超时；不自动给原生视频、Mihon APK 或 LNS 专用连接设置代理，也不复制账号 Cookie。
- MangaDex 规则 1.0.4 起可在来源设置选择低流量图片；已有规则需通过来源目录显式升级，不覆盖自改规则，已缓存/下载图片不会自动重下。
- 「我的 → 通用设置 → 版本管理与应用更新」提供当前版本卡片、发布说明和历史版本选择；仅点击时匿名检查官方 `HyperionHXH/triomi` GitHub Releases（含测试版），按实际构建号允许更高版本。下载显示真实 MiB / 百分比，可取消或手动重试；下载、暂存、核验和系统交接分开显示，下载到100%不代表安装完成。证书、哈希和完整路径折叠到技术详情，本地 APK / ZIP 核验保留在高级区。
- 资产仅允许有界跳转到 GitHub 官方 CDN，核对 GitHub SHA-256 / SHA256SUMS；Android 再核验实际包名、版本及当前安装证书，提供「稍后安装 / 立即安装」。需要权限时明确进入系统设置，返回后仍需再次确认，不自动续装；系统安装器启动只表示交接，可取消并重新读取实际版本。Windows 下载完整 ZIP 和配套清单，验证所有成员与实际 EXE 版本后打开文件位置；按页面步骤解压到新目录，退出 Triomi 后运行其中 `triomi.exe`，不覆盖运行中的程序，应用数据沿用。Windows 包未签名，哈希只证明完整性。

当前已验证产物、实际设备证据与仍待验项目统一见 [CURRENT_STATUS](docs/CURRENT_STATUS.md)，不以功能入口或构建成功代表所有平台已验收。
需要你配合的账号授权、云同步测试目录与实际手机 MixN 故障环境统一见 [USER_ASSISTANCE](docs/USER_ASSISTANCE.md)，无需发送密码或 token。

## 许可证

客户端源代码采用 GPL-3.0（见 [LICENSE](LICENSE)）。站点内容、书籍正文、插图与相关商标不因本许可证改变其权利归属。

范围冻结与下一批 GLM 工作单见 [SCOPE_FREEZE_2026-10-02.md](docs/SCOPE_FREEZE_2026-10-02.md)。
