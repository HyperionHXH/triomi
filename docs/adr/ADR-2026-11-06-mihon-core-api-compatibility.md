# Mihon 核心插件 API 兼容基准

## 问题与证据

Android 0.14.0+180 装载原始 Jinman Tiantang 1.6.64 APK 后，搜索在
`getFilterList()` 阶段抛出 `NoSuchMethodError: FilterList.<init>(List)`，尚未发出
搜索请求。同 APK 在 Komikku 可以搜索。实际插件还调用宿主缺失的
`HttpException(int)` 和 `getCode()`。这是 Android 宿主 ABI 差异，与 iOS JS
规则实现无关。

## 决策

以 Komikku 提交 `64aeb48f31a211e734dafe6c838ae2c712ae69e2` 的核心 source-api 1.6
为固定基准，保留 Triomi 的加载、发布者核验、逐请求取消与网络策略。对齐模型、
Rx/suspend 桥接、HttpSource/ParsedHttpSource 及插件直接消费的网络帮助接口，
保留已经公开的旧构造入口。

`HttpException.code` 可以是插件自行构造的业务码。只有从实际 HTTP Response
创建的内部响应异常才能向 Dart 上报 HTTP 状态和 Retry-After；HTTP 200 的业务
401 不应触发宿主的 HTTP 401 处理。

Windows 通过独立 Suwayomi 运行时执行扩展，不共享 Android 的 DEX 类加载器。
Android 测试通过不能代替 Windows 验收。APK 发布者核验也不能为另行下载的
JAR 背书，桌面代码的来源与信任边界必须继续保留。

## 验证边界

`tools/mihon_source_api_abi.json` 固定核心公共描述符，检查发布 APK 的实际 DEX，
在普通构建和正式发布流水线中执行。它用于防止已知接口遗漏，不是全仓库兼容
证明，也不替代真实插件的搜索、详情、章节、页列表和图片解码验收。

原生契约测试覆盖 FilterList 的构造和 data class ABI、模型复制、Page 状态、
Rx/suspend 桥接、HTML 默认实现、真实 HTTP 元数据及取消传播。实际插件验收
必须使用原始发布 APK，记录版本、哈希和签名；不把修改后的测试插件冒充原版。

Page 和 PagePreview 使用与固定上游一致的 Kotlin serialization 生成 API，
门禁同时检查生成入口，原生测试验证 JSON 往返及临时状态不持久化。

用户要求兼容 Komikku 全部插件，因此核心 API 门禁只是第一层检查。后续必须
冻结实际仓库索引、审计原始插件的外部接口依赖，并分别验证 Android DEX 与
Windows JVM 路径；仅提供 APK 的插件也计入桌面覆盖范围。静态检查、加载、
筛选与实际联网阅读分别记录，未取得或未运行的条目不能计为通过。

Komikku SY 的 exh 元数据和宿主委派增强应按真实插件依赖审计处理；不能用
空实现冒充持久化或站点功能，也不能将宿主自带增强与插件必需接口混为一谈。
最终本机和公开发布验证结果分别记录在 CURRENT_STATUS 与交付证据中。

## 插件运行时与跨调用状态

仓库检查须覆盖插件直接引用的运行库，不能只检查 source-api。冻结样本暴露了
coroutines 1.11 的 `runBlockingK`、QuickJS、Protobuf 和图片解码依赖，以及新
Cronet 包引用的 OkHttp 5.4 Chain 接口；使用真实库提供对应实现并验证执行结果，
不新增同名空实现。解码辅助库会捕获缺失可选解码器的 LinkageError 并回退；这类
引用须结合实际辅助库路径验证，不能把所有缺失引用一律当作必需或一律忽略。
不同解码库含同名 native `.so` 时不得用 pickFirst 隐藏二进制冲突。

`SManga.memo` 与 `SChapter.memo` 以原始 JSON 文本跨宿主调用传递，避免 64 位
标识经过浮点转换。Android 原始字段快照与本地展示覆盖分开保存，数据库 schema
13 为作品和章节各增加独立 metadata 列；下载正文、备份、WebDAV、历史缓存和
持久换源计划都必须往返保存。字段缺失保留已有值，明确提供的 memo（包括
`null` 或空对象）整体替换；无独立版本信息的同步冲突采用本地明确字段优先，
不把本地缺失状态覆盖到云端已有状态。

Windows 使用固定 Suwayomi 包自身的运行库，按实际 classfile 和原始 JAR 验收；
不能将 Android 的依赖版本或 `.so` 直接复制到桌面运行时。静态引用解析不能证明
反射、JNI、站点登录、验证码或实际图片算法可用，批量加载与阅读验收各保留证据。

## 桌面筛选与图像处理

固定 Suwayomi 的 REST 筛选接口直接序列化插件选项对象，部分混淆对象触发
Jackson 500；其分组提交也不能表达所有嵌套 Group/Sort。普通筛选读取和搜索改用
上游 GraphQL 的显示值与递归 typed changes，保留 Header/Separator 原始位置，
不以过滤说明行后的索引提交状态。

GraphQL 原生输入不能表达显式 `Sort.state = null`。省略该项会重新采用插件
非空初始值，已由原版 MangaDex 1.6.1 的相关度排序请求分支确认。仅对包含空排序
的快照，通过 helper 给同一搜索 mutation 扩展 `triomiFilters` 字符串参数，先完整
验证类型、位置、节点预算、深度与循环，再递归应用状态并复用上游 Source 搜索、
作品入库和 GraphQL DTO。原始数据获取器仍处理不带扩展参数的请求，认证要求与
来源身份检查保留；不修改固定服务端 JAR，不将空值静默转换成插件默认值。

Tenkaiscan 原始 JAR 使用固定桌面 AndroidCompat 尚未实现的 ColorMatrix，以及
带轴心缩放和平移的 Matrix/Canvas 绘制。helper 提供实际颜色矩阵、仿射变换与
图像绘制，在固定服务端前加载；原版插件的拦截器由受控 PNG/JSON 请求驱动，验证
翻转、反色与 JPEG 结果。此证据不代表 Android 图形接口全集已实现，透视变换
仍明确拒绝。源码与哈希、上游许可证随桌面运行时分发。
