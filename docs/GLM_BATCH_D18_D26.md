# 第三轮扩展任务包：D18–D26

日期：2026-10-01。用户要求一次多派任务，本文件与 GLM_DPSK_WORK_ORDERS.md 的
D15–D17 组成 **12 项连续执行任务包**。这些是新增接收准备工作，不重做 T1–T8/D8–D14。
总体设计与生产缺陷修复仍由 Codex 负责，用户手动分配，GLM 不调用其他模型。

## 连续执行规则

1. 先读当前计划、第三轮审核、对应生产实现和已有测试；每项先写覆盖差距，已有
   测试充分时引用具体用例，不复制用例凑数量。不设置 token 或测试数量配额。
2. D15–D17 按主工作单执行，接着 D18→D26；不在完成一个任务后停下来询问是否
   继续。不等待 Codex 逐项回复。每项维护 docs/delivery/Dxx.md，末尾写实际结果。
3. 允许的测试调用真实生产类，用 FakeHttpClient/内存数据库/临时目录控制边界。
   禁止另写一个业务实现来测试自己的副本。异步用 Completer/可控 socket 驱动，
   不依赖公网、长时间 sleep 或真实账号。共用既有夹具只能读取，新增助手放各自
   test/fixtures/dxx/ 下；不改他人测试语义或删除断言。
