# E-Hentai iOS ↔ Android 主线功能对照清单

基准：Triomi 主线 `origin/master f3f08bb`（v0.15.4）实际执行的 E-Hentai 插件 **1.6.36**
（`eu.kanade.tachiyomi.extension.en.ehentai`，源ID `57122881048805941`，
源码 `HyperionHXH/E-extensions@13df3c3 src/en/ehentai`）。
运行基准：v0.15.4 Windows 发布包内同一 Suwayomi v2.4.2366 运行时 + 官方原生 JAR，E 盘无界面运行
（用户选定；安卓模拟器因本机缺少硬件加速驱动不可用，已删除）。
范围：严格对齐安卓（用户确认不额外实现收藏写入/额度显示）。

状态：`待实现` → `一致`（需 Mac 测试 + iPhone 实测通过）。

与安卓的已知差异：SOCKS 代理不可用（iOS Dart HttpClient 只支持 HTTP CONNECT）；图片失败重试上限 8 次（约 60 秒退避），因 iOS 图片加载无滚出即取消的所有者；旧分段迁移时，整本仅在所有旧分段都已读时标记已读。

## A. 来源能力与列表

| # | 安卓行为（基准实测/源码） | iOS 现状 1.1.1 | 状态 |
|---|---|---|---|
| A1 | 热门 `/popular`；最新 = 首页游标分页（`var nexturl`/`#dnext`） | 热门单页、最新用 `next=` 参数 | 一致（Mac + iPhone 实测通过） |
| A2 | 镜像设置：E-Hentai / ExHentai（ExHentai 需三Cookie） | 仅 e-hentai.org，拒绝 ExHentai | 已实现（Mac 测试通过，待 iPhone 实测） |
| A3 | 列表行：标题、封面（`data-src`优先，跳过占位）、行内 `namespace:tag` | 标题、封面，无行内标签 | 已实现（Mac 测试通过，待 iPhone 实测） |
| A4 | 关键词搜索 `f_search`；空关键词且无筛选 → 热门 | 有关键词搜索 | 已实现（Mac 测试通过，待 iPhone 实测） |
| A5 | 直接打开图库 URL（`/g/<id>/<token>`），含 ExHentai | 仅 e-hentai URL | 一致（Mac + iPhone 实测通过） |

## B. 筛选（21 项，与安卓 FilterList 同结构、同顺序、同取值）

| # | 筛选 | 站点参数 | 状态 |
|---|---|---|---|
| B1 | 浏览来源：站内搜索/我的收藏夹/我的关注标签/排行榜·昨日/本月/本年度/全部时间 | `favorites.php` / `watched` / `toplist.php?tl=15/13/12/11` | 已实现（Mac 测试通过，待 iPhone 实测） |
| B2 | 关注标签、排除关注标签（文本） | 关注模式 `f_search` 精确标签项 | 已实现（Mac 测试通过，待 iPhone 实测） |
| B3 | 收藏夹分类（10个，名称登录后从站点学习）、收藏夹内关键词、收藏排序 | `favcat`、`inline_set=fs_f/fs_p` | 已实现（Mac 测试通过，待 iPhone 实测） |
| B4 | 跳转日期 YYYY-MM-DD | `seek` | 已实现（Mac 测试通过，待 iPhone 实测） |
| B5 | 分类（全部+10类） | `f_cats = 1023 xor bit` | 已实现（Mac 测试通过，待 iPhone 实测） |
| B6 | 最低评分、语言 | `f_srdd`、`language:xxx` | 已实现（Mac 测试通过，待 iPhone 实测） |
| B7 | 页数下限/上限 | `f_spf`/`f_spt` | 已实现（Mac 测试通过，待 iPhone 实测） |
| B8 | 包含已删除、要求种子、忽略语言/上传者/标签 | `f_sh`、`f_sto`、`f_sfl`、`f_sfu`、`f_sft` | 已实现（Mac 测试通过，待 iPhone 实测） |
| B9 | 排行榜分页 `p=`、进程重启后可直跳 | `toplist.php?p=N-1` | 已实现（Mac 测试通过，待 iPhone 实测） |

## C. 详情、章节与阅读

| # | 安卓行为 | iOS 现状 | 状态 |
|---|---|---|---|
| C1 | 详情：英/日标题、封面（`#gd1` img 或背景）、作者=上传者、`namespace:tag` 全量、描述、状态未知 | 作者取画师、描述为元数据堆叠 | 一致（Mac + iPhone 实测通过） |
| C2 | **单章节 “Full Gallery”**，chapter_number 1，上传时间=Posted；无版本拆分 | **按 10 页拆成多章节**（用户反馈的“20页20页拆分”根因） | 一致（Mac + iPhone 实测通过） |
| C3 | 页面列表：首页 `?nw=always`，按首页缩略图数（20/40）推算总页数，逐页抓取，空页/无新链接报限流 | 每章限 10 张、预先解析图片 | 一致（Mac + iPhone 实测通过） |
| C4 | 图片：查看页 `img#img`；原图需登录+设置原图时取 `/fullimg/` | 仅标准图 | 一致（Mac + iPhone 实测通过） |
| C5 | 图片失败（403非封禁/404/429/5xx/网络）指数退避 0.5s→15s，并经 `nl()` 刷新节点重试 | 失败即报错 | 已实现（Mac 测试通过，待 iPhone 实测） |
| C6 | 预解析图片地址（默认关） | 无设置 | 已实现（Mac 测试通过，待 iPhone 实测） |
| C7 | 标签点击 → 本源按标签搜索 | 需与 C1 标签格式一致 | 一致（Mac + iPhone 实测通过） |

