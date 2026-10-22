# 来源能力矩阵与生产/夹具边界（D75）

> 当前来源边界（R171）：没有保存仓库设置时默认启用官方 KazumiRules；已有自定义列表及用户显式清空状态保留。番剧支持兼容 api1–9 XPath/API 子集，包括 API9 `sourceTemplate`，官方17条规则导入检查通过不代表各站验证、视频解析或播放均成功。两端补齐无后缀 HLS 嗅探及格式传递；只有规则声明旧解析时读取 iframe 查询中的媒体地址，不绕过验证码/TLS。Mihon仓库策略及原生/桌面宿主不变，不自动删除用户设置。当前产物、有限实际播放及发布状态以[CURRENT_STATUS](CURRENT_STATUS.md)为准；下方带轮次记录保留历史事实。

## 来源矩阵

| 来源 | 类型 | discover | search | detail | content | 播放线路 | 生产/调试 | 证据 |
|---|---|---|---|---|---|---|---|---|
| `bangumi-anime.json`（Bangumi 番剧资料） | anime | ❌ | ✅ | ✅ | ❌ | **无**——资料源，不提供正片 | 生产随包身份，官方base的公开读取由专用v0/p1 Adapter处理 | R153生产HTTPS详情713ms、36集总1050ms，缓存后339ms；0个可播放URL。账号请求不转发公开兼容后端；仅当前主机样本，不代表全站/设备网络 |
| `local-fixture.json`（本地夹具·漫画） | manga | ✅ | ✅ | ✅ | ✅（图片） | 图片页，仅夹具服务器 | **debug且显式开发开关** | `source_registry.dart` 的 `developmentSourcesEnabled` |
| `local-fixture-anime.json`（本地夹具·番剧） | anime | ✅ | ✅ | ✅ | ✅（mp4/HLS） | 夹具 sample.mp4/m3u8，**不是真实番剧** | **仅调试** | 同上 |
| `local-fixture-novel.json`（本地夹具·小说） | novel | ✅ | ✅ | ✅ | ✅（文本） | — | **仅调试** | 同上 |
| `local-fixture-js.json`（夹具 JS 对照） | manga | ✅ | ✅ | ✅ | ✅ | 同夹具 | **仅调试** | 同上 |
| `mangadex-api-js.json` v1.0.5 | manga | ✅ | ✅（名称/原始题材标签） | ✅ | ✅（图片；可选低流量） | — | 随包播种，可从来源目录安全升级，不覆盖用户规则 | R155公开题材字典77项、Action请求实际Berserk结果；最终Windows在线最近更新20部及封面。历史C149为v1.0.4；不是APK执行证据 |
| 用户 Mihon APK 仓库 | manga | ✅ | ✅ | ✅ | ✅（插件图片） | — | Android 宿主真实验收；不代表全仓库兼容 | MangaDex 1.6、拷贝漫画 1.4、Jinman 1.6.59 阅读/重启；Jinman 原始来源设置与图片还原通过；十八漫画 1.6 加载成功但站点超时 |
| `age-anime-js.json` v1.0.1 | anime | ✅（首页最新） | ✅ | ✅（分线路） | ✅（网页 PlaySource） | Android WebView 解析到实际 HLS/MP4 | 随包播种，可从目录更新；本轮 Android 实测 | C99 芙莉莲线路 2 第 08 集 24:49 正片；线路 1 错误卡明确拒绝 |
| Kazumi 7sefun v1.3 / MXdm v2.4 / DM84 v1.4 | anime | ❌（推荐独立） | ✅ | ✅（站内播放列表） | ✅（网页/直接流） | 各站各列表独立，不冒充多个网站 | C124随包MIT原规则、支持XPath子集 | 三站真实网络搜索/目录见C124-kazumi-live-network；7sefun设备视频另记，不宣称三站全视频通过 |
| 推荐服务（非播放provider） | anime | 24条触底分页/刷新 | — | 跳到Bangumi资料 | ❌ | 不生成播放地址 | 公开推荐与v0搜索采用各自合法响应Adapter | 分页使用原始rows/offset，筛选切换清后端游标；公开资料镜像说明在界面可见，不传凭据 |
| `archive-animation-js.json` v1.0.1 | anime | ✅ | ✅ | ✅ | ✅（MP4 契约） | 显式 MP4 文件地址 | 动画馆藏候选，网络未通过 | D87 真实请求超时；QuickJS 离线契约通过 |
| 轻之国度 LK（内置适配器） | novel | ✅ | ✅ | ✅ | ✅ | —（正文） | 生产；公开内容可匿名，账号/付费另需权限 | C125双API本人登录/书架2/非0未读/重复合并稳定、20章/19471字符及缓存/TXT/EPUB；有界LK DNS回退保留TLS校验 |
| 轻书架 LNS（内置适配器） | novel | ✅（账号） | 声明支持，未独立复验 | ✅（账号） | ✅（正文/字体） | — | 生产，真实接口需要会话；整书官方站点下载 | C125双API本人登录/169章/4124字符/专用字体/缓存；游客及无效会话拒绝；CanDownload=false、DownloadCost=200；整书重打包拒绝，不扣金币 |
| Windows Mihon兼容宿主（Suwayomi v2.4.2366） | manga | 按插件 | 按插件 | 按插件 | 插件转换后的真实图片 | — | 随完整Windows包，不依赖外部Java/服务器；桌面JAR独立来源/指纹确认 | 普通应用已实跑xkcd仓库下载/确认/启用、5来源、真实设置保存重进、3311章及第1/2→2/2页真图；具体字节范围和最终包另见CURRENT_STATUS，不冒称全仓库 |


