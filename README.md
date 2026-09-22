# Triomi

追番 · 漫画 · 小说 三位一体的聚合客户端。

> 本项目不内置任何内容源，也不存储任何内容。所有内容来自用户自行添加的来源规则，
> 软件只负责聚合、解析与呈现。请遵守各内容站点的服务条款与版权要求。

## 当前进度

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M0 脚手架** | 工程骨架、设计令牌与主题、自适应外壳、drift 表结构、Hive 设置 | ✅ 进行中 |
| M1 规则引擎 | JS 沙箱 + XPath 简式层、来源管理、发现 / 搜索 / 详情 | ⏳ |
| M2 漫画闭环 | 阅读器（四模式）、书架、进度、历史 | ⏳ |
| M3 追番闭环 | media_kit 播放器、弹幕、时间表 | ⏳ |
| M4 小说闭环 | LK / LNS 适配器移植 + 阅读器（Mixn 功能全量对齐） | ⏳ |
| M5 增强 | 下载、追踪服务、WebDAV 同步、备份导入导出 | ⏳ |

完整需求、方案与任务拆解见 [`docs/PROJECT_SPEC.md`](docs/PROJECT_SPEC.md)。

## 目录结构

```
lib/
├─ main.dart                     应用入口（Hive 初始化 + ProviderScope）
├─ app.dart                      MaterialApp.router、主题与本地化装配
├─ core/
│  ├─ theme/
│  │  ├─ app_tokens.dart         设计令牌：间距、圆角、字号、断点、色板
│  │  └─ app_theme.dart          ThemeData 装配（复刻 libadwaita 观感）
│  ├─ router/app_router.dart     go_router 路由表
│  ├─ db/
│  │  ├─ tables.dart             drift 表定义
│  │  └─ app_database.dart       数据库（schemaVersion 1）
│  ├─ models/media_type.dart     内容形态、来源类型、来源错误分类
│  ├─ storage/preferences.dart   Hive 设置存储
│  └─ widgets/                   通用组件：AppCard / SettingsGroup / EmptyStateView
└─ features/
   ├─ shell/adaptive_shell.dart  三档自适应导航壳
   ├─ library/                   书架
   ├─ discover/                  发现
   ├─ schedule/                  追番
   ├─ profile/                   我的
   └─ settings/                  设置（外观分组已可用）
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

## 环境与构建

- Flutter stable（Dart 3.x）
- JDK 17、Android SDK 35（构建 Android 端时需要）
- Visual Studio 2022「使用 C++ 的桌面开发」工作负载（构建 Windows 端时需要）

```powershell
cd triomi
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # 生成 drift 代码
flutter run -d windows        # 或 -d android
flutter analyze
dart format .
```

## 许可证

客户端源代码采用 GPL-3.0。站点内容、书籍正文、插图与相关商标不因本许可证改变其权利归属。
