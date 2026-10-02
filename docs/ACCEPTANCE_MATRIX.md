# 规格 2.4 验收证据矩阵（D17）

> 最新复核：D40 单任务 WiFi 自旋已修复；D37 前台 TTS 插件与阅读器已实现，Android debug APK 构建成功，真实发声未验收。D36 仅完成异步取消，同步强隔离未完成；D35 运行期异常补偿完成，崩溃恢复未完成。详见 `docs/REVIEW_2026-10-02_D39_D46.md`，下一批 D47-D58。

对照 `PROJECT_SPEC.md` §2.4（Mixn 功能全量清单，A1–G2）逐项建立证据表。
判定分两层：**实现层**（代码 + 单测可证）与**设备/账号层**（模拟器或真实站点
记录）。两层都有充分证据才在规格里打勾；只有实现层的项保留勾选但标注设备
边界，有缺口的项不打勾并写明缺口。

证据来源缩写：
- 「测试」= `test/` 下的用例；「记录」= `docs/handoff/README.md`、
  `docs/M*_REVIEW.md`、`docs/CHECKPOINT_2026-10-01.md` 的设备/真实账号记录。
- 文件引用相对 `lib/`。

## A. 发现与搜索

| 项 | 要求 | 证据 | 判定 |
|---|---|---|---|
| A1 | 双源独立发现，不混榜 | LK：`features/novel/data/lk/lk_source.dart` DiscoverProvider（热门/日榜/周榜/新人新作/最近更新）；LNS：`lns_source.dart`（GetBookList(view/new/latest) + GetRank 日榜）。测试 `t4_test.dart` 发现榜单组、`t5_test.dart`；记录：2026-09-27 LK 真实站点发现页正常、LNS 真实账号榜单正常 | 完成 |
| A2 | 聚合搜索并行、逐来源成败、不要求登录 | `features/search/`（逐来源成败聚合）；LK/LNS 均实现 SearchProvider；声明式源聚合搜索测试 `rule_engine_test.dart`、`m4_test.dart` | 完成 |
| A3 | 触底分页；固定榜单到底明确提示、不重复追加 | `features/discover/discover_page.dart:289` 触底判定（T7-2：空页或不满一页 → 到底）+「已经到底了」分隔条；LNS 日榜固定快照翻页不重复追加（`t4_test.dart`） | 完成 |

## B. 书籍与阅读

| 项 | 要求 | 证据 | 判定 |
|---|---|---|---|
| B1 | 详情页：简介/标签/同书版本/分卷/两级目录 | 同书版本 `t5_test.dart`（alternate_versions 解析）+ 记录「同书版本（B1）在真实站点有数据」；LK 分卷解析 `lk_client.dart`（list/volumes）；LNS 卷→章 `lns_source.dart` defaultVolumeTitle | 完成 |
| B2 | 统一书架，复合键 | `features/library/data/library_repository.dart`；复合键隔离显式回归 `d10_release_audit_test.dart`；备份导入侧 `m5_test.dart`；记录：模拟器与真实账号书架链路 | 完成 |
| B3 | 阅读器双模式 | `NovelReadingMode.paged/scroll`（`novel_reader_settings.dart:7`）；`reader_pagination_test.dart`、`reader_settings_test.dart`；记录：M4 模拟器两模式 | 完成 |
| B4 | 排版调节全套 | 字号/行距/边距/背景/护眼色/进度条：`novel_reader_settings.dart` + `reader_settings_test.dart`；点击区域与屏幕常亮：`novel_reader_page.dart` + `core/platform/platform_channel.dart`；音量键翻页（默认关）：`novel_reader_page.dart:383`；屏幕方向：T7-8（`t7_misc_test.dart`） | 完成 |
| B5 | 正文插图 | 图片块解析 + 协议相对地址/HTTPS 升级：`novel_blocks.dart`（`_toHttpsImageUrl`、img 宽高属性）；放大/长按保存相册/系统返回退出：`core/widgets/image_viewer.dart`（`onLongPress: _saveToGallery`）；懒加载按分页排版天然按页渲染。记录：M4 真实账号正文插图渲染 | 完成（注：无显式「懒加载」开关，靠分页按需渲染实现） |
| B6 | 付费章节，不绕过 | 锁定标注与解锁流程：`lk_client.dart`/`lk_source.dart`（UnlockProvider）、`novel_reader_page.dart`；导出排除锁定章节：`export/epub_exporter.dart`；测试 `t5_test.dart`。真实付费账号的解锁记录未单独立项（红线由「不缓存、不导出、不伪造」实现保证） | 完成（实现层） |
| B7 | LNS 专用字体，在线离线先缓存再渲染 | 字体地址补全/TTF 换源/WOFF2 拒绝：`t4_test.dart` 字体组；离线序列化带字体族：`t4_test.dart`；记录：2026-09-27 真实账号正文字体生效、修复 wss/scheme 与相对路径两处真实缺陷 | 完成 |