R153请求生命周期：Dio已接每操作取消，真实loopback取消25ms并保留同客户端并行200；JS worker宿主使用parentId和各调用Zone归属，取消HTTP不终止其他来源会话。同步native JS仍依赖既有watchdog/销毁终止；Mihon/SignalR没有物理取消的调用允许在途完成但禁止过期结果发布，不宣称已停止。漫画来源明确不支持搜索时不请求，能力未知仍尝试，不从空结果推断不支持。

C153最终Android实际旅程：公开推荐/FX资料、保留原7sefun映射与21集目录、已下载小林第01集24:22/25:11真帧；MangaDex无需命名订阅确认→单源最近更新20部→原书库第76.2话5/14双页真图。该漫画是JS/API来源，不新增APK执行主张。API26/正式包原LK缓存正文20/22、3/37可读，双API小说已下载书架冷启恢复。上述在线API35临时经普通CONNECT代理解决模拟器DNS问题，结束恢复默认网络、停止临时服务；不证明默认网络可达或新网页视频解析。当前整套974通过/3跳过、85Python、analyze无问题；Windows仅本轮最终构建与50成员打包通过，缺专用桌面接口，当前UI旅程未验。完整边界见[C153](delivery/evidence/C153-final-acceptance.json)。

C154仅修复界面系统字号的优先级，不扩大任何来源能力：原API26/API35/正式包的200%系统设置下界面真图、横屏导航/筛选与本地键盘输入有样本证据，原字号均已还原。Windows当前下载ZIP已实跑MangaDex单源20部、Berserk搜索1部、211章目录/第9/88页真图、原缓存小说3/83冷启相同正文；跨栏搜索草稿保留、窄窗口系统200%与NVDA真实语音输出样本已证，系统设置已恢复。Windows未执行APK扩展，不代表全来源/完整读屏矩阵通过。975项Flutter通过/3跳过，原153媒体证据保留原字节范围，不挪作154重验，见[C154](delivery/evidence/C154-final-acceptance.json)。
R155最终实证：Windows正式MSI真实MXdm→FX第01集4:30/24:19及选集，绿色包MangaDex JS/API最近更新20部、LK奇幻标签在线20条；最终API26原xkcd历史→详情→2/2真图→返回历史，API35 LNS2/10专用字体和正式LK3/37正文可读。番剧五分区缓存可读，模拟器在线刷新DNS/超时保留；官方Next吐槽请求超时，不把缓存/错误算在线成功。Bangumi账号收藏与WebDAV同步已接生产账号服务，真实远端实写仍待具体授权；不复制镜像应用凭据。1004项Flutter/89项Python通过、3项跳过、analyze无问题；原证书/保数据升级/实际安装hash及Windows安装生命周期见[C155](delivery/evidence/C155-final-acceptance.json)。不扩大到全站、完整读屏或长时稳定性。




