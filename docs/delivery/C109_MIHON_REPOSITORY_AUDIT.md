# C109：用户漫画 APK 仓库兼容调查

日期：2026-10-05（后续宿主验收补录至 2026-10-08）。负责人：Codex。仓库调查通过；APK 宿主已由 C110-C113 后续实现并完成首批真实扩展验收。

用户指定验收仓库：
`https://raw.githubusercontent.com/HyperionHXH/Mihon-Extensions/main/repo/index.json`

## 实际取得的证据

索引是 `name / signingKey / extensionList.extensions` 格式，不是 Triomi 的 JSON/JS 规则目录。真实索引 1,532,377 bytes，1473 个 APK 扩展、2489 个来源；82 个扩展含 zh 来源。来源 id 是64位字符串，不能转 Dart/JS double；扩展包身份与每个来源身份必须分开。

抽查 MangaDex：包 `eu.kanade.tachiyomi.extension.all.mangadex`，versionName 1.6.0，extensionLib 1.6，APK 98,014 bytes，含 `classes.dex` 与 AndroidManifest。`apksigner verify --verbose --print-certs` 通过；证书 SHA256 为 `9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`，与索引 signingKey 一致。未安装或执行这个 APK。

可复验命令：`python tools/probe_mihon_repository.py`。脚本每跳仅HTTPS，索引8MiB/APK64MiB上限，临时下载并验证签名、DEX与manifest。原始结果：[`evidence/C109-mihon-repository.json`](evidence/C109-mihon-repository.json)。数量和包版本仅代表本次网络快照，不保证仓库以后不变。

## 调查时为什么已有漫画能读，但此仓库还不能用（历史记录）

Triomi 当前在 Dart/QuickJS 执行 JSON/JS 规则；MangaDex1.0.3 是本项目 API 规则，不是仓库中 MangaDex APK。APK 含 Kotlin/JVM DEX，需要 Android source-api 宿主、网络/依赖注入/序列化/协程兼容、实例加载、异常取消与 Flutter 桥接。仅解析 index 或打开下载链接不会提供任何发现/搜索/章节/图片能力。

对照 Mihon ExtensionLoader 和实际 source-api：1.4 与1.6 ABI需要区别处理，SourceFactory与单Source要展开成稳定来源；1.6 使用 suspend 方法和新增模型字段。`keiyoushi/extensions-lib` 为插件编译 stub，方法会 throw `Stub!`，不能当成现成可执行宿主。

参考：

- https://github.com/mihonapp/mihon/blob/main/app/src/main/java/eu/kanade/tachiyomi/extension/util/ExtensionLoader.kt
- https://github.com/mihonapp/mihon/tree/main/source-api
- https://github.com/keiyoushi/extensions-lib/blob/main/library/api/library.api

GNOME Komikku 的 Python server 生态与该 APK 生态不同。本项目原规范参考 GNOME UI；用户此轮提供仓库后，验收目标明确补充为 Android Mihon/Tachiyomi APK 兼容，而不是把GNOME解析器当APK执行。

## 后续实现门槛与当前结果（不交 GLM 拼运行时）

| 顺序 | 实现 | 完成门槛 |
|---|---|---|
| C110 | Android宿主与ABI契约，先支持仓库实际1.6 MangaDex包 | 已完成首批真实实例化与 discover/search/detail/chapters/content；不能退回项目内JS规则冒充 |
| C111 | APK验证安装与更新事务 | 已完成受限下载、签名/包名/version/DEX 校验、私有 staging、不可变失败更新和旧版保留 |
| C112 | 原生来源接入Flutter完整流程 | 已完成仓库→安装→来源注册→中文搜索→目录→真实图片阅读；Flutter loopback 图片桥接插件请求头/cookie |
| C113 | 覆盖1.4/中文来源、故障与更新验收 | MangaDex 1.6、十八漫画 1.6、拷贝漫画 1.4 已验收；不把2489来源标成全量通过 |

对现有JsSource与来源安全升级采用并行来源类型，不重写已有闭环。仓库管理、筛选/排序与大量parser用例可由GLM处理，但须先明确宿主契约；未完成C112前不提供可误认为已支持的「安装」按钮。Windows仍走JS来源，本轮不承诺Windows直接运行Android DEX。

## 本轮实现边界（2026-10-05）

已新增 `lib/core/source/mihon_repository.dart` 和来源页的 Mihon/Komikku 扩展管理入口。当前用户可以添加或刷新 HTTPS 仓库索引，按中文来源、内容类型、扩展名或来源名筛选，查看包名/版本/`extensionLib`/来源列表并下载 APK 到应用私有目录，同时保存独立的启用偏好。

下载卡片只在宿主 inspect 返回 `executable=true` 后显示可用来源，不写入普通规则 `SourceRepository`。首次安装保持停用；如果包已有启用偏好，更新成功后会同步 native 启用状态。真实 APK 的 DEX 加载、签名信任、source-api ABI 和 Flutter 内容桥接已由 C110-C113 完成；GLM 不得把索引或下载测试单独写成宿主验收。

这些是开发工作，当前不需要用户手机或账号来解除，不能列成「外部条件暂缓」。已决定的边界见 [ADR](../adr/ADR-2026-10-05-category-grid-and-apk-boundary.md)。