## C. 账号与站点功能

| 项 | 要求 | 证据 | 判定 |
|---|---|---|---|
| C1 | 双源独立登录/会话恢复，凭据安全存储 | `lns_auth.dart`（SecureLnsTokenStore）、`lk_client.dart` 会话；Hive→SecureStore 迁移与回退：`t6_reader_security_test.dart` 凭据迁移组；记录：LK/LNS 双源真实登录 | 完成 |
| C2 | LK：资料/轻币/签到/关注粉丝/发布管理/消息中心/评论全套 | 资料/轻币/七日签到：`lk_account_page.dart` + 记录；关注/取关：`t5_test.dart`；消息中心与评论已有记录。发布管理保留 `lk_works_page.dart` seam 与测试，但真实端点契约未验证，资料页入口暂时隐藏，待 Codex 获得可审计契约后恢复 | 部分完成（发布管理 adapter 未接） |
| C3 | LNS：资料/收藏同步/签到；无评论接口不显示入口 | `lns_account_page.dart` + 记录（Miuna5633 签到轻币 429→459）；远端书架读写双向验证（加入→出现，移出→清空）；无评论/关注入口 = 能力显隐 | 完成 |
| C4 | 站点错误保留具体来源/类型 | `core/models/source_exception.dart` 分类 + `SourceException.wrap`；非 2xx 带服务端原因（响应体片段/诊断头，commit `bbb9f75`）；分类测试 `d8_tracking_boundary_test.dart`、`d9_protocol_fixture_test.dart` | 完成 |

## D. 下载与导出

D1–D5 已在规格勾选（下载/SAF/后台排程有设备记录），此处补实现层证据：
`features/downloads/data/`（小说/漫画/视频下载器、HLS 解析、仅 WiFi；
D30 后 WiFi 判定有可注入 seam 并接进调度器）、
`export/`（EPUB/TXT 导出；D29 起 `NovelExportService` 支持 SAF 授权目录
注入 + 私有目录回退，详情页已接线，MIME 契约见
`docs/SAF_WRITE_CONTRACT.md`）、`features/downloads/download_providers.dart`；
测试 `m4b_test.dart`、`m5_test.dart`、`video_download_test.dart`、
`hls_playlist_test.dart`、`t7_misc_test.dart`（T7-4 SAF / T7-7 后台提醒）、
`export_saf_injection_test.dart`（注入/回退）、`detail_export_page_test.dart`
（导出页 widget：取消/MIME/回退提示）、`platform_channel_mime_test.dart`
（通道 MIME 契约）。

## E. 字体与外观

| 项 | 要求 | 证据 | 判定 |
|---|---|---|---|
| E1 | 系统字体 + 可下载字体，独立预览页 | `features/novel/reader/fonts_page.dart`（中文/标点/英文示例同页，系统默认与下载字体可对比，`fonts_page.dart:193` 起）；在线字体下载：记录 T7-5（霞鹜文楷 18.4 MB 下载成功并进预览卡） | 完成 |
| E2 | 阅读设置与外观设置分开保存、分组可恢复默认 | `novel_reader_settings.dart:189` 分组恢复默认；`settings_controller.dart:80` 外观分组恢复默认且不影响阅读设置；`settings_page.dart:12`；测试 `reader_settings_test.dart` | 完成 |
| E3 | 主题、界面字号、图标大小可调 | `settings_controller.dart:6`（主题模式/界面字号/图标大小）+ `settings_page.dart` | 完成 |

## F. 隐私与安全红线

| 项 | 要求 | 证据 | 判定 |
|---|---|---|---|
| F1 | 凭据不落缓存/日志/崩溃报告；登出清理私有缓存 | SecureStore 迁移与登出清理：`t6_reader_security_test.dart`（迁移组 + 登出清理组）；备份过滤（securityKey/token/password/secret 全变体，导出与导入两侧）：`d10_release_audit_test.dart`；追踪错误信息不带 token：`d8_tracking_boundary_test.dart` | 完成 |
| F2 | 只申请必需权限 | `android/app/src/main/AndroidManifest.xml`：INTERNET / POST_NOTIFICATIONS / RECEIVE_BOOT_COMPLETED（后台排程 persisted job 必需）/ ACCESS_NETWORK_STATE（JobScheduler 网络约束必需）；存储走 SAF，无全盘存储权限 | 完成 |
| F3 | 不伪造阅读时长、不接灰色接口 | 代码审查负向结论：仓库无「浏览赚币」「阅读时长上报」类实现（全文检索无命中）；评论发表携带的 read_duration_seconds 固定传 0（`lk_client.dart` publishComment） | 完成 |