## 边界规则（守卫测试逐条断言）

1. **Bangumi 是资料源**：`capabilities` 不得含 `content`——不从 Bangumi 推导
   播放地址，不伪造版权站地址；番剧播放闭环（D79/D80，Codex）必须来自
   显式声明的 `content.playSources` 合法 provider。
2. **夹具须显式启用**：`local-fixture*` 只在debug且
   `--dart-define=TRIOMI_DEV_FIXTURES=true` 时进入 `builtinRuleAssets`。
   普通debug/release不播种，已有夹具记录不进入enabledEntries，不用于发现/搜索；旧记录仍可在管理页保留。
   这是运行/播种边界，不宣称pubspec打包资产绝对不含夹具文件。
3. **夹具只指向本地服务器**：夹具规则的 `baseUrl` 只允许 `10.0.2.2:8123`
   （模拟器宿主中继）/ `127.0.0.1` / `localhost`——夹具不能被改成真实站点。
4. **夹具命名必须自证身份**：id 以 `local-fixture` 开头，name 含「夹具」或
   「调试」，UI 与文案不得把夹具内容宣传成真实番剧/漫画。
5. **全部随包规则必须通过相应规则 schema 校验**（声明式/JS用 `SourceRule.parseJson`，Kazumi用 `KazumiRule.parse`），
   UTF-8 编码（由 `tools/check_text_encoding.py` 兜底）。

## 回归测试入口

| 范围 | 测试 |
|---|---|
| 本表全部边界 | `test/source_boundary_guard_test.dart`（D75） |
| 规则 schema 自检 | `test/rule_engine_test.dart` |
| 夹具 HTTP 契约 | `tools/test_fixture_http_contract.py`（D25） |
| 漫画夹具端到端（发现→详情→章节→阅读/缓存） | `test/manga_fixture_contract_test.dart`（D78） |
| 来源目录协议 | `test/source_catalog_test.dart`（D76） |
| 来源目录 UI | `test/source_catalog_page_test.dart`（D77） |

## 最新验收（2026-10-05，C99–C102）

Flutter 与 Android 模拟器现已可用，`emulator-5554` 在线。来源目录可安装并安全更新 JS 规则；AGE 有真实最新列表、中文搜索、168 项分线目录与正片画面/活动音轨/进度。漫画 8/14 页、LK 小说 7/45 页强制重启恢复通过。具体证据、622 项回归和限制见 [四项核心验收](delivery/C99_C102_CORE_ACCEPTANCE.md)。

Internet Archive 不等同 Kazumi 式最新番剧来源，其馆藏也不能全部称为公版。声明 content 和离线 MP4 契约通过不等于真正番剧已能播放。Bangumi 仍无播放能力。

## 已知未完成（不冒充完成）

