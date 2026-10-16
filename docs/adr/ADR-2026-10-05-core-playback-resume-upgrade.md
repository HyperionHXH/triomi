# ADR：真实播放、阅读锚点和原子来源升级

日期：2026-10-05。状态：已实现并完成 Android 模拟器核心验收。证据见 [C99–C102](../delivery/C99_C102_CORE_ACCEPTANCE.md)。

## 真番剧播放

Kazumi AGE 规则明确要求 WebView 与原生播放器。Triomi 不直接导入其 XPath schema；独立 JS 适配器提供发现、搜索、分线路目录及网页 PlaySource。Android 使用 headless WebView 运行站点普通 JS/WASM，获取实际 MP4/HLS 请求，交给现有原生 MediaPlayer/TextureView。保留实际请求头，默认 TLS；禁止文件/content 访问、弹窗与外部协议跳转，35 秒超时及取消。页面身份检查丢弃旧 WebView 的迟到消息。TextureView 用 contain 变换，修复竖屏拉伸。

站点错误卡由规则声明 `unavailableVideoUrls`，模型、JS bridge、离线 JSON 和 method channel 保留这一字段；resolver 不硬编码站点或屏蔽所有短片。解析失败仍能打开集数/线路目录。Android 首轮验收保留；桌面实现及真实证据见下方C125更新，不用直链fixture冒充真实站点成功。

## C125 Windows网页解析与实际媒体验收（2026-10-10）

C125 最终桌面包已实现可见、可取消的 WebView2 网页解析：真实父页普通链接导航生成 Referer，嵌套 iframe 媒体消息转交顶层后仍做 HTTP(S)、userinfo、视频后缀与占位流校验；45秒 deadline、取消/迟到丢弃、默认 TLS、弹窗/权限拒绝保留。真实 7sefun 推荐→候选→两个播放列表→列表4第01集已进入 media_kit 原生播放器，正片画面0:17/23:40；正常重启后历史58秒持久化已核实，实际重开视频 seek 尚未验收。不宣称 AGE 或全站兼容；专用认证请求头拒绝，媒体 Cookie 传递未实现，网页下载仍拒绝。

Windows WebView使用独立应用支持目录的video-webview profile。普通父页完成后仅导航目标播放页一次；iframe文档脚本把媒体事件转发顶层，顶层限制HTTP(S)消息origin，Dart继续校验地址和请求头。失败/取消/超时销毁订阅与浏览器，晚到结果丢弃。发现插件注册器陈旧时要求Flutter正规pub get重新生成，不手写生成注册器，也不改SDK/Pub缓存。

最终 Windows 包 MangaDex 211章/真实图片、LTR→RTL即时勾选和8/88页正常关闭/重启续读已目视通过。匿名公开 LK 小说10章下载均done、10章非空content_json共370355字节，真实正文及TXT/EPUB实际导出通过。续播修复前 Windows ZIP包含完整50文件/DLL/data（含webview_windows_plugin.dll），SHA256 `3ac7d53d76f8fc1ca1d65b71b5ae0ed932472eb7c3261fdb4fe9cab251b18d89`；ZIP完整性及逐成员与Release目录一致性已复核。下载管理10/10可见状态、已下载小说重启阅读和强制断网读取仍缺，不能把缓存存在等同完整离线UI验收。见 `C125-windows-final-behavior.json`、`C125-windows-exports.json`、`C125-windows-bundle.json`。

computer win32专用接口可用；Sky RPC仅历史限制。当前49550404桌面漫画9/88独立恢复、LK10/10、HTTP不可用小说缓存重启锚点及清空代理在线重载已观察；7sefun保存193秒→新进程播放器3:13/23:40，真帧视觉仍待。CF用户豁免且真实失败保留、不作门槛。本模型无法读取截图，不把AX时间/页码当视觉验收。

## 阅读恢复

