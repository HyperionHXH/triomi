# T6 · 阅读器增强 + 凭据安全迁移

> 对应规格：2.4 B4/B5（阅读器）、E3（界面字号）、G2（全标已读）、
> C1（安全存储）/ F1（登出清理）。全部可离线完成，无需账号。
> 原则：**能不加插件就不加插件**（本机 Windows 无开发者模式，含 Windows
> 平台插件的包会在 pub get 时报警告；Android 不受影响，但能免则免）。

## 一、阅读器增强

### 1. 音量键翻页（B4）
- 三个阅读器页（`manga_reader_page.dart` / `novel_reader_page.dart`）
  用 `Focus(autofocus: true, onKeyEvent:)` 监听
  `LogicalKeyboardKey.audioVolumeUp / audioVolumeDown`：
  Up=上一页（章）、Down=下一页（章）。
- 设置项：`novelReader.volumeKeyTurn`（默认**关**，防误触），
  加进阅读设置面板。
- 播放器不改（音量键留给系统音量）。

### 2. 屏幕常亮（B4）
- **零插件**：`MainActivity.kt` 的 MethodChannel（现有
  `triomi/platform`，已有 pickFontFile）加 `keepScreenOn(bool)`：
  `activity.window.addFlags/clearFlags(FLAG_KEEP_SCREEN_ON)`。
- Dart 侧 `lib/core/platform/platform_channel.dart` 加封装；
  阅读器页 initState 开启、dispose 关闭；设置项默认**开**。

### 3. 插图放大查看 + 长按保存相册（B5）
- 小说正文插图块（`novel_reader_page.dart` 的插图渲染处）与漫画页：
  点击 → 全屏查看器（`Dialog.fullscreen` + `InteractiveViewer`，
  右上角关闭按钮 + 系统返回退出）。
- 长按 → 菜单「保存到相册」：**零插件**，MethodChannel 加
  `saveImageToGallery(bytes, fileName)`，Kotlin 侧用
  `MediaStore.Images`（`RELATIVE_PATH = Pictures/Triomi`，
  Android 10+ 免权限），返回内容 URI；Dart 侧 toast 结果。
- 图片字节获取：本地路径直接读文件；网络图走
  `SourceHttpClient.fetchBytes`。

### 4. 界面字号（E3）
- 设置项 `ui.textScale`：0.85 / 1.0 / 1.15 / 1.3 四档（默认 1.0）。
- `app.dart` 的 MaterialApp `builder` 里用
  `MediaQuery(textScaler: TextScaler.linear(scale), child: ...)` 全局生效；
  「我的 → 外观与主题」页加选择（与主题设置同组，但**与阅读设置分开保存**，
  E2 已有先例）。
- 图标大小不单独做档（跟随 Material 密度），交付说明里注明为有意简化。

### 5. 全部标为已读（G2）
- `LibraryRepository.markAllRead({String? sourceId})`：
  `UPDATE library_entries SET unread_count = 0 WHERE unread_count > 0`
  （可选按来源过滤）。
- 书架页 AppBar 溢出菜单加「全部标为已读」（确认对话框；
  **只清本地未读提示，不触远端**，G2 红线）。

## 二、凭据安全迁移（C1 / F1）

### 现状（安全缺口）
- LK 会话存 Hive 明文：`lk.securityKey`（`lk_client.dart`）。
- 弹弹play 凭据存 Hive（`danmaku_settings.dart`）。
- T1 将引入 `tracking.<kind>.token`（同样是敏感键）。

### 规格
1. 依赖 `flutter_secure_storage`（Android Keystore / Windows DPAPI）。
2. `lib/core/storage/secure_store.dart`：薄封装
   `read/write/delete/deleteAll`，Android 用
   `aOptions: AndroidOptions(encryptedSharedPreferences: true)`；
   **包一层接口便于单测 fake**。
3. **一次性迁移**（app 启动时，幂等）：
   把上述旧 Hive 键逐个读出 → 写 SecureStore → 从 Hive 删除 →
   置完成标记 `secure.migrated = true`。
4. 改造读取方：`LkClient` / `DandanplayCredentials` /（T1 的 tracking token）
   改为先读 SecureStore，**保留从 Hive 的回退读**直到迁移完成。
5. **登出清理（F1）**：LK `logout()` 时——
   - 删 SecureStore 的 `lk.securityKey`；
   - 清该来源 `chapters.content_json`（可能含付费解锁正文）与相关
     `downloads` 记录里的离线索引（离线文件是否删除给确认对话框）；
   - 远端书架内存缓存清掉。
6. 备份的 `_isSensitive` 过滤已覆盖（不动）。

### 测试要求
1. 迁移幂等：跑两次结果一致；旧键被删；标记后置位跳过。
2. 迁移后 LkClient 能读到 security_key；回退路径（未迁移时读 Hive）可用。
3. 登出清理：content_json 清空、key 删除、downloads 行处理符合选项。
4. 音量键/常亮/字号/全标已读各自的最小逻辑单测
   （如 markAllRead 的 SQL 行为、TextScaler 注入）。
5. 现有测试不回归（特别是 lk/danmaku 凭据相关）。

## 验收标准

- analyze 零问题；测试全绿。
- 新增插件只有 `flutter_secure_storage`（在 pubspec 注释一行理由）。
- 凭据全文检索：除 SecureStore 与临时变量外无明文落盘。

## 后续集成点

- 本机：APK 构建验证 flutter_secure_storage 在模拟器可用（Keystore
  初始化）、全屏插图与保存相册的端到端、音量键实机确认。
