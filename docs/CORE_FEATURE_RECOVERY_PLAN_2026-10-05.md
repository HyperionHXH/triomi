# Triomi 核心功能恢复规划（2026-10-05）

> 2026-10-05 后续：Codex 四项核心验收已通过，见 [C99–C102](delivery/C99_C102_CORE_ACCEPTANCE.md)。本文是历史恢复规划，当前派工以补充大纲为准。

> 最新进度见 [补充大纲](CORE_FEATURE_RECOVERY_PLAN_2026-10-05_ADDENDUM.md) 和 [D87](delivery/D87.md)。本文保留最初恢复阶段记录：Flutter/AVD 不可用、无生产漫画来源等描述已过时；现在已有可安装的 MangaDex 1.0.2、在线模拟器与真实漫画/轻之国度内容证据。Internet Archive 只是动画馆藏来源，不能统称公版或充当最新番剧播放验收。

## 触发原因

当前测试版不能满足核心使用路径：发现页没有可用的番剧列表，Bangumi 只能返回资料/集数元数据；播放测试使用的是本地夹具，不是真实番剧。漫画虽然已有规则引擎、详情、章节、书架和阅读器，但生产包没有默认漫画来源，来源页也没有 Komikku 式插件仓库，用户只能手工粘贴 JSON 或 URL。

本轮目标是先恢复三条可验证闭环，再处理次要问题：

1. 来源目录 → 安装/启用 → 番剧发现 → 详情/集数 → 合法播放线路。
2. 来源目录 → 安装/启用 → 漫画发现/搜索 → 详情/章节 → 阅读与离线缓存。
3. Android 模拟器上可重复执行的 smoke 证据。夹具只能证明产品链路，不能被称为真实番剧或真实漫画。

## 事实边界

- `assets/rules/bangumi-anime.json` 目前只有 `search`、`detail`，没有 `discover` 和 `content.playSources`；它继续作为元数据/追踪源。
- `assets/rules/local-fixture-anime.json` 配合 `tools/dev_fixture_server.py` 才有发现、详情、章节和播放；仅用于 debug/验收。
- 漫画规则引擎已经支持 discover/search/detail/content，但没有生产内置漫画规则或仓库目录。
- 不从 Bangumi 推导播放地址，不伪造版权站地址，不把夹具视频写成真实内容。真实播放源必须是合法公开 provider、用户自有 URL 或明确授权的仓库条目，并在模拟器联网测试中得到证据。
- 本机 Flutter 命令当前不可用；Android SDK 在 `C:\Android\Sdk`，AVD 有 `triomi_api35_clean`、`noval_api35`、`triomi_dev2`，但当前 `adb devices` 为空。没有启动 AVD 前不得声称完成模拟器验收。

## 批次与分工

| 批次 | 工作 | 负责人 | 交付/门槛 |
|---|---|---|---|
| D75 | 核心能力矩阵、生产/夹具边界、回归测试入口 | GLM | 矩阵和扫描测试；不得把 fixture 标真实内容 |
| D76 | 插件仓库索引协议：`id/name/type/version/url/hash/capabilities/license/updatedAt`，解析、重复项和版本比较 | GLM | parser/repository 单测全绿 |
| D77 | 来源仓库浏览 UI：按 anime/manga 分组，预览、能力标签、安装/启用/删除、更新失败可见 | GLM | widget 测试；保留手工 URL/JSON 导入 |
| D78 | 漫画 debug 规则与模拟器闭环：发现/搜索→详情→章节→阅读/缓存 | GLM | fixture server + 契约测试；不能扩展 OCR/账号 |
| D79 | 番剧 provider 选型与规则契约：Bangumi 资料源与可播放源分离，播放能力缺失时明确提示 | Codex | ADR/规则 schema/错误状态；不得添加未经授权地址 |
| D80 | 番剧播放闭环：真实合法 provider 或用户配置 URL 的 `content.playSources`、线路探测、HLS/MP4 错误诊断与安全下载 | Codex | 先用 fixture 验证，再用合法源证据；无证据则标记 blocked |
| D81 | Android 模拟器 smoke：启动 AVD、安装 debug APK、启动 fixture server，保存列表/详情/阅读/播放证据 | Codex | `adb` 日志、截图/像素或录屏路径可复现 |
| D82 | 插件下载安全：HTTPS、hash 校验、大小限制、版本冲突、回滚和安装失败恢复 | Codex | 单元/集成测试；禁止静默覆盖 |
| D83 | GLM 收口：来源/发现空态、类型过滤、中文 UTF-8、widget 回归和文档链接 | GLM | analyze/test 通过，乱码扫描通过 |
| D84 | 批次审核与发布门槛 | Codex | 更新总结；未满足的真实源/实机项列为未完成，不发布虚假能力 |
| D85 | 目录接线与真实来源首批 | Codex | 来源页可打开内置目录；MangaDex 漫画规则、Internet Archive 公版动画规则可安装；Bangumi 继续标为资料源 |
| D86 | 目录安装安全与回归 | GLM | 为 asset/HTTPS 安装补 widget/单测，覆盖大小、哈希、协议拒绝、失败可见；不得把网络未验证写成通过 |
| D87 | 模拟器 smoke 与真实网络验证 | Codex | AVD 安装 debug APK；验证目录、漫画列表/阅读、动画列表/详情/播放线路；保存日志；设备/网络失败要记录 |

