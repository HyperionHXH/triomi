# M5 之后执行计划（当前真相）

**更新日期**：2026-10-01
**代码基线**：`38d9130` → 镜像搜索匿名重试 → **D8/D9/D10 已交付** → Android 视频合成修复
**规范来源**：本文件与 `docs/handoff/README.md`；旧的 `docs/NEXT_PLAN.md` 只保留作历史记录。

> **状态（2026-10-01 设备复验后）**：D8、D9、D10 已全部完成；Android API 35
> x86_64 模拟器的画面合成、真实播放和动态帧差已由本机重新验收。剩余工作是物理
> 真机兼容性复验、网络/凭据联调与可选的 M6 规划，见下文。

## 结论

Triomi 的 T1–T8 代码主线已经完成，不应再把旧清单里的 D1–D5 或 T1–T7 当成待开发任务。当前工作区验证结果为：

- `flutter analyze`：零问题。
- `flutter test --reporter compact`：全量测试通过；2026-10-01 JSON 运行统计 381 个
  `testDone` 事件（343 个非隐藏用例，0 失败；Flutter 测试组/参数化用例会产生隐藏事件）。
- `docs/handoff/README.md`：纯代码交接任务已全部标记完成；LNS、LK 账号域、WebDAV、视频下载、后台提醒也已有设备或真实账号记录。

## 已发现并处理的问题

1. `docs/NEXT_PLAN.md` 的主体仍是 2026-09-23 的旧计划，虽然顶部声明过期，但正文会把已完成任务重新列为待办。
2. 根目录 `D:\noval_and_manga\PROJECT_SPEC.md` 与 `triomi/docs/PROJECT_SPEC.md` 是两份不同版本，根目录副本的 T1–T8 勾选状态已过期。执行时以 `triomi/docs/PROJECT_SPEC.md` 和本文件为准。
3. Bangumi 镜像搜索在带 token 时可能直接超时。`BangumiClient.search` 现在在确认已切到镜像后直接匿名重试，且新增单测覆盖“官方失败 → 镜像鉴权搜索超时 → 镜像匿名搜索成功”。这样不会在匿名重试时再次等待官方连接超时。

## 仍然真实存在的阻塞

这些不是 dpsk 能靠纯代码解除的阻塞：

| 阻塞 | 影响 | 解除条件 | 负责人 |
|---|---|---|---|
| 真实 Android 兼容性 | API 35 x86_64 模拟器已显示真实视频帧；物理手机尚未复验 | 在一台真实 Android 手机上跑同一夹具/正式播放器回归 | 本机设备环境 |
| Bangumi 手动绑定搜索 | 代码已做超时回退，尚需在设备网络上重新验证 | 用真实 token 或夹具包跑一次搜索并记录请求链 | 本机设备环境 |
| 弹弹play真实 AppId/AppSecret | 真实接口仍返回 `Invalid AppId` | 官方审核通过应用凭据 | 用户提供凭据后本机联调 |
| 真实站点写入 | token 属于用户，不能内置或由 dpsk 代填 | 用户明确授权并提供测试账号/token | 用户 + 本机 |

LNS、LK 账号域、WebDAV 双设备、后台更新提醒已经有记录，不应继续标记为“等待 dpsk”。

## Android 视频黑屏修复（2026-10-01，已完成）

### 根因

- `sample.mp4` 本身正常（640×360、24 fps）；HTTP Range/206 请求、Android 原生解码器
  与独立原生 Activity 均正常。
- `media_kit/libmpv` 的 Flutter 外部纹理在 API 35 x86_64 模拟器上黑屏；默认
  `AndroidView`、`PlatformViewLink + initSurfaceAndroidView` 与 `VideoView` 路径也不稳定。
- 嵌入式 `VideoView` 通过 URI 加载 HTTP 地址时还会报 `No content provider`。

### 最终实现