- Windows可见WebView2解析/下载已有接线；C148实际会话保存/取消、自有loopback网页→562487字节MP4完成且SHA一致；不改标最终C149。C149修复新包自有TLS HttpOnly保存→关闭→冷启动首请求复用→取消已通过，不代表真实站点登录/CF或视频profile共享；复杂解析仍待，专用认证headers继续拒绝。C125桌面限制只属历史。
- MangaDex1.0.4新增来源设置“低流量图片”，默认原图，正文每次读取最新偏好；缺节流列表回原图，原图缺失仍可读节流。简繁中文目录/排除外站/分页失败拒绝保持。C149生产JsSource+QuickJS+真实HTTPS烟测20条发现、同官方中文别名命中、211章/88页、原图1113232字节与节流575519字节均实际取回，见[真实引擎烟测](delivery/evidence/C149-mangadex-live-host.json)。`烙印勇士`/`劍風傳奇`同UUID，未列入altTitles的`剑风传奇`返回0；非任意别名或自动简繁转换。已有安装通过可见目录CAS升级，不覆盖用户规则；实际UI设置与图片另见最终证据。
- APK 不自动覆盖用户旧规则；执行DEX前完整验签及发布者/hash/版本pin、失败保留旧运行时已完成。未知不同发布者需可见信任确认。C125 Android/Windows生产JS迁入可强杀OS worker，三平台独立watchdog恶意循环/分配与恢复通过；宿主HTTP/凭据保留，8MiB消息和平台内存限额。属于故障隔离，不是不同UID/完整权限沙箱；其他平台明确不支持。
- C150历史缺versionName的已安装APK备份，仅从静态验签且原package/code/hash/完整signer匹配的快照补出，不改信任/旧配置。正常五APK SAF导出729296B与manifest通过；完整原件只预览取消，明确APK-only子集正常SAF恢复→冷启停用待确认→先拒绝再显式接受→DEX七语言/真实Feed/Suitor Armor169章通过，双设备原状态/pin完全不变且自有新增清理。封面占位、未经裁剪全库跨机恢复不算通过；25定向/967全量通过，见[C150闭环](delivery/evidence/C150-apk-restore-final-journey.json)。
- 漫画恢复图片页（条漫不含图内像素），小说恢复文字锚点，设备重启续读已通过；不同字体/屏幕会重新分页，页码可能变化。
- 用户Mihon/Tachiyomi仓库与GNOME Komikku格式不同。Android已有MangaDex1.6、拷贝漫画1.4、Jinman1.6.59实际阅读证据，十八漫画1.6站点超时。R165 Windows按用户新要求新增受管Suwayomi兼容运行时，优先仓库声明的原生JAR，无JAR才尝试APK转换；静态签名/身份核验、独立JAR信任及实际执行文件hash校验仍必需。KCEF关闭，桌面插件不提供假共享网页会话；真实设置/外部浏览器分开，不承诺网页挑战或全插件兼容。历史C110/C113/C116/C121仍只证明其当轮Android范围。
- Mixn双源全部账号功能和物理手机验证仍未全部完成。
- 轻书架官方公告16没有小说按章付费；金币用于整书EPUB，下载受上传者/管理员控制。C125读取nullable权限/费用并拒绝整书EPUB/TXT重打包，保留阅读缓存；历史离线EPUB证据仅为旧行为。游客/无效会话和本人实际下载字段已验收，不调用扣金币接口。特殊字体仍拒绝系统TTS。
- C149图片经既有来源网络客户端统一代理/超时/TLS；最终API35四推荐封面与漫画双页真图目视、Windows四封面实测。无痕三媒体后API35完整历史19/收藏6/关联2行不变，恢复off。正式包自有图15%白边裁切后内黄框保留、唯一自建封面正常UI清理实删，原正文保留；均精确清理样本，不等于任意裁边/用户缓存删除/全平台通过，见[最终证据](delivery/evidence/C149-final-acceptance.json)。
- C149 P8动态自有loopback新章通知/自动下载PNG/SHA及离线真图、低电/无网络/取消重试通过；P9实际生产SQLite/文件跨6进程迁移/hash/独立进度/冲突通过；P11 Windows每日任务启用/触发生成/冷启/取消通过。Windows隐私锁N17已修、最终新包真实开启/失焦/冷启/解锁/关闭还原通过，HttpOnly自有TLS会话冷启动通过；API26最终真实内嵌字幕选择/显示/关闭通过。外部追踪/WebDAV实写仍缺具体授权。
- C125新增原始验签xkcd1.6.0、Webtoons1.6.2真实阅读与独立续页，Json注册/JSON-Okio ABI缺口已修；不代表全仓库。真实MangaFire challenge识别及可见WebView双API通过，但API35站点封禁/API26未完成验证，缺成功恢复与会话复用证据。

