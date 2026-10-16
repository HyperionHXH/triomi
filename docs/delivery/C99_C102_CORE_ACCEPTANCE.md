# 四项核心功能验收与审核（2026-10-05）

负责人：Codex。本轮先完成 C99–C102，再恢复 GLM 工作；没有把计划、离线夹具或站点错误短片算作真实内容验收。

## 结果

| 任务 | 实际验收 | 结论 |
|---|---|---|
| C99 真番剧获取与正片 | AGE 最新列表、中文搜索、芙莉莲第一季目录 6 条线路共 168 项；线路 2 第 08 集 HLS 正片 24:49，画面、连续进度、拖动跳转及活动音轨 | Android 模拟器通过 |
| C102 漫画原章原页 | MangaDex 真实作品《Kage no Jitsuryokusha ni Naritakute!》76.2 话第 8/14 页，强制结束应用再打开，详情“继续阅读”恢复同章同页同图 | 通过 |
| C101 小说重启续页 | LK 公开小说 33139 第一话，正文 11,870 字符、本机排版 45 页；第 7/45 页强制结束应用再打开，正文开头与页码相同 | 通过 |
| C100 来源安全升级 | 在最终播放构建中从目录将实际安装的 AGE 1.0.0 升为 1.0.1，启用状态、来源 id、漫画和小说历史保留；失败与冲突用真实 SQLite 回归验证 | 通过 |

验收环境：Windows 宿主，Android API 35 `emulator-5554`，1080×2400，Flutter debug APK，应用 `io.github.hyperionhxh.triomi`。使用 `adb install -r`；没有清数据、伪造来源版本、修改用户数据库或账号。验收后已恢复系统输入法。

## C99：来源、解析与真实播放

参考 `_refs/kazumi-rules/AGE.json` 的 `useWebview/useNativePlayer` 和 Kazumi 的 headless WebView 播放解析实现，独立编写 Triomi JS 规则。规则负责列表/搜索/目录/iframe；Android resolver 执行播放页的正常 JS/WASM，观察真实媒体请求并保留实际 UA、Referer、Origin、Cookie。不是把 HTML 里的任意链接当直链，也没有关闭 TLS 校验或绕过账号门槛。方案见 [ADR](../adr/ADR-2026-10-05-core-playback-resume-upgrade.md)。

真实正片地址：`https://vip.ffzy-plays.com/20231027/18759_d592f7dc/index.m3u8`。原生日志显示 `duration=1489575`、`playing=true`，连续 position 增长；截图可辨认芙莉莲画面、字幕与正常画面比例。拖动后已有 13:27/24:49 的不同画面。

- [真实列表/搜索/目录 probe](evidence/C103-age-live.json)：20 个列表结果、搜索 2 项、目录 168 项；这是联网探测，不是播放证据。
- [真实目录](evidence/C103-frieren-directory.png)。
- [最终规则的正片画面](evidence/C103-final-frieren-playing.png)；[连续播放日志](evidence/C103-final-native-playback.log)。
- [拖动后画面](evidence/C103-frieren-seek.png)。
- [音轨证据](evidence/C103-final-audio-track.txt)：应用 PID 10915，活动 PCM 16-bit、44.1 kHz、双声道音轨，`InternalMute=false`。这是系统输出证据；未声称已由人耳检查手机扬声器。
- [失效线路与换线入口](evidence/C103-final-unavailable-line.png)。从该入口选择线路 2 第 08 集后取得上述正片。

线路 1 曾返回 3 秒的“视频加载失败”占位 MP4。AGE 1.0.1 通过 `unavailableVideoUrls` 声明这个确定的错误卡地址，通用 resolver 拒绝它并提示换线。没有按“短视频”或整个 CDN 一刀切。此前错误卡截图 `C103-frieren-playing-before.png` 是失败证据，不能当通过证据。

## C102 / C101：恢复位置

漫画历史用 source/item/chapter 的复合身份读取零基图片页；异步加载使用序列号，旧响应不能覆盖新章，恢复期间不写进度。换章与退出保存捕获的章/页，失败或零图片不覆盖历史。分页与条漫共享“图片序号”契约；条漫恢复原图片，不承诺图片内部像素偏移。

真实作品 id `77bee52c-d2d6-44ad-a33a-1734c1fe696a`，76.2 话 14 页。对照：[退出前第 8 页](evidence/C104-manga-before-restart.png) / [强制重启后第 8 页](evidence/C104-manga-after-restart.png)。