沿用现有 histories 表，不搬迁收藏、不新建进度表。历史查找使用 source/item/chapter；最近章用于详情继续入口，显式点某章恢复该章。

漫画 position 为零基图片 index，短章夹紧，分页与条漫统一。小说 position 的整数为正文 block index，小数为段内 UTF-16 字符比例；TextElement 记录起始 offset，重新分页后选择包含锚点的页。旧整数仍有效，跨排版页码可以变化。源码中的段落 fallback 不能被当成真实正文验收。

读器加载序列号防止迟到覆盖，恢复期/失败/空正文不写库。保存队列捕获章与位置，远端同步异步且不能挡住本地保存；生命周期和退出尽力保存，分页翻页即时入队。强制终止后的真实恢复证据另外记录，不把单元测试视为设备证据。

## 代理、来源停用与桌面返回（2026-10-13边界收口）

来源HTTP代理仅接受无userinfo/路径/query/fragment的 `http://host:port`，影响规则/LK共享HTTP，不影响LNS专用连接、APK或原生视频。不可用代理失败闭合，不直连兜底；空设置恢复默认。最新包实际无监听127.0.0.1:49391请求失败、缓存读取及重启锚点恢复已有观察，验收后已清空；不等同Windows主机全网断开。

停用/移除来源保留详情/正文缓存，缓存可读；无缓存拒绝发起新请求，重新启用后可正常请求，行为回归见 `detail_empty_directory_test.dart`。这不宣称取消已在途请求。expanded二级页按Navigator.canPop显示BackButton，最新桌面搜索→返回→推荐已实际执行；主导航不显示伪返回。续播仍以来源/作品/章节隔离，不跨站强套时间。
验收工具history只按真实历史页“清空历史”动作辨识，不要求特定账号书名；原5554/5556/5558导航smoke通过，5558公开书可独立验证。最新三台真实无默认网络缓存恢复证据 `C125-latest-offline-20261013.json` 与前轮目视证据分开；本轮图片问答工具账号缺失，不冒称字体/真帧视觉通过。
无缓存停用→启用重新加载的行为回归暴露刷新按钮 `setState` 回调返回Future。修复为先取得_load Future、再在void setState中赋值；保持异步数据FutureBuilder和来源安全边界不变。该回归证明明确停用错误/零请求、启用后普通重载取目录，Flutter原断言不再出现；不通过忽略异常收口。

## P1 稳定番剧身份（2026-10-13）

数据库v4新增 `(subjectSourceId, subjectRemoteId, sourceId)` 确认关联；站点remoteId可空，仅保存别名不假称匹配。候选必须人工确认，同一站点作品已有其他资料归属时拒绝，避免同名季自动合并。追番写资料身份，旧站点收藏、目录及历史保留；移除关联不删原作品数据。

最近站点/列表/剧集只有播放器准备完成且剧集属于该作品缓存目录后写入。切站从零开始，不搬运原站秒数；成功保存后同站重试继续正常恢复。原播放页面换源以replace导航释放旧播放器，不叠加后台播放实例。别名、确认映射及最近选择随备份事务导出/恢复；较新本地更新时间优先，身份冲突抛错并走既有补偿，不提供兼容别名或静默覆盖。

## P2 规则协议与人工验证（2026-10-13）

API配置只使用GET/POST、JSON/form请求体、受限JSONPath键/索引/通配符及变量模板；拒绝过滤脚本/递归表达式，独立线路剧集保持原归属。原规则文本保留原下载字节，同版本修改拒绝覆盖；兼容性检验不安装，批量更新只选已安装较新版本，每站失败隔离并保留旧规则。

Android规则站点复用可见WebView，captchaType自动点击和captchaScript配置不执行，全部由用户在可见网站人工处理。保存会话只代表浏览器Cookie已保存，不代表挑战成功；取消不自动重试。请求仍用原共享HTTP/应用代理，CookieManager按准确HTTPS URL供给瞬时Cookie；逐跳解析Location并拒绝HTTP降级，跨origin丢弃Authorization/Cookie，不通过新网络客户端绕过代理。Cookie不进入Preferences/备份/报告。桌面缺少相同会话桥时明确告知，不做假会话兜底。