## C125 最终包补验与边界

C125 最终桌面包已实现可见、可取消的 WebView2 网页解析：真实父页普通链接导航生成 Referer，嵌套 iframe 媒体消息转交顶层后仍做 HTTP(S)、userinfo、视频后缀与占位流校验；45秒 deadline、取消/迟到丢弃、默认 TLS、弹窗/权限拒绝保留。真实 7sefun 推荐→候选→两个播放列表→列表4第01集已进入 media_kit 原生播放器，正片画面0:17/23:40；正常重启后历史58秒持久化已核实，实际重开视频 seek 尚未验收。不宣称 AGE 或全站兼容；专用认证请求头拒绝，媒体 Cookie 传递未实现，网页下载仍拒绝。

历史Windows ZIP `3ac7d53d` 的MangaDex真图/8/88目视恢复、LK缓存及合法TXT/EPUB保留。当前 `49550404` 完整50成员匹配Release；最新AX211章、8/88→9/88及新进程9/88，LK10/10、HTTP不可用缓存/小说重启文字锚点已观察。清空代理普通在线重载成功；7sefun保存193秒→新进程播放器3:13/23:40，不称真帧目视。应用HTTP不可用不是主机全网断开，不证明LNS/APK/视频离线；图片/勾选视觉待复核。

C125 续播修复前旧设备验收release为123961800字节，SHA256 `52c391bd5ecf25e03d74981718aaad8505af570b7f87067085960510919b28b3`，旧debug证书 `0b70a33046b49ce49e6d43c68efa6d9c80b1c56cc88e7aec113fa737ee72afa6`；正式release为123965896字节，SHA256 `acc302287b6f69468004ec608c0b2b89b8be6e6c244804d32726c660799944a9`，RSA4096证书 `9b474750e4c2af300eb5a0207bfb9e477030f22bb390a7da7a40d3854edec077`。两包均单签名/v2通过，分别保留数据安装到5554/5556与5558，安装hash再次匹配。双API在未替换目标release下用targetContext.classLoader通过Preference、真实Zstd、Injekt Json/JSON-Okio StringSerializer三项ABI；正式设备未运行debug签名instrumentation。最新旧设备包保留LNS缓存/字体并恢复2/10、3/13；正式包MangaDex真实阅读恢复3/32，网络Connection closed经普通重试恢复。该轮缓存续读不代表重新联网登录或全部内容形态生命周期通过。

C125 补充已安装release真实30分钟耐久：1811.6秒、58次reader进出、464次输入动作、11次HOME/resume、5次独立强停重启、58次资源采样、新崩溃标记0。PSS183530–226737KiB，首/末10样本中位210051/205220KiB，线程49–67；FD采样被OS拒绝记null。使用更早C125验收构建（交接记录hash前缀189b42），不是最终52c391包；reader/JS逻辑后续未改。页码指标不证明每次图片解码，464不称全部有效翻页；未强制断网或切章，不证明小时级无泄漏，见 `C125-release-endurance-api35.json`。

当前刷新修复后交付46df9ad2/8c5cf8c9 APK及4bfde845 Windows目录/ZIP秘密扫描：1115源码/日志/证据文件、530/530/50/50成员，零已提供账号/密码/签名秘密，无私钥/调试文件；范围见最终秘密扫描JSON。CF豁免且not-completed，其余补验gatepartial。

正式RSA4096签名最终包acc302在5558补齐匿名公开LK旅程：真实热门/10章目录、下载管理已完成10/10（目视）、第一话73页→实际翻页3/73→HOME/resume仍3/73→无默认网络强停独立重启经离线详情恢复3/73中文正文（目视）→第二话1/56加载。网络恢复，未替换为测试包、未登录/扣费或调用LNS导出，见C125-signed-novel-final-journey.json。

## C107–C109 历史补验