4. D18–D26 不改 lib/**、android/**、pubspec.* 或生成代码。发现生产缺陷后保留
   最小可重现回归与失败输出，写出触发条件/预期/实际/影响/修复建议，继续下一项。
   失败不要改成 skip、expect 当前错误为正确或删除用例；最后明确列出未通过任务。
   无法在现有接口隔离某行为时记录证据与所需接口，不为测试大改架构。
5. 真实 JS 引擎缺失允许按原有机制报告环境不可用，但不能把替身通过写成真实
   引擎通过；必须区分 passed/failed/skipped/not-run，设备验收不由单测替代。
6. 每项 focused test；D15–D26 全部完成后跑一次 analyze、全量 Flutter test、
   Python tools、媒体自检、扫描与 diff --check。遇失败仍输出汇总，不伪造全绿。
   用实际执行环境的 Flutter 路径，先清代理并配置 Android SDK；不安装新平台工具链。
7. 不自动提交、推送或派发新线程；保留接收时已有未提交修改。结果只写 docs/delivery
   与下列允许文件，不把截图/数据库/备份包/真实内容/凭据加入仓库。

## D18：备份导入与 WebDAV 合并的完整性

阅读：core/backup/backup_service.dart、webdav_client.dart，m5_test、t6/t7、
d10_release_audit_test。允许新增 test/backup_import_boundary_test.dart、
test/fixtures/d18/**、docs/delivery/D18.md。

核查并对尚未覆盖的行为补测试：

- 损坏 ZIP、缺 payload、非对象 JSON、超出支持的格式版本：拒绝时旧数据不丢。
- 两来源相同 remoteId 的作品/章节/书架/历史隔离；重复导入不倍增记录；分别覆盖
  本地较新、远端较新、时间相同、缺时间。先确认现行合并契约，疑义写明。
- 导入中途类型异常是否回滚数据库；设置导入与数据库事务是否存在部分成功窗口。
- includeOfflineContent 开/关的 round-trip；敏感键在导出及导入两侧均被过滤，
  示例全部假值；离线引用缺文件时不能被测试误判为可读。
- WebDAV 401/403/404/超时/无效 stat 回复的分类，失败不报同步成功；涉及本地
  文件写入的用例严格使用 tempdir，不触碰真实 WebDAV。

交付附状态合并表及事务边界说明；生产缺陷只留下复现。focused command：
flutter test test/backup_import_boundary_test.dart --reporter compact。

## D19：下载失败、重试与离线状态

阅读：downloads/data/、download_providers.dart，m5_test、video_download_test、
hls_playlist_test。允许新增 test/download_boundary_test.dart、test/fixtures/d19/**、
docs/delivery/D19.md。

- 来源不可用、锁定章节、空正文、图片下载中途失败、视频分段失败的任务状态与
  doneChapterIds；未完成不能被统计成已下载。
- 同章节重复 enqueue、失败重试、两来源相同章节 ID：任务与离线内容不能串源。
- 已完成记录与磁盘文件不一致、manifest 无效/缺页、删除任务后的本地内容读路径；
  检查 removeFiles 只作用于应用拥有的文件，不能构造跨目录删除真实文件。
- 渐进式与明文 HLS 的相对 URL、嵌套 master、分段请求失败、进度回调边界；
  复用既有 HLS 测试，不对已拒绝的加密流假造下载成功。
- 审计调度器删除/重试期间在途请求返回的竞态，以及仅 WiFi 判断的降级语义；
  没有可注入网络接口时记录限制，不模拟全机网络配置或增加插件。

交付包含状态转换表、重试是否清理旧部分文件的实际结论。focused command：
flutter test test/download_boundary_test.dart --reporter compact。

## D20：追踪并发与同步标记

阅读：tracking/data/，t1_tracking_test、d8_tracking_boundary_test。允许新增
test/tracking_concurrency_test.dart、test/fixtures/d20/**、docs/delivery/D20.md。

- 用可控 fake HTTP/Completer 制造早请求晚返回、进度连发、一服务成功另一服务失败。
  检查 progress/status/lastSyncedAt 与本地记录，以既有只增不减/冲突契约为依据。
- 401、429、超时后不能 markSynced；失败重试成功才更新标记。
- 解绑/清 token 与在途请求并发；已解绑记录不应被旧回执重建，不泄漏到下一账号。
- 小说章数与番剧集数映射，排序值缺失、远端进度更高、两来源相同 remoteId；
  不重复 D8 镜像回退纯网络用例，专注服务层结果。

交付写实际调用顺序与存储结果。focused command：
flutter test test/tracking_concurrency_test.dart --reporter compact。

## D21：LNS 连接生命周期与协议恢复

阅读：novel/data/lns/lns_hub_connection.dart、lns_gateway.dart，t4_test、
d9_protocol_fixture_test。允许新增 test/lns_lifecycle_boundary_test.dart、
test/fixtures/d21/**、docs/delivery/D21.md。

- 假 socket 驱动 handshake 超时、握手失败后重连、reset 时 pending invoke 拒绝、
  timeout 后迟到回执、旧连接关闭事件不能击穿新连接。
- 多 invoke 回执乱序按 invocationId 匹配；未知 ID/重复完成帧不误完成其他请求。
- 一条消息多帧、跨消息断帧、malformed JSON、二进制帧、close/error 帧；
  对已有覆盖引用用例，补真实遗漏，记录错误分类与 subscription/pending 清理证据。
- 重连是否自动重发非幂等调用必须明确；不凭空要求重新签到/付费调用自动重放。

focused command：flutter test test/lns_lifecycle_boundary_test.dart --reporter compact。

## D22：JS 宿主桥与规则异常边界

阅读：core/source/js/、t2_js_source_test、t2_js_engine_test、js_engine_probe_test。
允许新增 test/js_bridge_boundary_test.dart、test/js_runtime_lifecycle_test.dart、
test/fixtures/d22/**、docs/delivery/D22.md。

- 规则错误字段/缺导出/非法返回值：import/load/call 各层错误分类和来源 ID。
- fetch reject、选择器失败、多异步请求乱序、Promise reject 后再调用、dispose
  后晚到 fetch 结果；测试真正宿主桥或运行时，不能只测试假引擎自己。
- 审核不同源实例的 headers/session 隔离、异常输出是否带假 token；补具体路径。
- 真实 runtime timeout 的作用范围须实证区分：异步 Promise 超时不代表同步无限
  循环可被中断。禁止直接在测试主进程执行无限循环。若需验证，用现有子进程手段
  设置外部终止期限；条件不具备则提交静态证据和风险，不写“沙箱完全安全”。

focused command：flutter test test/js_bridge_boundary_test.dart
test/js_runtime_lifecycle_test.dart --reporter compact。引擎不可用写原因与跳过数量。

## D23：阅读解析、分页与续读边界

阅读：novel/reader/novel_blocks.dart、novel_reader_page.dart、novel_reader_settings.dart，
reader_pagination_test、reader_settings_test、m4b_reader_zh_test；漫画阅读对应实现。
允许新增 test/reader_resume_boundary_test.dart、test/fixtures/d23/**、
docs/delivery/D23.md。无需修改页面。

- 同来源同书不同章节与不同来源同 ID 的位置保存/恢复隔离。
- 字号/字体/宽度变化后的分页位置钳位、空正文、只有插图、长段落、连续换行、
  中英文标点/emoji；以“内容没有丢失、位置合法、没有空白死循环”断言，避免绑定
  某个环境下的精确分页数量。
- 缺尺寸/无效尺寸的插图、协议相对地址、HTML entity、标题/正文混排。
- 到末章、重复结束回调、全部标已读：本地提示不能被误写成远端阅读历史。
- 需要 widget 的部分复用现有 harness；没有注入点时记录缺口，不另建分页实现。

focused command：flutter test test/reader_resume_boundary_test.dart --reporter compact。

## D24：TXT/EPUB 产物语义验证

阅读：novel/export/，m4b_test、m4_test 与已有导出记录。允许新增
test/export_artifact_boundary_test.dart、test/fixtures/d24/**、docs/delivery/D24.md。

- TXT UTF-8、顺序、章节标题、插图占位、空卷/锁定章的现行处理、特殊文件名。
- 实际解包 EPUB：mimetype/容器/OPF manifest 与 spine 对应、章节顺序、导航目标、
  封面和图片引用确实存在，重复图片处理；不只断言 zip bytes 非空。
- XML 特殊字符、Unicode 标题、相对图片路径、图片请求失败与导出失败清理。
- SAF 成功/失败/取消通过现有注入回调测试，用户原文件不被删；无法在纯测试证明
  Android 授权行为时标为设备项，不把回调 fake 当系统权限验证。

focused command：flutter test test/export_artifact_boundary_test.dart --reporter compact。

## D25：开发夹具接口的离线契约

阅读：tools/dev_fixture_server.py、tracking_fixture.py、lk_fixture.py、
lk_fixture_selftest.py、assets/rules/。允许新增 tools/test_fixture_http_contract.py、
tools/fixture_contract_helpers.py、docs/FIXTURE_CONTRACTS.md、docs/delivery/D25.md；
只修这些新文件，不改既有 server/真实媒体，发现缺陷报告 Codex。

- 建立规则声明端点→响应字段→消费方的对应表，覆盖漫画、小说、番剧、弹幕、
  追踪、LK 夹具；仅测试真实存在的端点，说明 LNS fake 覆盖的范围。
- 使用临时 server 监听 loopback 动态端口（端口0），避免抢占8123；支持 clean
  shutdown/join。若原 server 无注入点，通过现有 handler 构造测试实例，不先
  改生产服务器结构。所有 HTTP 都只到127.0.0.1。
- Range/206 的范围与 Content-Range/Content-Length、越界/不合法 Range 的实际
  契约、完整 sample.mp4 下载摘要；正文/评论分页，token fake 的校验与错误回执。
- teardown 后服务/线程/文件不残留，运行不依赖 Android 路径或已有夹具服务。

验收：python -m unittest discover -s tools -p "test_*.py" -v。
如 D15 已创建 CI job，新 test 自动纳入发现，不再编辑 workflow。

## D26：平台与依赖盘点、TTS 实现前资料

允许新增 docs/PLATFORM_DEPENDENCY_AUDIT.md、docs/TTS_RESEARCH.md、
docs/delivery/D26.md。只读 pubspec.lock、插件平台实现、平台工程与官方公开文档。
不升级、安装插件、不运行真实站点或添加空壳功能。在线资料不可达时标未核实。

1. 逐个平台列出播放、JS、安全存储、字体导入、SAF/导出、后台更新、音量键、
   常亮能力：已有实现/静默降级/依赖缺失/尚未构建验证，给文件证据。
2. 根据锁文件与当前构建告警盘点 flutter_js、flutter_secure_storage、
   package_info_plus、wakelock_plus、media_kit 的兼容性与废弃传递依赖；引用官方
   changelog/插件仓库链接并记查阅日期。区分已知影响与将来升级风险，不猜最新版。
3. TTS 候选库重点比较 flutter_tts 与平台原生桥：Android/Windows 支持、回调
   精度（词/句）、暂停/恢复、离线语音、语种、音频焦点、许可证/维护、测试替身能力。
4. 追踪 ReaderBlock→可朗读文本的现有链路，说明标题/插图/混淆字体/付费锁定正文
   处理约束；列应由 Codex 决定的接口问题，不替 Codex 定稿，不提供虚构功能验收。
5. 输出能力矩阵、升级依赖顺序建议、TTS 资料结论与不确定项，不把调研标为实现。

验收：引用可核查、文件链接存在、git diff --check；记录未验证的平台和资料。

## 全批交付汇总

新增 docs/delivery/BATCH_D15_D26_SUMMARY.md，表中每行给出：任务编号、文件、
新增覆盖与已有覆盖引用、实际命令、通过/失败/跳过/未运行数、发现、Codex 后续。
不要复述十二份文档来制造长度，保留决定接收与修复顺序所需的证据。

有失败时单独列 P0/P1/P2 清单，引用最小复现测试；明确全量测试是否因为这些新
回归未通过。Codex 会逐项收修复，再决定进入 TTS 的接口设计与实现。
