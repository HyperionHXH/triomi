# 弹幕来源、Kazumi功能对照与三源实施

## 当前状态

2026-10-24：菜单/评论修复后，用户选择B站＋Animeko，并追加非B站覆盖及Kazumi相关功能；随后明确本轮只做观看与设置、不做发送。现已增加Gamer动画疯第三来源，三源可独立组合，生产播放器两端均实网显示无B站目录作品的弹幕。最终版本、运行边界与发布结果统一见[当前状态](CURRENT_STATUS.md)。

旧弹弹play客户端、账号凭据入口及发送操作已删除；来源协议中的 `content.danmakuUrl` 仅保留序列化兼容，播放器不再消费该旧来源字段。匿名读取B站、Gamer动画疯和Animeko，不提取其他应用私有身份或使用用户账号。既有显示参数和屏蔽设置继续持久化，旧安全存储值不主动删除。

## Kazumi真正使用的来源

固定参考提交：`Predidit/Kazumi@1e3e111553b74c07f4412fa8a0e7959821caa789`。

- [DanmakuApi](https://github.com/Predidit/Kazumi/blob/1e3e111553b74c07f4412fa8a0e7959821caa789/lib/request/apis/danmaku_api.dart)仍通过弹弹play搜索、匹配及comment接口获取弹幕；来源选择不意味着Kazumi端自行实现了所有平台的采集。
- [DanmakuClient](https://github.com/Predidit/Kazumi/blob/1e3e111553b74c07f4412fa8a0e7959821caa789/lib/request/clients/danmaku_client.dart)发送应用身份与请求签名；[构建凭据入口](https://github.com/Predidit/Kazumi/blob/1e3e111553b74c07f4412fa8a0e7959821caa789/lib/utils/dandan_credentials.dart)不是可供其他项目复用的公开密钥。
- 因此，本轮排除复用Kazumi身份或再包装未经许可的弹弹play代理，不把开源绘制层误当作免费弹幕数据服务。

## 方案A：Animeko独立弹幕池，最轻量

固定参考：`open-ani/animeko@2f2c4d63bdf86c15775a32b525a40bdcd5b0ed32`。

[项目说明](https://github.com/open-ani/animeko/blob/2f2c4d63bdf86c15775a32b525a40bdcd5b0ed32/README.md)明确区分弹弹play聚合与Animeko自己的弹幕服务。[公开API客户端](https://github.com/open-ani/animeko/blob/2f2c4d63bdf86c15775a32b525a40bdcd5b0ed32/client/src/commonMain/gen/me/him188/ani/client/apis/DanmakuAniApi.kt)中，读取`GET /v1/danmaku/{episodeId}`不要求认证，发送则要求用户JWT。[提供器](https://github.com/open-ani/animeko/blob/2f2c4d63bdf86c15775a32b525a40bdcd5b0ed32/app/shared/app-data/src/commonMain/kotlin/data/network/danmaku/AniDanmakuProvider.kt)直接使用Bangumi分集ID，响应为`danmakuList`，播放时间以毫秒表示。

本机实际匿名读取结果：

| 作品 | 正片集数 | Bangumi分集ID | 返回弹幕数 |
| --- | --- | --- | --- |
| 葬送的芙莉莲 | 1 | 1227087 | 83 |
| 葬送的芙莉莲 | 12 | 1227098 | 18 |
| 葬送的芙莉莲 | 28 | 1257306 | 92 |
| 孤独摇滚 | 1 | 1128641 | 108 |
| 孤独摇滚 | 12 | 1128652 | 213 |

两个官方源码节点`danmaku-cn.myani.org`与`danmaku-global.myani.org`对芙莉莲首集均返回200及相同83条；本机无代理直连也成功。**这两个是同一弹幕池的节点，不能把83+83当166条。** 其余四样本通过本机已有代理读取；不以单主机样本推断所有手机网络可达。

优点：无需自己部署服务器，也不需要弹弹play应用身份；可以复用已确认的Bangumi分集关联，匹配歧义小。缺点：所测弹幕量明显较少，不能保证新番、冷门番、所有分集都有内容，也没有本项目第三方使用SLA。公开文档的匿名读取能力不等于无限制使用或永久可用承诺；发布接入时需遵循服务方使用条件、明确来源并控制请求频率。首版适合只读，不借用Animeko登录身份发送。

## 方案B：B站直取 + Animeko补充，推荐的无自建服务器路线

本机用公开元数据正常读取、不带账号Cookie或其他应用身份：

1. [bangumi-data](https://github.com/bangumi-data/bangumi-data/tree/94ea82be75d9e617c7970bb0fd0670ae5c60e53d)的`data/items/2023/09.json`将Bangumi作品400602映射到B站**媒体ID**21087073；它不是season_id。
2. B站媒体元数据返回季度46089，季度接口真实返回芙莉莲条目及剧集；首集`ep779775`、`cid1339446971`、`aid450096728`，标题“冒险的结束”。季度返回还包含其他类型条目，不能直接把数组下标当正片集号。
3. 读取`comment.bilibili.com/1339446971.xml`实际返回压缩XML，解压后355,318字节、**3,600条**弹幕。该XML是可取得的快照，不声称全部历史弹幕。
4. 读取B站`x/v2/dm/web/seg.so`同CID的第一段，正常返回198,208字节protobuf；按字段解码得到**1,682条**，这是**前六分钟分段**，不是整集总量。不能与XML数直接相加当独立弹幕。

优点：本样本弹幕更密，端上请求不需要常驻自建后台；Animeko可以补充另一独立社区来源。缺点：B站版权覆盖、下架、地区、风控、接口变化会影响可用性；与播放站的片头、删减、字幕版本可能不同，需要明确季度/正片映射与时间偏移。仅完整映射时自动选择，歧义时让用户选，不按站内ID猜测；不绕过访问限制。B站读取是非稳定开放平台契约，不承诺所有番剧都能匿名获取。

已按用户选择实施：播放器「播放设置 → 弹幕 → 来源 / 匹配」可选两者、单源或关闭，分别显示真实分集、条数、加载与错误状态；可纠正B站官方ep/ss/md链接，选择真实分集并按源调节秒数偏移。未关联Bangumi季度时明确查找关联，不用播放站ID或标题猜测；特别篇/编号歧义要求手动确认。任何一个来源失败不阻塞视频或丢弃另一来源，合并前按毫秒时间与正文去重。

## 方案C：自托管多平台聚合，可完全关闭dandan源

固定研究：[`huangxd-/danmu_api@5ef63a01bae7c4bad4dcd7bafbbcdcf33aa82564`](https://github.com/huangxd-/danmu_api/tree/5ef63a01bae7c4bad4dcd7bafbbcdcf33aa82564)，该提交日期2026-10-18。

[说明](https://github.com/huangxd-/danmu_api/blob/5ef63a01bae7c4bad4dcd7bafbbcdcf33aa82564/README.md)、[源注册表](https://github.com/huangxd-/danmu_api/blob/5ef63a01bae7c4bad4dcd7bafbbcdcf33aa82564/danmu_api/sources/registry.js)和[配置样例](https://github.com/huangxd-/danmu_api/blob/5ef63a01bae7c4bad4dcd7bafbbcdcf33aa82564/config/.env.example)显示：

- 支持多个平台、Animeko和本地文件，提供兼容形状的搜索/详情/comment接口；**兼容弹弹play JSON格式不等于依赖其数据服务**。可以在`SOURCE_ORDER`只选非dandan来源，未配置的dandan不需要启用。
- 可用Node18+、Docker或serverless部署，但仍需要自己拥有并维护服务地址、访问token、资源配额和升级；手机访问电脑上的服务需同网络可达，`127.0.0.1`不能指向另一台机器。
- 平台可能分别需要Cookie、地区可达性或其他权限，部署不能消除这些条件。不能复制上游包含的其他应用身份、签名秘钥或不明归属中转地址来保证“全平台”。
- 实际仓库`LICENSE`为AGPL-3.0，而package.json写ISC，存在元数据不一致；不能仅凭npm字段就把整个项目按ISC并入。
- 本轮核查了源码及配置，**未部署该聚合服务，也没有完成各上游搜索→选集→整集弹幕实测**。因此这是可选架构，不是开箱可用或免费稳定的已验收方案。

适合愿意承担服务维护、希望后续逐个平台扩展的情况；不建议为本轮基础弹幕强行引入常驻后台。

## 方案D：本地XML/JSON导入，离线补充

不需要服务器或弹弹play身份，但用户需自己合法取得并选择每集文件。可以提供手动集数绑定及时间偏移；它不能替代“播放即自动匹配联网弹幕”。Triomi目前**没有**文件选择/XML解析接线，不能当作已支持。

## B方案实施与验收边界

- B站只请求官方季度/媒体接口与protobuf分段；按上游时长读取全部6分钟分段，两并发、最多24段，单段2MiB、单集8MiB/30000条。任一分段失败整源报错，不把部分读完冒称完整；XML快照仅用于研究，生产不以它回退。正常API也只是站点当前公开返回，不保证全部历史弹幕。
- Animeko按真正Bangumi分集ID匿名读取；仅CN节点网络/超时可回退global，同池不叠加。认证、限流、解析错误保留，空成功不当作错误。
- Hybrid与Gamer各自内存TTL5分钟、最多16项/2MiB，合计预算4MiB，不创建视频或弹幕磁盘缓存。手工匹配与有符号秒数偏移按作品＋章节最多128项。切集、重试、关闭与退出取消旧owner并隔离迟到响应；独立切换一个来源不清空其他来源。倍速、暂停、seek和迟到加载沿真实视频时间轴绘制。
- 生产客户端实网：芙莉莲subject400602映射md21087073→ss46089→ep779775/cid1339446971，读取整集7361条，末条1559.658秒；Animeko分集1227087为83条。随后Windows实际播放器7359＋83条、Android7357＋83条；动态公共接口不同请求条数会变化，不当作固定总量断言。
- 两端实际播放自建六分钟媒体并在真实生产绘制层显示远端弹幕、展开来源面板。Android触摸单源/关闭/恢复双源、切第2集立即清旧弹幕并重新读到B站5688＋Animeko30条；本集B站+2.5秒偏移真实输入保存，另一来源仍0秒。原用户设备、账号及资料未动，专用AVD/临时入口已清理。不是任意网站、全部手机或地区可达承诺；非B方案仍只是研究，不冒称实现。

## 非B站覆盖：Gamer动画疯

固定映射：[bangumi-data@94ea82be75d9e617c7970bb0fd0670ae5c60e53d](https://github.com/bangumi-data/bangumi-data/tree/94ea82be75d9e617c7970bb0fd0670ae5c60e53d)。其中2023/04的《百合是我的工作！》Bangumi381666没有任何B站地区站点映射，Gamer的ACG ID为128544。官方搜索精确核对ACG→animeSn113239→videoSn33254，再验证视频详情中的三种身份与全部12集；不拿ACG ID当animeRef或视频ID，不按相似标题自动串作品。目录缺少站点映射不单独作为法律授权结论。

官方[播放器脚本](https://i2.bahamut.com.tw/build/js/anime_player.js)本轮SHA256为`808699c5419999781f1b6833184551e5ee4ded53cac017521792b1af9b63d9d5`，默认弹幕池TW、HK对应播放页“彈幕來源顯示”的台湾／港澳复选框。`geo=TW,HK`是弹幕来源池筛选，不是伪造客户端地区；不改节点/IP或请求身份。此前漏参数时的“無效的地區”错误现已纠正，不能当成地理封锁实证。

生产客户端真实读取`videoSn33254`返回985条、0–1420秒、三种正常模式；时间十分之一秒转换成秒，位置0/1/2映射滚动/顶部/底部。Windows与Android生产PlayerPage均显示B站无季度、Animeko4条、Gamer985条；自动续到第2集后两端分别显示Animeko3条和Gamer726条，旧集清除。三源独立开关已实操，关Gamer不丢Animeko。单响应2MiB、最多30000条，完整数量与totalCount必须相符；HTTP/应用错误不变成空成功。

## Kazumi观看与设置功能对照

参考同一固定Kazumi提交的[设置页](https://github.com/Predidit/Kazumi/blob/1e3e111553b74c07f4412fa8a0e7959821caa789/lib/pages/settings/danmaku/danmaku_settings.dart)、[播放器设置](https://github.com/Predidit/Kazumi/blob/1e3e111553b74c07f4412fa8a0e7959821caa789/lib/pages/settings/danmaku/danmaku_settings_sheet.dart)与[来源选择](https://github.com/Predidit/Kazumi/blob/1e3e111553b74c07f4412fa8a0e7959821caa789/lib/pages/player/danmaku_source_sheet.dart)。已实现：

- 即时显示开关、区域0–100%、滚动/顶部/底部、字号10–48、字重1–9、透明度、行高、颜色开关与描边粗细。播放器和通用设置复用同一provider，不等“应用”按钮；桌面/横屏靠右圆角侧栏，手机底部滚动面板。
- 停留2–16秒、跟随视频倍速开关、碰撞航道或海量叠加（仍受20–300条屏幕预算保护）、5秒内同正文/模式重复合并；排版缓存384项，绘制帧不重复排版或复制活动列表。跟随倍速关闭只改动画速度，不错移原始时间轴。
- 本地OpenCC简繁转换复用既有单字字表；多义字并非完整词组转换。关键词/安全正则屏蔽可启停、编辑、删除、导入、导出；最多256条，每条128字符。正则限制为字符类/锚点/至多一个可变重复项，不支持分组、择一、环视和反向引用，避免非可信规则卡死UI。恢复显示默认值保留规则、用户屏蔽及来源匹配。
- 分集标题/ID筛选、真实集号定位、超过100条时分段，特别篇与编号歧义必须明确选择。B站附加section中的OP/ED/PV也可手工选；官方ep780514主题曲案例已修复，不让附加条目参与正片自动匹配。来源官方URL、各源秒数偏移、错误重试继续独立。

实际可见验收：Windows半屏区域立即生效且持久化；Android触摸半屏区域、合并重复、真实输入并保存屏蔽词spoiler，最终Prefs读回0.5/true及规则。双端真实视频/远端弹幕与长面板滚动已查看，非完整物理设备或地区矩阵。本轮按用户选择不实现发送/聊天室、账号授权和专用下载弹幕文件，也不把来源覆盖承诺成全部作品必有弹幕；视频下载功能原样保留。