发现默认真实AGE，漫画默认MangaDex；两处取消「全部」，发现固定封面网格且不继承书架列表设置。漫画中文搜索「烙印勇士」命中、211章、连续换章、APK更新后强制重启仍恢复第0.02话4/69页。最终640项Flutter/83项Python回归，analyze无问题。详细记录见[C107–C108](delivery/C107_C108_DISCOVER_MANGA_ACCEPTANCE.md)。用户仓库签名调查成功仅证明真实包与仓库键一致，不能证明应用执行兼容。

此前52c391最终验收包已完成扩展30分钟耐久1819.5秒：38次真实reader进入、152输入动作、104次小说页码变化、13次LK切章、8次HOME/resume、4次独立重启、2次无默认网络断网强停恢复LNS2/10且中文字体目视可读，网络全部恢复。38资源样本PSS189101–227692KiB，首/末10中位207905.5/211642.5KiB，线程48–65，新崩溃标记0，FD拒绝记null。长测12次Webtoons循环以竖滑操作已保存LTR模式，未证实漫画翻页，整体保留partial；短专项横滑4/13→5/13→6/13及强停恢复6/13真图通过，不回填为长测有效翻页。此长测早于续播修复，不冒称新307f27包30分钟通过。见C125-release-endurance-final-api35.json、C125-final-webtoons-short-journey.json。

历史2026-10-11续播修复及14项回归：章节时间按来源/作品隔离，Android prepared后seek/准备期不写零，Windows Media.start。307f27/8c913420/d12625为代理导航前包，正式4:32/24:17/验收9:39/23:40真帧及原产物数据保留 `C125-player-resume-final.json`、artifacts.json、windows-bundle.json；当时Sky限制已过时，当前产物和最新观察见综合JSON。

新307f27验收包API26离线专项通过：正常Wi-Fi设置开关关闭与svc data关闭，dumpsys无默认网络，强停独立进程经离线详情恢复LNS3/13，真实中文正文及字体已目视。Wi-Fi/data恢复到原值，默认网络105，见C125-player-resume-api26-offline.json/png。

CF豁免保持；用户确认LNS服务器故障且Mixn也不可用，当前在线可达性排除交付门槛，不再重试；原失败、官方权限、离线字体缓存证据保留不伪称成功。Windows旧字节旅程/当前刷新产物范围仍按综合JSON；独立主线按用户要求继续，真实媒体/视觉待验收，gatepartial不改。

P1/P2当前源码：资料身份关联/别名/最后来源可随备份恢复，真实API35稳定追番/列表4第01集独立恢复已观察。Kazumi API模式现支持GET/POST JSON/form、受限JSONPath、nested/delimited及播放页模板，未执行动态脚本。Sorani真实API35规则镜像检验/安装/重启、中文第一季14集目录通过；双Android可见7sefun验证浏览器已打开/返回，不等于验证码成功。Cookie仅浏览器持久化与瞬时请求内存，禁止进备份/日志；逐跳HTTPS防降级/跨站认证头泄漏。Windows公共API协议可用，Android会话桥不冒称桌面验证已实现；生产签名/桌面当前仍是C125刷新文件，不用旧包冒称P1/P2字节已交付。

P4 C128恢复型下载：HLS初始化/byte-range/嵌套master/校验分片/纯本地清单、渐进强ETag续传、暂停重启恢复与磁盘空间已接生产。Android网页下载解析与在线播放隔离；Windows网页下载仍拒绝。实际Mux跨进程只补56缺失片、64片离线禁网络协议解码；原API35小林列表4第01集完整474.1MiB、无默认网络强停后20:44→22:25/25:11应用续播。截图不当目视通过，API26/正式/Windows最终媒体验收待证。最新双API开发包c863735e与C125发布文件不同，5558仍C125正式版本。