## D. 账号与设置（9 项设置 + 镜像）

| # | 设置 | 状态 |
|---|---|---|
| D1 | ipb_member_id / ipb_pass_hash / igneous（容错 `name=` 前缀、去尾部标点、旧合并Cookie迁移） | 已实现（Mac 测试通过，待 iPhone 实测） |
| D2 | 关注标签组编号（1–999，修改即重新同步） | 已实现（Mac 测试通过，待 iPhone 实测） |
| D3 | 手动追加关注/排除标签（兼容模式） | 已实现（Mac 测试通过，待 iPhone 实测） |
| D4 | 代理地址（http/https；socks/socks5 因 iOS Dart HttpClient 不支持而明确拒绝并提示） | 已实现（与安卓差异：不支持 SOCKS） |
| D5 | User-Agent | 已实现（Mac 测试通过，待 iPhone 实测） |
| D6 | 图片质量 标准/原图 | 已实现（Mac 测试通过，待 iPhone 实测） |
| D7 | 请求间隔 0/0.5/1/2 秒（仅页面请求） | 已实现（Mac 测试通过，待 iPhone 实测） |
| D8 | 登录态缺失时：ExHentai/收藏夹/关注 给出与安卓一致的明确提示；登录页、临时封禁识别 | 已实现（Mac 测试通过，待 iPhone 实测） |
| D9 | 关注流：登录走 `/watched`，空时回退 `/mytags` 同步标签搜索（10分钟缓存） | 已实现（Mac 测试通过，待 iPhone 实测） |

## E. 漫画插件管理（对齐主线安卓“插件与来源管理”）

| # | 安卓能力 | iOS 现状 | 状态 |
|---|---|---|---|
| E1 | 入口“插件与来源管理”，已安装列表（图标/名称/版本/启停状态） | 同名入口 → `IosPluginLibraryPage`“插件库”：已安装 JS / API 规则插件（图标/名称/版本/启停），菜单 详情与来源设置 / 启用·停用 / 卸载；app bar 搜索插件、添加插件、溢出菜单 仓库 / 规则与来源设置 | 已实现（Mac 测试通过，待 iPhone 实测） |
| E2 | 添加插件页：按仓库浏览、按名称/语言/内容分级筛选、搜索 | “添加插件”页：内置离线目录 + 已启用仓库，语言/内容分级筛选、独立搜索页、刷新 | 已实现（Mac 测试通过，待 iPhone 实测） |
| E3 | 仓库：添加/编辑/移除（不卸载、不删书架） | 添加/编辑（原位替换，保留顺序与启停）/启停/移除，移除前确认且不卸载插件；APK 仓库仅经 `triomi.indexUrl` 兼容入口 | 已实现（Mac 测试通过，待 iPhone 实测） |
| E4 | 安装/更新（失败保留原版本）、启用/停用、卸载（保留书架历史） | `CatalogInstaller` 安装/更新（失败保留原版本与启停），已安装列表显示“可更新 vA→vB”与更新按钮；卸载 = 移除规则行，保留书架/历史/下载 | 已实现（Mac 测试通过，待 iPhone 实测） |
| E5 | 插件详情与来源设置、外部浏览器、应用内网页会话 | `IosPluginDetailsPage`：来源设置 / 外部浏览器 / 应用内网页会话均走 `performMangaSourceAction` | 已实现（Mac 测试通过，待 iPhone 实测） |

## F. 数据迁移

| # | 要求 | 状态 |
|---|---|---|
| F1 | 已收藏 E-Hentai 作品身份保持（`<gid>/<token>`），书库/历史不丢 | 已实现（Mac 测试通过，待 iPhone 实测） |
| F2 | 旧“Pages a-b”分章节历史迁移到单章节对应页位置 | 已实现（Mac 测试通过，待 iPhone 实测） |

## G. iPhone 实测（iOS 15.8.3，独立 `.acceptance` 身份，生产 Triomi 未改动）

经生产 iOS 网络栈（Dio + HTTP 代理）实网访问 e-hentai.org，与安卓 1.6.36 基准对照，11/11 通过：

| 检查 | 安卓基准 | iPhone 结果 |
|---|---|---|
| 筛选行 | 22 行，名称/顺序见 B | 22 行，名称与顺序逐项相同 |
| 热门 | 单页，无下一页 | 单页（实时 55 条），无下一页 |
| 最新 | 两页各 25 条、无重叠、有下一页 | 25 / 25、重叠 0、有下一页 |
| 图库 URL 搜索 | `/g/4320527/f4f84dd874/` | 命中同一 `4320527/f4f84dd874` |
| 详情 | 标题、上传者 `sexwanjiayun`、24 个标签 | 相同 |
| 章节 | 单章节 “Full Gallery” | 单章节 “Full Gallery”，章节 ID = 图库 ID |
| 页数 | 201 页 | 201 页，1…201 顺序完整 |
| 图片 | 可读取 | 首页 / 末页均为有效图片字节 |
| 标签搜索 | 本源按标签搜索 | `artist:ryoma` 返回 25 条且包含该图库 |
| 阅读显示 | — | 第 1 页实际渲染（945×1347），有截图 |
| 设置页 | 12 项设置 | 镜像 / 三 Cookie / 图片质量 / 请求间隔等全部渲染，有截图 |

未在 iPhone 上实测（仅 Mac 测试覆盖）：ExHentai 与收藏夹 / 关注流（需要用户 Cookie）、图片失败重试与 `nl()` 换节点、旧分段章节迁移、插件管理 E1–E5。