## G. 书架更新提示

| 项 | 要求 | 证据 | 判定 |
|---|---|---|---|
| G1 | LK 用来源未读章数；其他源章节数跨刷新增加时标更新 | 通用基线已落地：`LibraryRepository.saveChapters` 首次缓存不报未读，后续只按新增章节 remoteId 累计 `unreadCount`，重复刷新不重复累计；D32 补齐边界回归（删除不减、重排不累计、`markAllRead` 全清/按来源/无未读返回 0，`library_repository_test.dart`）。LK 专用来源未读数覆盖尚未接入 | 部分完成（通用基线+边界测试完成） |
| G2 | 更新以复合键为准；全部标已读只确认本地提示、不改远端 | `t6_reader_security_test.dart` G2 组（只清有未读行/按来源过滤/无未读返回 0）；D32 补充 `markAllRead` 返回值语义固化；markAllRead 纯本地操作，无远端调用 | 完成（依赖 G1 的写入方落地后才有实际更新数可确认） |

## 结论与建议（交 Codex）

1. **G1 通用基线已完成**：目录刷新按新增章节 remoteId 累计本地提示；D32 已固化
   删除/重排/`markAllRead` 边界；后续只需接入 LK 专用未读数覆盖。
2. **C2 发布管理页（D27）**：页面 + `LkWorksRepository` adapter seam + 路由
   保留；真实接口契约未验证，资料页入口已隐藏。获得可审计端点与字段后再恢复入口。
3. **第四轮 D39-D46 补充证据**：D39=导出页 widget 回归（SAF 取消/MIME/回退
   提示）、D40=调度器 WiFi 停泵/恢复（**发现单任务自旋缺陷 D40-1，待
   Codex 修复**）、D41=TTS 回调竞态（token/seek-stop/speak 抛错）、
   D42=错误文本脱敏审计、D43=SAF 写入契约（含旧备份 zip 兼容确认）、
   D44=交付文档一致性扫描器；
4. **第四轮 D27-D34 补充证据**：C2=D27（发布管理页 seam，入口隐藏）、
   D28=Windows 播放库依赖锁定（构建待工具链）、D29=SAF 导出注入且详情页已接线、
   D30=WiFi 检测 seam 与调度接线、D31=TTS 合同层与 token 竞态防护（插件接线=D37）、
   D32=G1 边界测试、D33=备份审计、D35=设置先写与失败补偿；D34 为文档/扫描器收口。
   交付明细见 `docs/delivery/D27.md`–`D34.md` 与 `BATCH_D27_D34_SUMMARY.md`；
   第四轮见 `docs/delivery/D39.md`–`D46.md` 与 `BATCH_D39_D46_SUMMARY.md`。
4. **第五轮 D47-D58 补充证据**：D47=TTS 生命周期 widget 回归（换章/退出/
   后台/繁简停止 + 迟到事件丢弃）、D48=语速三档与系统音色选择及本机持久化、
   D49=SAF writer 返回系统真实 document URI（系统改名场景钉住）、
   D50=导出位置三分支提示（授权目录/取消选择/写入失败回退，回退不报导出
   失败）、D51=夹具 Range 非法形态统一 416、D52=备份补偿扩充（第 2/3+
   个写入失败回滚、null 旧值与缺键区别、补偿自身失败复现= D60）、
   D53=停泵测试提速（调用数封顶信号）、D54=JS 异步生命周期扩展（乱序/
   超时并存/不可序列化参数/load 状态隔离，真实 quickjs 宿主）、
   D55=一致性扫描器标识边界（D1≠D10）。设备/构建层证据不变：TTS 真实
   发声、Windows 构建与语音仍未验收（见 `docs/RELEASE_READINESS.md`）。
   交付明细见 `docs/delivery/D47.md`–`D58.md` 与 `BATCH_D47_D58_SUMMARY.md`。
5. 设备/账号层通用边界：弹弹play 真实凭据仍在官方审核（Invalid AppId），
   物理真机项见 `CHECKPOINT_2026-10-01.md`；这些不影响上表实现层判定。