## P3 Android Media3生命周期（2026-10-13）

原生改用Media3 1.9.4 HLS/ExoPlayer，保持真实通过的TextureView/hybrid composition，不保留MediaPlayer双引擎及未被生产消费的纯状态复制模型。准备完成后才解禁持久进度；完成事件携真实position/duration、先保存后按同列表选择相邻下一集（锁集由加载拒绝，不自动跳过），列表末尾不串源。比例/倍速/音量/字幕设置控制实际引擎，后台音频使用同一ExoPlayer/MediaSessionService，不分配第二解码器。

直接启动服务必须显式addSession注册通知管理器；只构造MediaSession会显示系统会话但没有前台通知，真实HOME已复现启动超时崩溃。修复后Media3自行提升前台、退出解除session再release player；后台默认关闭，设置打开后系统通知/锁屏控制继续，退出播放器停止。解析取消与窗口策略携owner，旧页退出不能取消新页解析/清空新页策略。倍速/非零续播、HOME同进程/PiP/退出服务实证另存，无法视觉读取的截图不充当真帧通过。

## P4 恢复型媒体下载（2026-10-13）

HLS不拼接假视频：每个初始化段/分片/byte-range独立落盘和SHA256/长度校验，必要时序标签保留；全部完成才原子发布仅含本地引用的m3u8。缺失/损坏重新请求，nested master有界且拒绝循环；加密/未结束直播/外置音轨不完整明确拒绝。渐进文件只在强ETag、If-Range与范围/总长一致时续传。磁盘空间按目标目录检查，不足或响应残缺不能标done。

下载Android网页解析独立实例，暂停不抢占在线播放。选择子集保存完整目录，暂停状态持久；数据库流只供UI实时进度，不重建队列。渐进进度按百分比变化写库，占用仅路径/状态变化扫描。删除在途任务先停止并等待写入屏障，再重读最新路径删除，避免已删目录被旧任务重建。真实API35完整下载/断网重启应用续播、公开Mux跨进程缺失补下与禁网络协议解码证据见C128；视觉/其他平台不据此冒称全部通过。

网络异常优先读取Dio结构化类型/response状态；普通异常仅明确HTTP/status词后的完整状态码参与分类，端口/资源编号不能冒充401/403/404/429。连接拒绝误判限流已由全量测试捕获并定向回归。

## P5 公开资料筛选与失败隔离（2026-10-13）

趋势榜保留固定backend分页；有筛选时使用公开v0搜索，原始rows推进offset，类型/敏感条目过滤不改变游标。切筛选/刷新generation隔离晚到页。季度以含首日/不含下一季度首日表示，第四季跨年；历史季只按上游放送星期分类，未提供星期不按首播日期猜造。

资料、角色声优、Staff、关联、评论、剧集分区按需加载、错误/分页独立，不加入播放来源身份映射；关联动画导航到自己的Bangumi subject。SQLite既有detailJson保存按分区/offset的公开数据，并发分区事务重读后合并，既有mediaItem刷新不清缓存；随既有备份导出/恢复，旧备份缺字段保留本机缓存。缓存回退明确显示，资料失败仍可关闭分区后选播放来源；只用公开读取，不携带用户token或上游私密签名。

## P6 漫画Feed与原始筛选（2026-10-13）

SQLite v5保存来源键、榜单/查询、原FilterList结构值、排序和hidden tombstone，停用来源不删配置；默认播种检查包括hidden的所有ID，删除不被下次打开复活。排序事务校验完整ID集，同秒备份冲突本机优先。Feed按每源独立请求/分页/错误，APK使用真实hasNextPage；不合并不同来源的作品ID。

