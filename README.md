# Triomi

追番 · 漫画 · 小说 三位一体的聚合客户端。

> 本项目不内置任何内容源，也不存储任何内容。所有内容来自用户自行添加的来源规则，
> 软件只负责聚合、解析与呈现。请遵守各内容站点的服务条款与版权要求。

## 当前进度

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M0 脚手架** | 工程骨架、设计令牌与主题、自适应外壳、drift 表结构、Hive 设置 | ✅ 已完成（[复查记录](docs/M0_REVIEW.md)） |
| **M1 规则引擎** | 声明式规则（HTML + JSON、CSS/XPath）、来源管理、发现 / 聚合搜索 / 详情 | ✅ 声明式部分完成（[复查记录](docs/M1_REVIEW.md)）｜JS 沙箱待设备验证 |
| **M2 漫画闭环** | 阅读器四模式、书架、进度、历史 | ✅ 已完成（[复查记录](docs/M2_REVIEW.md)） |
| M3 追番闭环 | media_kit 播放器、弹幕、时间表 | ⏳ |
| M4 小说闭环 | LK / LNS 适配器移植 + 阅读器（Mixn 功能全量对齐） | ⏳ |
| M5 增强 | 下载、追踪服务、WebDAV 同步、备份导入导出 | ⏳ |

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
│  ├─ profile/                   我的
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
```

> **注意**：本机若设置了 `HTTP_PROXY` / `HTTPS_PROXY` 等代理环境变量，`flutter test`
> 会因 flutter_tester 的 WebSocket 握手失败而报
> `Invalid WebSocket upgrade request`。跑测试前先清除：
> `$env:HTTP_PROXY=''; $env:HTTPS_PROXY=''; $env:ALL_PROXY=''`

当前开发机的验证能力与限制（无 Visual Studio / Android SDK，只能跑 analyze + test）见
[`docs/M0_REVIEW.md`](docs/M0_REVIEW.md)。

## 许可证

客户端源代码采用 GPL-3.0。站点内容、书籍正文、插图与相关商标不因本许可证改变其权利归属。