P5 C129公开资料：推荐筛选使用官方v0搜索POST/日期/标签/类型，历史季按上游放送星期分类且未注明保留；详情各分区调用公开info/characters/persons/subjects/episodes与next.bgm.tv comments，无第三方私密签名/认证。关联作品保持独立subjectId；每区缓存到SQLite并备份，断网不取消播放来源入口。API35真实2017Q1/角色声优/Staff/关联/评论/剧集信息/历史周三及无默认网络重启缓存通过；API26/正式/Windows/视觉不据此全通过。

P6 C130漫画Feed：每源榜单/保存搜索不混分页/来源身份，APK保留原hasNextPage和完整FilterList状态，停用/移除不删配置。MangaDex APK zh-Hans真实FilterList“Has available chapters”改值后搜索、重启恢复通过；开放规则热门/更新与排序重启实证另存。相关推荐只在插件supportsRelatedMangas且未禁用时调用原fetchRelatedMangaList；当前实测MangaDex未提供，明确提示并提供手动搜索，不生成其他站假推荐。备份含Feed/过滤/排序/删除标记；同时间戳本机优先。仅所测源，不称整个APK仓库均兼容全部Filter扩展。

P7 C131阅读器：sourceId+remoteId隔离覆盖设置，模式/横竖屏/触摸/均匀边裁切/宽屏双页/滤镜/条漫自动滚动/解码预算和预载消费真实图像/视图；在线与离线同一路径。当前真实MangaDex规则漫画横屏双页1→3/14及普通重试重启3/14、设置持久已有AX运行证据；不把AX勾选当图像处理目视、不以单作品宣称全部大图/条漫/无障碍通过。

P8 C132更新：原API35真实MangaDex开放规则与zh-Hans APK各一本，受限网络两项deferred，放开当前网络后前台及独立Job7401两源成功，新增0章不生成伪通知。每请求/目录提交用最新启用注册表，空/身份冲突拒绝且保留旧目录/未读。真实后台使用MihonHost.request与JS worker，不冒用番剧Job7301证据。通知代次去重消费者通过；真实封面通知/新章自动下载及系统重启低电仍待。

P9 C133：漫画多源合并保留原sourceId/remoteId、原章节归属和请求能力，默认完整并列，不以同名/章号自动断言等价。人工映射后按优先级选可读版本；不同版本位置单独恢复，真实API35规则3/14与APK1/14已观察。迁移锁章拒绝、文件只有原bytes/SHA256验证并复制校验后发布；已有目标合并保留目标目录/进度/较新历史，追踪冲突拒绝。真实保存计划与强停后执行completed通过，实际文件复制仍消费者范围，不能据此称全源/全平台迁移通过。

P10 C134追踪：同步只接受明确服务/远端条目绑定；稳定番剧subject和漫画合并主作品作为身份，不能拿任意来源同remoteId替代。新手动绑定不上报，双向页显示冲突和评分/状态/进度并要求二次确认。Bangumi episode与book ep_status、AniList GraphQL已接；无真实远端写授权，不能称服务端互通通过。

P11 C135备份：账号Cookie/session/token/password及整个WebDAV本机配置不导出，设备SAF授权/定时任务配置也不跨设备套用。封面当前只在导出时抓取进ZIP，导入不接入应用图片缓存；不可用源只恢复停用元数据，下载只恢复暂停索引，不伪造已有文件。真实Android7501无网络SAF导出、系统选择现有ZIP及本机优先恢复已观察；云端版本存储只在loopback真实HTTP验证，不以协议夹具声称第三方云账号上传成功。历史产物保留，当前同源码C139三产物另见发布证据。

P12 C137无痕：只能承诺新打开阅读/播放会话不持久新进度/历史、不自动上报站点或追踪。仍访问来源/缓存，保留旧阅读数据，不提供网络匿名、缓存擦除或应用锁。原API35仅缓存小说打开退出无写证据，漫画正文加载来源拒绝与视觉前提缺失保留；消费者翻页/退出/播放位置回归通过，不据此称实际全媒体无痕通过。