## GLM 一次性工作单（D75、D76、D77、D78、D83）

请按顺序完成并在每项后更新 `docs/delivery/D75.md` 等文件：

1. 增加来源目录 JSON schema、解析模型、版本/重复项/hash 字段校验和单元测试；索引既支持本地 asset，也为 HTTPS raw JSON 预留同一格式。
2. 在 `SourceRegistry`/repository 增加 catalog 条目读取、预览、安装、启用、删除和更新所需的最小 API；保留现有单规则导入，不改动 Bangumi 的资料语义。
3. 改造 `SourcesPage`，提供 Komikku 式来源目录入口，按 anime/manga 分组显示能力、许可证、版本和健康状态；安装/更新中、失败、重复和回滚提示必须可见。
4. 增加漫画 debug 规则的 discover/search/detail/content 契约测试，覆盖列表→详情→章节→阅读/离线缓存；不得引入受版权保护的站点内容。
5. 为 `DiscoverPage` 和来源页增加无来源、仅资料源、无播放能力、多来源切换的 widget 测试；修复中文文件/终端输出为 UTF-8，运行已有编码扫描。
6. 每项完成后运行相关 Dart tests/analyze，并把命令、结果、未完成原因写入 delivery 文档。不要删除失败断言或把真实测试改成 skip。

## Codex 自负责的复杂工作

- 决定并记录合法番剧 provider 策略；Bangumi 只做资料，播放源必须显式声明 `content.playSources`。
- 审核仓库协议的安全边界、hash/版本/回滚和动态 JS 规则风险。
- 启动 Android AVD，执行 fixture smoke，保存可复查证据；若本机缺 Flutter SDK 或网络/授权条件，记录为环境阻塞。
- 实现或修复播放线路解析、可用性探测、HLS/MP4 错误诊断等需要跨模块推理的部分。

## 模拟器验收命令

```powershell
$sdk='C:\Android\Sdk'
Start-Process "$sdk\emulator\emulator.exe" -ArgumentList '-avd','triomi_api35_clean','-no-snapshot','-no-boot-anim'
& "$sdk\platform-tools\adb.exe" wait-for-device
& "$sdk\platform-tools\adb.exe" shell getprop sys.boot_completed
& "$sdk\platform-tools\adb.exe" install -r build\app\outputs\flutter-apk\app-debug.apk
python tools/dev_fixture_server.py
```

验收顺序固定为：来源目录/启用 → 番剧或漫画列表 → 详情 → 章节 → 播放或阅读 → 返回与缓存。每一步保存 logcat 和截图；fixture 通过不等于真实源通过。

## 当前状态（D85 完成后）

- 来源页已经接入“浏览来源目录”入口，应用启动时加载 `assets/catalog/index.json`。
- 目录含 MangaDex 漫画开放 API 规则与 Internet Archive 公版动画规则，安装后进入来源列表；规则实际请求真实 HTTPS API。
- MangaDex 规则实现发现、搜索、详情、章节和 `/at-home/server` 图片正文；授权与可用性仍取决于 MangaDex 服务和条目本身。
- Internet Archive 规则实现动画馆藏发现、搜索、详情、MP4 文件章节和显式播放线路；只选择存在 MP4 文件的条目，不能保证每个馆藏都有可播放文件。
- 安装侧已实现 asset 路径、HTTPS 限制、2 MiB 大小限制和可选 SHA-256 校验。

## 当前未完成项

- 来源版本更新、冲突检测和回滚：目录安装已接通，但版本比较/回滚 UI 仍未完成。
- Internet Archive/MangaDex 的真实网络端到端验证：规则已写入包，尚未在 Android AVD 上验证。
- Android 模拟器自动化/CI job：未完成，本机当前没有在线 adb 设备。
- 本轮实际启动 `triomi_api35_clean` 并安装 APK 成功；首屏无崩溃，但该模拟器网络未连接，真实来源请求仍待网络可用时复验。
- 真实站点稳定性、账号、版权授权和物理设备验收：外部条件，不能由代码测试伪造。

## 完成定义

D75-D84 只有在 fixture 模拟器闭环、目录安装流程、来源能力提示和测试证据全部具备后才算完成。若没有合法真实番剧 provider，产品文案必须明确“Bangumi 为资料源，无播放地址”，发布记录不得宣称番剧播放已完成。