正式播放器 Android 路径为：`PlatformViewLink` → `initExpensiveAndroidView`（Hybrid
Composition）→ 原生 `TextureView` → `MediaPlayer.setDataSource(String)`。桌面端仍保留
`media_kit/libmpv`。TextureView 不设置 background drawable；黑色底由外层 `FrameLayout` 提供。
Surface 销毁/重建会保存播放位置与播放状态，重新绑定后恢复；换线路会清除旧状态。

### 设备验收证据

- APK：`flutter build apk --debug` 成功并安装到 `emulator-5554`。
- 2026-10-01 重新构建并安装带原生日志的 APK，使用 `D:\noval_and_manga\_video_pixel_verify.py`
  自动导航到「本地夹具番剧源 → 夹具番剧 51 → 第 1 话」，采集 12 张 1080×2400 截图。
- `sample.mp4` 源文件经 OpenCV 核对为 720 帧、24 fps、约 30 秒；原生日志报告
  `prepared duration=30023`，播放位置从 `1116 ms` 连续推进到 `7363 ms`。
- 截图中央视频区域非黑比例为 **85.45%–86.22%**；相邻帧平均绝对差为
  **3.36–5.92**，超过阈值 2 的变化像素比例为 **8.54%–11.53%**。这次把“有画面”
  与“画面持续变化”分开验收，确认是真实视频帧在播放。
- 旧记录中看到的 `0:04 / 0:04` 是采样时视频已经播放结束后的状态，不能用来推断
  夹具媒体时长；本轮已用 `MediaPlayer` 日志和源视频元信息纠正。
- 已覆盖播放、暂停、seek、倍速、线路/章节入口的原生控制桥接；真机仍需兼容性回归。

### 明确关闭项

- 不再为了这个问题切换更高 Android 版本/继续试模拟器 GPU 开关。
- Anime4K 超分按用户决定关闭；不作为后续任务。

## 给 GLM / dpsk 的下一批工作

原则：只接纯代码、测试和文档一致性扫描；不得重复 T1–T7，不碰 UI 接线、APK、模拟器，
也不要索要或提交真实凭据。GLM 与 dpsk 可以并行处理下列小任务，本机逐项复验后回写记录。

### 可交给 GLM / dpsk 的纯代码任务

- **D11：播放器验证数据解析**：把 `TriomiNativeVideo` 日志解析、截图非黑比例、帧差和
  变化像素比例整理成可测试的纯 Dart/Python 数据层；不得声称设备验证由单测替代。
- **D12：视频夹具元信息自检**：增加对 `sample.mp4` 时长、帧率、帧数和相邻帧变化的离线
  自检命令/测试，源媒体不变时输出可比较摘要。
- **D13：原生播放器状态机测试 seam**：为 prepared/playing/paused/completed/error、
  Surface 重建恢复位置增加可注入的状态转换测试；不接触真实 Android Surface。
- **D14：UI 自动化定位与文档漂移扫描**：消除“第 2 个标签”这类脆弱索引，检查根目录旧
  文档与 `triomi/docs` 当前真相的冲突；只提交脚本/测试/文档。

可直接复制给外部模型的工作单、允许修改范围、禁止范围、验收命令和交付模板见
docs/GLM_DPSK_WORK_ORDERS.md。D11、D12 已有本机草稿和单测；D13 有纯 Dart 契约草稿，
等待 GLM 对照 Kotlin 复核；D14 尚未实现，优先交给 DPSK。

### D8：追踪网络边界回归（优先级 P0）——✅ 已完成

- 交付 commit：`test(D8): 追踪网络边界回归…`（含一处行为修复）。
- **复核发现并修复**：`allowMissing`（未收藏 404 → null）只对测试替身
  「返回响应」的路径生效；真实 dio 网络层把 404 抛成异常，`collection()` 在
  设备上会直接抛错而不是返回 null，`_pushBangumi` 书籍路径的「只增不减」守卫
  会因此误报失败。`_json` 的异常路径（主地址与镜像两处）现按契约返回 null。