P12 C138补证：API35最终无探针包中前台与漫画后台JS独立进程并存，Job7401完成只结束后台worker；普通MangaDex首个at-home请求超时，显式重试成功、实际页码3/14→5/14，无痕退出历史逐行不变。开关还原；未计图片视觉、API26并行漫画和视频无痕通过。双API开发包现为e8f9384c。

P11 C140补证：封面ZIP实际恢复、本机图片优先和离线再导出已接；API35系统选择公开封面包→确认→重复导入，62396字节SHA256一致、原未读/进度保持。只持久恢复的封面，不把普通网络Image加载当完整持久缓存；失败可留下未使用缓存。当前同源码开发5542c2dc/正式0447f966/WindowsZIPbb19be89已构建校验，桌面行为与图片视觉仍未验收。

P11 C141：备份恢复不再依赖archive的verify参数或已合并条目集合；原中央目录重复名、大小、CRC和符号链接在写入前检查。API35系统选择损坏ZIP实际拒绝，原书架状态保持；16定向/794全量/analyze通过。当前同源码开发f32bd466/正式2d85317a/WindowsZIP8448347c校验与原三台保数据安装hash匹配、秘密零命中；不是下载媒体可携带、第三方云互通或全平台视觉通过。

P11 C142：真实API35前台和独立Job7501经本机流式ZIP→SAF文件复制生成新备份，manifest SHA/ZIP完整性及6收藏4013目录19历史正确，本机成功副本已清理、原关闭排程还原。SAF源限应用私有文件；不改小说导出权限，不做远端上传。当前验收037d3842/正式43c5da85/Windows ec59c884三产物验证，下载媒体/流式导入和最终平台视觉仍待。

P11 C143：本地恢复校验私有快照、原中央目录及磁盘条目SHA/CRC，原条目路径永不直接提取；确认前后hash不一致拒绝写入。API35最终包系统选C142实际ZIP→预览合并6本机收藏保持未读进度，临时输入清理。18定向/796全量/analyze；当前三产物b68fa68f/429d1a4c/14c98cdf验证，不代表下载媒体/云互通或视觉通过。

P11 C144：完整下载文件现可由明确本地媒体备份选项携带；漫画/HLS文件名严格相对、HLS检查全部依赖及SHA，原设备路径/resume凭据不迁移，已有任务不覆盖。实际API35原公开7sefun视频经ZIP子集到API26，497133814字节hash一致，下载1/1和真正无默认网络强停续播0:49→1:20已观察；3旧夹具文件不计公开站成功，host解码不是目视。部分字节仅暂停索引、云端仍未授权，当前14c83151/70efadac/e42d61b5三产物与秘密校验通过。

## C148 当前来源与离线边界

- Windows新增可见手动验证，provider+精确HTTPS origin隔离WebView2 profile；仅显式Save后复用原生精确URL HTTPOnly Cookie，真实响应Set-Cookie更新/注销。跨origin交互导航/弹窗/权限拒绝，默认TLS；不从页面读取伪造Cookie，不把来源profile复制给视频profile。
- Windows网页下载接前台可取消解析、任务owner与原生关闭屏障；逐跳Cookie精确查询、HTTPS降级/跨站认证泄漏拒绝，无前台/锁定/停用暂停。代表性消费回归通过，真实桌面Cookie/冷启动/profile共享/站点下载仍未实跑，不能将构建成功称为浏览器验证成功。
- 本地漫画保留独立文件索引；记录清理不删除有路径媒体引用。离架导入仍可管理，重复导入恢复缺失书架、不覆旧进度；无账号/网络即可阅读。备份预览采用实际有界流式解压，完整媒体补本机缺字节恢复占位，不覆盖已有下载。
- 最终952项通过/3OS权限跳过，analyze无问题；原证书双Android/正式和Windows包已刷新，原设备数据保留。完整证据与P1–P12余项只以[CURRENT_STATUS](CURRENT_STATUS.md#剩余主线)和[C148最终证据](delivery/evidence/C148-P12-final-acceptance.json)为准；本文件以上C125–C144为历史证据。
