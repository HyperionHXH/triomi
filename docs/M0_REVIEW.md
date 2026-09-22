# M0 复查记录

日期：2026-09-22 ｜ 对应任务：T1（M0 脚手架）｜ 提交：`chore(M0): 工程骨架、设计令牌与主题、自适应外壳、数据库表结构`

## 1. 验收结果

| 检查项 | 命令 | 结果 |
|---|---|---|
| 静态分析 | `flutter analyze` | **No issues found**（启用 strict-casts / strict-inference / strict-raw-types，unused_import 与 dead_code 按 error 处理） |
| 单元 + 组件测试 | `flutter test` | **5 passed**（主题装配 ×2、断点分类 ×1、窄屏外壳切换 ×1、宽屏侧边栏 ×1） |
| 代码格式化 | `dart format .` | 21 文件，0 变更 |
| drift 代码生成 | `dart run build_runner build` | `lib/core/db/app_database.g.dart` 生成成功 |

## 2. 环境说明（重要，影响后续验证方式）

| 项 | 状态 | 影响 |
|---|---|---|
| Flutter SDK | 3.47.5 stable / Dart 3.13.4，位于 `C:\Users\MiunaH\.workbuddy\binaries\flutter\sdk` | 路径未加入系统 PATH，命令需用绝对路径调用 |
| Visual Studio | **未安装** | 无法构建 / 运行 Windows 桌面端（`flutter run -d windows` 不可用） |
| Android SDK | **未安装** | 无法构建 APK，无法真机验证 |
| 结论 | —— | 当前只能做 `flutter analyze` + `flutter test`（Dart VM，纯逻辑与 Widget 级验证）；**首次出现「必须真机/真窗体验证」的里程碑是 M2（阅读器手感）与 M3（播放器）**，届时需要先补齐工具链 |

**测试运行的坑**：本机存在 `HTTP_PROXY / HTTPS_PROXY` 等代理环境变量，会让 `flutter_tester`
的 WebSocket 握手失败，报 `Unable to connect to flutter_tester process: Invalid WebSocket upgrade request`。
跑测试前必须先清除：

```powershell
$env:HTTP_PROXY=''; $env:HTTPS_PROXY=''; $env:ALL_PROXY=''
flutter test
```

**另外两个环境陷阱**（避免后续误踩）：

1. `flutter devices` 会去执行 `reg query HKEY_CURRENT_USER\Software\Microsoft\Edge\...`，
   该程序被本机安全策略拉黑而直接失败。**不要用 `flutter devices` 列设备**，构建时用
   `flutter build web` / `flutter build apk` 指定目标即可。
2. 浏览器自动化工具（agent-browser）需要 `npm install -g`，而本机 npm 会拉起被拉黑的
   `wsl.exe`，因此**无法在本机做自动截图**。视觉验证走下面的 Web 预览通道由人眼确认。

## 2.1 视觉预览通道（绕过桌面/安卓工具链缺失）

M0 的 UI 可以直接用 Web 构建查看，这是当前唯一能真实看到界面的方式：

```powershell
flutter build web --release
cd build/web
python -m http.server 8080 --bind 127.0.0.1
# 浏览器打开 http://127.0.0.1:8080
```

- 把窗口拉宽到 1240px 以上：应看到桌面版 Sidebar + 内容区（Komikku 布局）
- 缩到 600~1240px：NavigationRail 侧栏
- 缩到 600px 以下：底部 NavigationBar

断点切换逻辑已由 Widget 测试覆盖（窄屏出现 NavigationBar、宽屏出现侧边栏），
但**配色与配图的观感需要人眼确认**——本机无法自动截图，M0 的视觉验收请通过上面的预览通道完成。
这是本里程碑唯一未闭环的验收项。

## 3. 复查中发现并已修复的问题

| # | 问题 | 级别 | 处理 |
|---|---|---|---|
| 1 | `overrides: <Override>[...]` 在 Riverpod 3.4 下编译失败（`Override` 不再作为公开类型导出） | 错误 | 改为类型推断的列表字面量 |
| 2 | `if (bottom != null) bottom!` 触发 `use_null_aware_elements` | 提示 | 改用 Dart 3 空安全元素 `?bottom` |
| 3 | 外壳把私有类型 `_ShellDestination` 暴露在公开 API（`static const destinations`） | 提示 | 改为私有 `_destinations` |
| 4 | 侧边栏宽度 `232`、导航栏高度 `64` 硬编码，违反「尺寸不硬编码」约定 | 自查发现 | 提取为 `AppSpacing.sidebarWidth` / `AppSpacing.navigationBarHeight` |
| 5 | 字号档位中文标签在 controller 与 page 各写一份 | 自查发现 | 收敛为 `AppearanceSettings.labelForScale()` 单一实现 |

## 4. 已知限制 / 留给后续里程碑

- `settings_page.dart` 中版本号 `0.1.0 · M0` 为硬编码字符串，M5 接入 `package_info_plus` 后改读真实版本。
- `AppDatabase` 只有 `schemaVersion = 1` 与 `onCreate`，**没有 migration**。M2 首次改表结构前必须补 `onUpgrade`，否则用户数据会丢。
- 深色主题的对比度尚未做视觉回归（无桌面构建环境），M2 前需要至少一次截图核对。
- 未添加 LICENSE 文件与 CI（属 T8）。
- `databaseProvider` 尚未被任何页面使用（M0 只建结构），意味着 drift 的建表路径**还未经过运行时验证**——T2 接入来源表读写时是第一次真实验证。

## 5. 下一步（T2）入口

T2 目标：`MediaItem / Chapter / TrackEntry` 模型 + `SourceEngine`（flutter_js 沙箱 + XPath 简式层）+ 来源管理页。

开工前需要先确认两件事：
1. JS 引擎选型落地包（`flutter_js` 在 Windows/Android 的可用性需实测，备选 `flutter_js_widget` / `quickjs_dart`）；
2. 首批示例源站点（1 漫画 + 1 番剧），用于跑通「搜索 → 详情 → 章节列表」。
