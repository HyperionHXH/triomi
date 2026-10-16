# C107–C108：发现界面与真实中文漫画验收

日期：2026-10-05。负责人：Codex。真实漫画阅读闭环通过；Mihon APK 插件执行尚未实现，不能以本验收替代插件兼容验收。

## 用户反馈与修复

发现按钮原先使用固定高度，字号放大后文字可能裁切。现在 chip 由内容决定高度，点击区至少 48dp，横向可滚动。发现的番剧/漫画/小说分开，不再提供「全部」。推荐使用封面网格，正常手机三列、极窄屏两列、宽屏自适应，标题两行且来源信息独立；不再跟随书架的竖排设置。

参考依据是本机 Kazumi 源码 `_refs/kazumi/lib/pages/popular/popular_page.dart` 的手机三列布局。本轮 Windows 原生窗口控制连接未成功，因此没有声称实际观察过 Kazumi 运行窗口。发现截图为 Triomi 实际模拟器。

书架共用同一收藏库，但只显示当前选中类别，默认漫画；保留小说与「番剧（旧）」兼容入口，去掉「全部」。数据库、旧收藏与历史不搬迁。新的决定见 [ADR](../adr/ADR-2026-10-05-category-grid-and-apk-boundary.md)。

新安装默认播种真实 AGE 与 MangaDex；夹具需 debug 加显式 `TRIOMI_DEV_FIXTURES=true` 开关。旧夹具记录可保留管理，但默认不参与可用来源。默认选择优先有 discover 能力的来源，避免先进入 Bangumi 资料源或夹具。已有来源不被随包播种覆盖；旧版规则由来源目录手动安全升级。

漫画规则 1.0.3 同时请求简繁中文，显示中文别名，目录分页且排除无应用内图片的外站托管章节。按稳定章节 id 去重，最多 100 页/10000 条；重复页、提前空页、缺字段、后页失败均明确失败，不缓存半份目录。图片接口错误信封和缺字段拒绝，只有 dataSaver 图片时可读取。切章时取消无意义的「0/0」及「1/0」滑杆，改成加载/失败提示。

## 真实验收

环境：Android `emulator-5554`，包 `io.github.hyperionhxh.triomi`。保留应用数据，使用 `adb install -r` 更新 debug APK。

| 路径 | 实际结果 | 证据（本目录 evidence/） |
|---|---|---|
| 发现番剧 | AGE 真实列表、三列封面、文字完整 | `C107-discover-grid-after.png` |
| 放大字号 | 应用外观设为「特大」后分类/来源文字仍完整，网格标题和来源不重叠 | `C107-discover-app-large.png` |
| 漫画发现 | 默认 MangaDex，实际封面 | `C108-manga-discover-after.png` |
| 手动规则升级 | 1.0.2→1.0.3 成功，保留收藏 | `C108-catalog-update-available.png`、`C108-catalog-updated.png` |
| 中文作品目录 | 《烙印勇士》（Berserk）211 章，不止前100章 | `C108-manga-catalog-211.png` |
| 第一章阅读 | 第0.01话繁中88页，加载真实图，翻到4/88 | `C108-manga-page1.png`、`C108-manga-page4.png` |
| 连续切章 | 第0.02话繁中69页，读到4/69，中文正文可见 | `C108-manga-chapter2-page4.png` |
| 重启续读 | 返回保存、force-stop、更新APK并重启、从书架继续；仍为第0.02话4/69，同一图片 | `C108-manga-restart-page4.png` |
| 书架分类 | 漫画默认；切小说保留原小说；无「全部」 | `C108-library-manga.png`、`C108-library-novel.png` |
| 中文搜索 | 全局搜索「烙印勇士」，MangaDex命中1条 | `C108-chinese-search-mangadex.png` |

主机联网 probe 使用随包 JsSource、QuickJS 与真实 HTTPS，发现20条、英文 Berserk 搜索命中、211章、两章88/69张，分别下载真实首图 1,113,232 / 798,288 bytes。记录为 `C108-host-mangadex-live.json`。搜索「剑风传奇」返回0，API索引名为「烙印勇士」；不能把英文搜索通过写成所有中文别名可检索。设备全局搜索中 Bangumi 超时、LNS unauthorized，其他来源的成功结果仍呈现，不能标成全部来源通过。

两倍字体由widget测试实际注入验证。系统font_scale=2的设备截图`C107-discover-font2.png`只能证明系统字号改变；应用当前用自己的uiFontScale覆盖系统值，因此不称为应用两倍字号验收。设备另用应用内「特大」设置（1.25）补验，完成后恢复标准；输入法与系统字体缩放也恢复原值。

## 检查与产物

切章提示先更新测试，旧实现真实失败（`C108-loading-before.log`），修复后加载和错误状态不显示滑杆。阅读/重启 focused tests 3项通过。最终全量 Flutter 640项、Python unittest 83项通过，analyze 无问题。日志：`C108-reader-tests.log`、`C108-flutter-tests-final.log`、`C108-python-tests-final.log`、`C108-analyze-final.log`。

debug APK 构建并安装成功：`build/app/outputs/flutter-apk/app-debug.apk`，日志 `C108-build-final.log`。编码检查0错误，新文档另以严格UTF-8读取检查。本轮未自动提交、推送或发布。源码、规则、截图与记录可复核。

## 尚未完成

- 用户提供的 APK 仓库已调查、签名已验证，但应用尚不能安装执行 APK；见 [C109](C109_MIHON_REPOSITORY_AUDIT.md)。这是明确的核心实现缺口，由 Codex 负责。
- MangaDex 中文章节取决于站点实际目录，非所有作品都有中文；缺失别名检索、用户可选低流量图片设置尚未实现。
- 书架封面缓存中原小说仍显示占位图，正文与收藏验收不等于封面全部正常。
- 手机硬解/音频/厂商差异、LNS本人账号及付费权限仍需用户条件；桌面动态播放器与恶意JS可终止隔离未完成。

前一轮真实番剧24:49正片、小说7/45页及来源安全事务升级已经通过，不重新列为未实现；见 [C99–C102](C99_C102_CORE_ACCEPTANCE.md)。
