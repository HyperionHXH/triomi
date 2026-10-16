# D88-D91 审核与 Codex 交付总结

> 历史记录：下文是该批交付时结论。后续 C99–C102 已完成真番剧正片、漫画/小说重启续读及安全升级；当前状态见 [最新验收](C99_C102_CORE_ACCEPTANCE.md)，不要按本文旧“未完成”清单重复派工。

日期：2026-10-05。GLM D88-D90 在补齐本地追番缺口后通过本批验收；Codex D91 已完成。真实来源验收 D87 部分完成，真实番剧仍未完成，不把这批 UI/存储交付当成三个软件完整聚合完成。

## 审核结果与补齐内容

| 项目 | 审核结论 | 最终处理 |
|---|---|---|
| D86 来源安装安全回归 | 环境阻塞已解除，补验通过 | asset/HTTPS、2 MiB、hash、失败重试、无半安装记录有回归 |
| D88 导航 | 通过 | 发现第一且默认；书架、追番、我的依次排列，窄/中/宽屏一致 |
| D89 阅读书架 | 类型过滤通过，追番入口不完整 | 原“去追番”误到远端账号页；Codex 改为本地持久化加入/取消及真实列表 |
| D90 测试与记录 | 当时 592 项通过，证据口径需更新 | 最终 601 项；保留历史记录，当前结果以本文件为准 |
| D91 本地追番 | 完成 | 共享物理表、按类型分业务视图，旧动画无需迁移，取消保留历史缓存，幂等加入保留进度 |
| D87 真实核心功能 | 部分完成 | 真漫画/小说已在模拟器阅读；番剧正片链路未通过 |

本地追番设计与文件清单见 [D91](D91.md) 和 [ADR](../adr/ADR-2026-10-05-discover-first-reading-library.md)。使用真数据库与真 `SchedulePage` 回归，替换仅跳占位账号页的证明。默认漫画/小说“全部标已读”不清动画未读。

Codex 同时修正 MangaDex 章节 feed 和绝对 URL，版本 1.0.2；Archive 绝对 URL 和动画馆藏筛选，版本 1.0.1。模拟器发现漫画加载滑杆越界，已添加修前红/修后绿回归并修复，最终 APK 复验真实图片、翻页和换章通过。

## 实际验证

| 命令/检查 | 结果 | 日志 |
|---|---|---|
| `flutter analyze --no-pub` | No issues found | [静态检查](evidence/D88-D91-analyze.txt) |
| `flutter test --no-pub --reporter expanded` | 601 passed | [全量 Flutter](evidence/D88-D91-flutter-tests.txt) |
| `flutter build apk --debug --no-pub` | 成功 | [构建](evidence/D88-D91-build.txt) |
| `python -m unittest discover -s tools -p 'test_*.py'` | 83 passed | [Python](evidence/D88-D91-python-tests.txt) |
| `python tools/check_text_encoding.py` + 未跟踪文本补扫 | 0 errors | [编码检查](evidence/D88-D91-encoding.txt) |
| `adb install -r` 与应用重启 | 成功，保留应用数据 | [设备结果](D87.md) |

Flutter 路径：`C:/Users/MiunaH/.workbuddy/binaries/flutter/sdk/bin/flutter.bat`；Android SDK `C:/Android/Sdk`，JDK 21。test/build 顺序执行。

手动真实网络工具不纳入默认离线全量：

- `flutter test --no-pub tools/live_catalog_probe.dart --reporter expanded`：MangaDex 通过、Archive 连接超时，见 [真实结果](evidence/D87-host-live.json)。
- `flutter test --no-pub tools/live_novel_probe.dart --reporter expanded`：LK 匿名通过、LNS unauthorized，见 [真实结果](evidence/D87-novel-live.json)。

漫画真正取得中文图片，第 76.1 话 1/15→2/15、下一章 1/14；LK 真正文 11,870 字符，模拟器显示 1/45。漫画/小说收藏在重启后共存。图片、UI 与限制详见 [D87](D87.md)。本地 debug APK 已安装模拟器，本轮没有 commit、push 或发布 Release。

## 还没有完成及分工

| 缺口 | 能否由代理继续解决 | 分工 |
|---|---|---|
| 真正 Kazumi 式番剧来源和正片播放 | 继续调查规则/动态页面/播放解析并实现；当前未完成 | Codex C99 |
| 漫画完整中文目录、清晰错误/搜索入口 | 可以，边界明确 | GLM D92、D94、D97 |
| 已安装来源版本提示与安全更新 | 可以，提示与事务更新分别实现 | GLM D93；Codex C100 |
| 公开小说阅读/重启续页/字体验证 | 可以，LK 本次匿名真实正文已通 | GLM D95；Codex C101 |
| 漫画页位置恢复、历史页码及失败不覆盖进度 | 可以，跨阅读状态需仔细实现 | Codex C102；GLM D97 先补边界回归 |
| 追番/书架持久化与备份广泛回归 | 可以 | GLM D96、D98 |
| LNS 用户会话、付费权限 | 需要用户自己的权限，目前暂缓相应真实验收 | 用户条件，不请求明文密码 |
| 物理手机硬解/声音/后台/系统差异 | 需手机，先把模拟器核心链路补齐 | 后续用户实机验收 |

下一批可整份交给 GLM：[D92-D98 工作单](../GLM_BATCH_D92_D98.md)。当前推进入口：[恢复计划补充](../CORE_FEATURE_RECOVERY_PLAN_2026-10-05_ADDENDUM.md)。继续围绕找真实内容、读/播、收藏和续读，不增加外围功能。