review 修复并重新构建后，以 `install -r` 更新 APK，强制结束再打开，仍恢复 76.2 话第 8/14 页：[最终构建复验](evidence/C104-reviewed-build-restored.png)。

小说保存 block index + 段内字符比例，分页元素保留 UTF-16 offset，长段跨多页不会只恢复段首；旧整数位置继续兼容。排版变化定位同一正文锚点，页码可能改变，不能承诺跨字体/屏幕还保持相同数字页码。本地保存串行且翻页即时写入，远端同步不能阻塞本地队列；空白正文报错并保留历史。

真实 LK 作品《只有颜值是优点的同学，以猛烈攻势向我扑来的百合故事。》，id `33139`，22 章。对照：[退出前第 7/45 页](evidence/C105-novel-before-restart.png) / [强制重启后第 7/45 页](evidence/C105-novel-after-restart.png)。正文均从“疏远：仅此而已。”及后续同一句继续。

review 后的同一最终 APK 再次经强制重启，从书架详情“继续阅读”进入，仍为同一正文及第 7/45 页：[最终构建复验](evidence/C105-reviewed-build-restored.png)。

`reader_restart_test.dart` 使用真实 SQLite 和真实阅读器，验证漫画/小说 destroy→remount、长段多页文字锚点、漫画加载失败及小说空白正文不覆盖历史。离线测试与上述真实设备证据分别记录。

## C100：安全升级和数据保留

预览显示已装版本与可更新版本；必须是更高的有效 SemVer。远程下载每次发请求前校验 HTTPS、host、无账号信息，最多 5 次重定向，禁止中间 HTTP 降级；按原始 bytes 校验可选 SHA-256、严格 UTF-8、声明长度及流式累计 2 MiB 上限。目录与规则 id/type/version 必须一致，能力与真实 JS 初始化结果一致。验证后只做一次 CAS 事务替换；下载期间被编辑/禁用/移除则拒绝旧请求覆盖。失败发生在写入前，无需先卸载旧来源或新增回滚表。

- [设备升级预览：1.0.0→1.0.1](evidence/C106-final-upgrade-preview.png)。
- [设备升级后：已安装 1.0.1](evidence/C106-final-upgraded.png)。
- [只读数据库复核](evidence/C106-upgrade-data-check.json)：AGE id/version/enabled、漫画第 8 页和小说锚点、收藏仍在。
- `catalog_update_test.dart`：版本、hash、超限、JSON/JS 失败、能力/身份不符、并发编辑/删除；每类失败断言原来源与真实收藏/历史不变。
- `rule_download_security_test.dart`：Dio 重定向实际请求记录证明没有向 HTTP 降级目标发送请求。
- `source_catalog_page_test.dart`：更新成功及失败提示，禁用状态保持，失败可重试。

本轮“安全升级”的完成范围是下载验证与事务数据保护。可选 hash 不等于发布者签名，运行前语法/能力检查不等于恶意 JS 的可终止沙箱；任意同步死循环隔离仍见 [ADR 001](../adr/001-js-execution-isolation.md)，由 Codex 后续负责，不能宣传任意第三方脚本完全安全。

## 最终检查与后续边界

`flutter analyze --no-pub`：No issues；`flutter test --no-pub`：622 项通过；Android debug APK 构建成功。Python 83 项通过；UTF-8 检查同时覆盖 tracked 与未跟踪文件，0 errors。命令与日志见 `evidence/C99-C102-*`。

最终验收 APK：`build/app/outputs/flutter-apk/app-debug.apk`，SHA-256：`B4A7BEB91BC0FD8F31B64203F57F57B09E5BF7D6D2B2C9B12844DF560FE42F1D`。此构建已安装到上述模拟器；后续重新构建时应记录新 hash，不能沿用本轮身份。

仅需人的事项：手机扬声器/硬解/系统权限与厂商差异；LNS 登录后接口、字体及付费权限需用户自己的会话。LK 公开正文已实测，不把所有小说统一暂缓。当前 AGE 动态网页解析验收限 Android，桌面仍可用已有直链来源，不宣称桌面 AGE 通过。站点线路可能变化，需要维护规则或换线。

仍可继续实现的缺口：MangaDex 完整中文目录分页、外站托管章节的明确错误、资料源/空目录的搜索入口、小说账号引导和广泛持久化回归。没有把这些扩充项再当作四项核心未完成；也没有声称复制了 Komikku APK 扩展生态或 Mixn 全量账号功能。

四项完成后下一批见 [GLM D92–D98](../GLM_BATCH_D92_D98.md)，D93 已由本轮吸收，禁止重复实现。没有自动 commit、push 或发布 Release。