- 新增 `test/d8_tracking_boundary_test.dart`（12 例）：404 异常路径（主/镜像）、
  镜像再次失败、匿名重试仍超时、官方超时也回退、429 归类且不换镜像、空响应、
  非法 JSON、失败信息不含 token、`SourceException.wrap` 分类。
- 仍需设备复验：镜像带 token 搜索超时的**真实网络**表现（本机网络本轮就是超时，
  复验不了「恢复后能搜到」的另一半）。

### D9：协议/解析夹具回归（优先级 P1）——✅ 已完成

- 交付 commit：`test(D9): 协议/解析夹具回归…`（含一处解析边界修复）。
- 新增 `test/d9_protocol_fixture_test.dart`（25 例）：LNS 错误信封 -100/1001、
  空列表与分页钳位、书架快照解析、批量取书与阅读历史边界、封面占位图 `#`
  转义、详情候选键；LK 错误信封与 HTTP 分类、非 JSON、无 data 信封剥离、
  评论分页边界与附图/点赞候选键；Bangumi/AniList 搜索与剧集列表的字段缺失降级。
- **顺带修复**：Bangumi `episodes` 的补号原来按原始列表下标，垃圾元素会占据
  序号位把后面的章节顶到错的话数上，改为按已解析条数补号。
- 握手/帧匹配/字体断帧不重复 T4 已有用例；未伪造任何「真实联调通过」。

### D10：发布前纯代码审计（优先级 P1）——✅ 已完成

- 交付 commit：`fix(D10): 备份敏感键过滤按无分隔符比对…`。
- **审计发现并修复（F1 红线缺口）**：备份敏感键过滤只匹配带下划线的
  `security_key`，LK 的真实键名 `lk.securityKey`（无下划线）匹配不上——旧版本
  迁移前 Hive 里残留的真实值会进备份包并随 WebDAV 上传。现在按去掉 `_ - .`
  后的键名比对，另补 `credential` 变体。
- 新增 `test/d10_release_audit_test.dart`（3 例）：备份过滤（含导入侧）与
  复合键 `(sourceId, remoteId)` 隔离的显式回归。
- 其余审计项均有既有覆盖：SecureStore 迁移（t6）、登出清理（t6/t5）、
  离线内容开关（t7 T7-6）、异常信息与测试输出（grep 无凭据）。
- drift 迁移：v1→v2 的 onUpgrade 路径无直接升级测试（现有为轻量表结构断言）；
  如需严格校验建议后续引入 drift schema 工具链，本轮不做。
- CI：`build.yml` test job 在干净环境跑 analyze + test，满足要求。
- 依赖升级建议（只记录不升级）：7 个可兼容升级；11 个受主版本约束
  （package_info_plus 10、wakelock_plus 1.8、win32 6 等）升级需评估 API 变更；
  `flutter_secure_storage_macos` 与 `js`（flutter_js 传递依赖）已 discontinued，
  现阶段不影响 Android/Windows，升级 flutter_js 时一并处理。

## 本机接手顺序

1. 有真实 Android 设备后跑一次正式播放器回归：首播、暂停/继续、seek、倍速、换线路、
   旋转/后台恢复、退出重进；记录机型/API/是否显示画面。
2. 用夹具包复验 Bangumi 搜索三步链路（官方不可达、镜像带 token 超时、镜像匿名成功），
   再用用户 token 做一次真实连接。
3. 弹弹play 审核通过后再做一次真实匹配/发送；账号密码只在设备输入，不进文档、备份或命令历史。
4. 上述联调完成后再决定是否进入 M6：跨平台、DLNA、TTS、一起看。Anime4K、额外 Android
   版本复验按用户已作出的“不做”决定关闭。

## dpsk 交付模板

```text
任务: D8/D9/D10 <标题>
完成范围: <代码与测试文件>
测试: flutter analyze；flutter test --reporter compact；结果与用例数
未做/偏差: <账号、设备、网络限制必须明确写出>
后续集成点: <若有，只写本机需要接的类/验证步骤>
```