宿主以插件新getFilterList复建对象，再校验名称/类型/选项并写回状态后getSearchManga；类型支持原文本/单选/复选/三态/分组/排序及AutoComplete，有界深度，不执行额外脚本。保存值不匹配更新后形状时拒绝，用户重新编辑。相关推荐读取原supportsRelatedMangas/disable标记并调用fetchRelatedMangaList，结果仍属于原来源；不支持时仅人工搜索。原设备动作/仓储边界见C130，不据测试标全仓库兼容。

## P7 每作品阅读设置与图像预算（2026-10-14）

每作品覆盖使用JSON编码sourceId/remoteId键，未覆盖模式/适配/背景继承旧全局设置；复用Hive watch和备份，不存新用户凭据。均匀边裁切只识别黑/白且连续整行/列同色，最多每侧20%；像素扫描在compute隔离，解码尺寸上限宽2400/高8192。统一ImageProvider本地/网络生命周期和CustomPainter，滤镜矩阵只作用图像。双页在宽600以上且非条漫生效，页码/持久化仍以图片索引而非spread编号。

缓存24–256MiB限定Flutter解码缓存，正在可见的图片另占内存，不承诺整进程总内存同值；退出恢复原预算。预载0–8顺序读取，停用/锁章/旧requestSeq拒绝；条漫自动滚动仅前台、已载入且控制条隐藏时推进，退出取消timer。相同章/页不重复排队写历史；错误可重试，不清已有位置。真实设备范围C131，像素/自动滚动/全平台剩余专项仍partial。

## P8 持久漫画更新与后台所有权（2026-10-14）

SQLite每作品(sourceId,remoteId)保存queued/running/deferred/failed/success、目录新增数、检查时间和通知整数代次；Unix秒无法唯一表示同秒更新，通知使用generation/notifiedGeneration而非时间比较。发送前事务预占，崩溃允许漏提醒但不循环；新章事件实机待。新目录只有身份唯一、非空、来源仍启用且约束满足后事务提交，取消晚到结果回queued不替目录。初次目录为基线不把全部旧章算新章；自动下载失败保留目录success并单独提示。

专用持久Job7401/12小时，不覆盖番剧7301；后台真实MihonHost/JS worker、Hive/安全存储/补偿恢复/数据库初始化，结束取消资源，9分钟上限保留durable队列。Android原生owner锁跨Flutter引擎，下载另锁避免前台泵与后台抢同文件；Windows更新用OS文件锁。测试宿主用实际Platform.isAndroid，不用模拟UI defaultTargetPlatform触发原生锁。自动下载只消费自身持久ID列表，ID设备相关不入备份；停用/约束重查、无权限不绕通知。证据与剩余范围见C132。

C149补验：API26动态自有loopback新增章通知、自动下载PNG/hash及独立进程离线真图、约束/取消重试已有消费者证据。最终正式包系统重启先确认JobStore异步写入ABX，app未启动且无PID时7401/PERSISTED/12小时及原网络电量约束已恢复；立即重启早于系统落盘曾丢任务，保留该边界，不改生产掩盖。原关闭策略通过UI还原，系统注册及落盘7401均消失。恢复注册不等于已执行定时网络更新，见`C149-final-acceptance.json`。

## P9 可恢复范围迁移与合并原章归属（2026-10-14）

迁移计划将范围、明确章节映射、源/目标结构快照SHA256、完整旧版图片manifest及逐文件SHA256持久化；快照只存hash，不把可能的私密正文复制进计划。显式执行/恢复读取最新记录并事务CAS，不满足拒绝；文件复制到计划自有路径且逐项校验后才发布download row，旧文件与所有原记录保留。目标已有记录需显式mergeExisting，保留目标进度/较新历史/既有目录，追踪不同remoteTrackId原子拒绝；普通跨站映射页码0，只有已复制相同文件才保留旧位置。计划不自动导入到别的设备（路径/快照设备相关）。

