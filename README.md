# Triomi

开发进度与最新批次：[GLM D47-D58](docs/GLM_BATCH_D47_D58.md)（交付汇总见 [BATCH_D47_D58_SUMMARY](docs/delivery/BATCH_D47_D58_SUMMARY.md)）。前台 TTS（含语速/音色设置、生命周期防护）已实现并通过 Android debug 构建，**真实语音验收待设备**；导出/备份的 SAF 写入返回系统真实位置并显式提示保存目录；JS 同步强隔离（ADR 001）与备份崩溃恢复尚未完成（Codex D59/D60）。

追番 · 漫画 · 小说 三位一体的聚合客户端。

> 本项目不内置任何内容源，也不存储任何内容。所有内容来自用户自行添加的来源规则，
> 软件只负责聚合、解析与呈现。请遵守各内容站点的服务条款与版权要求。

## 当前进度

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M0 脚手架** | 工程骨架、设计令牌与主题、自适应外壳、drift 表结构、Hive 设置 | ✅ 已完成（[复查记录](docs/M0_REVIEW.md)） |
| **M1 规则引擎** | 声明式规则（HTML + JSON、CSS/XPath）、JS 沙箱（flutter_js）、来源管理、发现 / 聚合搜索 / 详情 | ✅ 已完成（[复查记录](docs/M1_REVIEW.md)、[T2 交接](docs/handoff/T2-js-sandbox.md)）｜真实 quickjs 在 Android/桌面可用，缺动态库时相关用例按既有机制报告不可用 |
| **M2 漫画闭环** | 阅读器四模式、书架、进度、历史 | ✅ 已完成（[复查记录](docs/M2_REVIEW.md)） |
| **M3 追番闭环** | media_kit 播放器、弹幕层、Bangumi 放送表、模拟器端到端验证 | ✅ 已完成（[复查记录](docs/M3_REVIEW.md)） |
| **M4 小说闭环** | 小说阅读器（分页/滚动）、轻之国度 / 轻书架内置适配器、付费章节解锁、EPUB/TXT 导出、字体管理、繁简转换、远端书架、评论与消息中心 | ✅ 已完成（[复查记录](docs/M4_REVIEW.md)）｜真实账号联调已跑通 |
| **M5 增强** | 下载管理（小说/漫画/番剧视频，离线可读可播）、备份导出导入、WebDAV 双设备同步、弹幕（渲染 + 发送 + 凭据）、Bangumi/AniList 追踪 | ✅ 已完成（[复查记录](docs/M5_REVIEW.md)）｜追踪写链路已用真实 token 验证；弹幕发送链路夹具设备验证通过，**弹弹play 真实凭据仍在官方审核**（当前线上返回 Invalid AppId，见 handoff/README） |

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
│  ├─ library/                   书架（页面 + 数据层：仓储、provider）
│  ├─ history/                   阅读历史
│  ├─ discover/                  分站榜单 + 作品卡片组件
│  ├─ search/                    聚合搜索（逐来源成败）
│  ├─ detail/                    详情 + 目录
│  ├─ reader/                    漫画阅读器（四模式）与阅读设置
│  ├─ sources/                   来源与规则管理
│  ├─ schedule/                  追番
│  ├─ downloads/                 下载管理（队列、离线内容、仅 WiFi）
│  ├─ player/                    media_kit 播放器、弹幕层与弹幕设置
│  ├─ novel/                     小说（阅读器 / LK 适配器 / 导出 / 字体 / TTS）
│  ├─ profile/                   我的（备份与恢复、云同步、下载管理入口）
│  └─ settings/                  设置（外观分组已可用）
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
- JDK 17、Android SDK 35（构建 Android 端时需要）
- Visual Studio 2022「使用 C++ 的桌面开发」工作负载（构建 Windows 端时需要）

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

> **注意**：本机若设置了 `HTTP_PROXY` / `HTTPS_PROXY` 等代理环境变量，`flutter test`
> 会因 flutter_tester 的 WebSocket 握手失败而报
> `Invalid WebSocket upgrade request`。跑测试前先清除：
> `$env:HTTP_PROXY=''; $env:HTTPS_PROXY=''; $env:ALL_PROXY=''`

当前开发机已配置 Android SDK：debug APK 可构建，API 35 x86_64 模拟器完成了
播放器动态帧、追踪、WebDAV、SAF/字体等端到端验证（见
[`docs/CHECKPOINT_2026-10-01.md`](docs/CHECKPOINT_2026-10-01.md)）；Windows 桌面构建在本机未验证。
M0 时代的「无 VS / Android SDK」限制见 [`docs/M0_REVIEW.md`](docs/M0_REVIEW.md)（历史记录）。

## 免责声明

- 本项目是**内容聚合客户端**：不提供、不存储、不分发任何内容；所有内容都来自用户
  自行添加的来源规则所指向的第三方站点。
- 请仅用于个人学习、备份与自用，并遵守所在地法律法规与各内容站点的服务条款；
  由此产生的一切后果由使用者自行承担。
- 弹幕能力对接 **弹弹play 开放弹幕网络**：使用时需自行申请应用并遵守其开发者协议，
  展示其数据时须保留完整来源标注（「弹弹play」/「弹弹play开放弹幕网络」）。
- 番剧元数据、放送表与追番进度来自 **Bangumi**、**AniList**，相关版权归各站点所有；
  个人访问令牌只保存在本机（系统安全存储），不写日志、不随备份导出。
- 仓库内置的「夹具来源」与示例规则只指向本地调试服务，不含任何真实站点内容。

## 持续集成

`.github/workflows/build.yml` 在 push / PR / 手动触发时跑四件事：

1. `flutter analyze` + `flutter test`（零问题、全绿是硬门槛）；
2. Python 工具链（`tools/requirements-dev.txt`：tools 单测、夹具媒体自检、文档漂移扫描）；
3. Android release APK；
4. Windows 绿色包（zip）。

产物在 Actions 页面对应 run 的 Artifacts 中下载。Android 包用的是 Flutter 模板默认的
debug 签名（仓库不含密钥），仅供自用安装；要发布请自行配置 keystore。

## 许可证

客户端源代码采用 GPL-3.0（见 [LICENSE](LICENSE)）。站点内容、书籍正文、插图与相关商标不因本许可证改变其权利归属。

范围冻结与下一批 GLM 工作单见 [SCOPE_FREEZE_2026-10-02.md](docs/SCOPE_FREEZE_2026-10-02.md)。