合并引用是人工确认的作品成员顺序与章节等价组，不创建假来源或改写原Chapter。默认每章保留sourceId/remoteId，只有人工等价组允许按优先级选择未锁可读版本；每次content/预载按原章来源解析，历史/进度按原作品owner写入。合并reader跳过saveChapters以免把跨源章搬进主作品目录；进度去重含sourceId防相同remoteId串章。删除关系用空members墓碑且时间单调，备份同秒本机优先/旧备份不复活。证据与剩余实际文件/视觉/全平台范围见C133。

## P10 双向追踪的显式写入与稳定身份（2026-10-14）

被动阅读/播放上报继续只增不减、失败不阻塞；新绑定默认manual-only，用户必须在同步预览页确认具体服务、远端条目、状态、评分和进度后才允许写入。预览读取远端快照，提交前重读本地绑定/进度和远端快照，冲突拒绝；写入按服务串行限速，写后再次读取确认。Pull只提升本地进度，保留单次撤销快照并在后续变化后拒绝撤销。

追踪身份优先使用P1稳定番剧subject，漫画使用P9人工确认合并主作品；不按标题、remoteId或页码猜身份。Bangumi动画逐集PATCH、书籍/漫画ep_status，AniList GraphQL状态/进度/评分。凭据SecureStore优先、旧设置迁移兼容、备份过滤；没有用户指定目标与授权不进行真实远端写动作。证据C134。












## 来源升级

更高 SemVer 才允许更新；下载校验 raw bytes、HTTPS 每跳、2 MiB、可选 hash、UTF-8、schema/身份/版本/能力。临时 JS runtime 完成初始化后 dispose；唯一写入是 repository CAS 事务，保留 kind/enabled/id/关联收藏/缓存/历史。用户下载期间编辑或移除来源时拒绝覆盖。

不先卸载旧来源，不让更新失败造成半安装，不自动运行已装规则升级。用户在目录查看版本并点击更新。内置 compiled adapter 不接受规则替换。签名认证及任意恶意同步 JS 的强制终止不属于本次事务升级，沿 [ADR 001](001-js-execution-isolation.md) 继续推进。

## 本轮范围

发现第一、漫画小说统一书架、独立追番的产品结构继续执行。优先把真实内容链路做可靠，不扩展 OCR、社交等方向。GLM 接具体分页/文案/回归，Codex 保留播放协议、运行隔离与跨模块状态工作。

此前52c391最终验收包已完成扩展30分钟耐久1819.5秒：38次真实reader进入、152输入动作、104次小说页码变化、13次LK切章、8次HOME/resume、4次独立重启、2次无默认网络断网强停恢复LNS2/10且中文字体目视可读，网络全部恢复。38资源样本PSS189101–227692KiB，首/末10中位207905.5/211642.5KiB，线程48–65，新崩溃标记0，FD拒绝记null。长测12次Webtoons循环以竖滑操作已保存LTR模式，未证实漫画翻页，整体保留partial；短专项横滑4/13→5/13→6/13及强停恢复6/13真图通过，不回填为长测有效翻页。此长测早于续播修复，不冒称新307f27包30分钟通过。见C125-release-endurance-final-api35.json、C125-final-webtoons-short-journey.json。

历史2026-10-11续播修复：按来源/作品/章节查chapterPositionOf，Android prepared后完成seek再播放、准备期禁止覆盖历史，Windows Media.start，Android不分配无用media_kit。14项回归和原307f27/8c913420/d12625包/真帧证据保留 `C125-player-resume-final.json`、artifacts.json、windows-bundle.json；这批是代理导航前历史范围，不用旧hash或Sky限制代表当前交付。

新307f27验收包API26离线专项通过：正常Wi-Fi设置开关关闭与svc data关闭，dumpsys无默认网络，强停独立进程经离线详情恢复LNS3/13，真实中文正文及字体已目视。Wi-Fi/data恢复到原值，默认网络105，见C125-player-resume-api26-offline.json/png。
