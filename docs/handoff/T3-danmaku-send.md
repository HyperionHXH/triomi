# T3 · 弹幕发送（弹弹play）——账号登录补全

> **状态：✅ 已完成（2026-09-23）。** client.login + 控制器 login + 设置页登录入口（账号/密码 + 登录获取 token 按钮，密码不落盘）都已完成；
> 夹具服务补了 /api/v2/login 与 /api/v2/comment/<id> 回执端点，
> dandanplay baseUrl 支持 `--dart-define=TRIOMI_DANDANPLAY_BASE` 覆盖做 E2E。
> 注意：dandanplayClientProvider watch 凭据，**凭据控制器里不能 read 它**
> （Riverpod 3 会抛 CircularDependencyError），控制器内自行构造 client。
> 对应规格：4.6 弹幕增强。现状比预期更完整：**发送客户端与播放器发送流程
> 都已实现**，缺的只有「账号密码 → token」的登录链路（现在 token 只能
> 手动粘贴）。这是一个小任务。

## 现状（已就位，不要重做）

- 客户端：`lib/features/player/data/dandanplay_client.dart`
  - `sendComment({episodeId, text, timeSeconds, token, mode, color})` 已实现
    （签名 `Base64(SHA1(AppId+Timestamp+Path+AppSecret))`，X-AppId /
    X-Timestamp / X-Signature / Bearer token 头齐全）。
  - `search(keyword)` / `comments(episodeId)` / 解析全部可用。
- 播放器：`player_page.dart` 的 `_sendDanmaku()` 完整（凭据检查 → 引导去
  设置 → 输入对话框 → sendComment → toast）。
- 凭据：`DandanplayCredentials`（`danmaku_settings.dart`），
  `canSend = isConfigured && token.isNotEmpty`；设置页
  `features/player/danmaku_settings_page.dart` 可填 appId/appSecret/token。
- 单测已覆盖签名与解析（`test/m5_test.dart` 弹幕组）。

## 范围

### 做
1. `DandanplayClient.login({userName, password})`：调
   `POST /api/v2/login`，body：
   ```json
   {
     "userName": "...", "password": "...",
     "appId": "...", "unixTimestamp": <秒>,
     "hash": "md5(appId + userName + password + unixTimestamp + appSecret)"
   }
   ```
   响应 `{ token, userId, ... }`，返回 token；401 →
   `SourceErrorType.auth`（消息用服务端 errorMessage），其他沿用分类。
   hash 用 `crypto` 包的 md5（项目已有 crypto 依赖）。
2. `DandanplayCredentialsController`（`danmaku_settings.dart`）加
   `Future<String?> login(String userName, String password)`：
   成功后把 token 写回凭据并持久化，**密码不落盘不落日志**（只用于本次请求）。
3. 单测。

### 不做
- 设置页 UI 的登录表单（本机接线：加「用账号密码登录获取 token」按钮，
  调上面的 controller 方法即可）。

## 测试要求

1. login 成功路径：断言 body 的 hash = md5(appId+user+pass+ts+secret)
   （FakeHttpClient 捕获请求体，用 crypto 现算对比）。
2. login 失败：服务端 `{"success":false,"errorMessage":"密码错误"}` →
   auth 错误且消息透出。
3. token 持久化后 `canSend == true`；密码字段不出现在任何持久化内容里。
4. 现有弹幕测试不回归。

## 验收标准

- analyze 零问题；测试全绿；无 UI 改动。

## 后续集成点

- 本机：弹幕设置页加登录入口（账号/密码两个输入框 + 登录按钮）；夹具
  服务补 `/api/v2/login` 与 `/api/v2/comment/<id>` 的回执端点做 E2E。

## 设备端验证（2026-09-28 补齐）

上面那句「夹具补端点做 E2E」当时只做到了端点，**发送链路一直没在设备上跑过**。
本轮补跑，并给夹具再补两个读端点（原来只有 login 与 POST comment）：

- `GET /api/v2/search/episodes?anime=…`：固定回一部剧两集（episodeId 9001/9002）。
- `GET /api/v2/comment/{id}`：复用 `danmaku_json()` 回 40 条弹幕。
- `POST /api/v2/comment/{id}` 的日志**带上文本与时间点**，设备端 E2E 就是靠这行
  断言「真的发出去了」。

设备（emulator-5556，`--dart-define=TRIOMI_DANDANPLAY_BASE=http://10.0.2.2:8123`）
上的完整链路：

1. 弹幕设置填 AppId/AppSecret + 账号/密码 → 「登录获取 token」→ 夹具登录返回
   `fixture-dandanplay-token`，token 自动填入；状态由「未配置」变为**「可拉取、可发送」**
   （密码只用于本次请求，不落盘）。
2. 播放器 → 「搜索弹幕」→ 夹具搜索返回剧集列表 → 选「第 1 话」→
   `GET /api/v2/comment/9001` 载入弹幕，`_danmakuEpisodeId = 9001`。
3. 「发送弹幕」输入文本 → 发送 → 夹具进程日志：
   `[dandanplay] comment sent to episode 9001: 'triomi-e2e-danmaku' @ 29.75s`。

结论：签名头（X-AppId / X-Timestamp / X-Signature）与 Bearer token 都按预期带上，
链路通；**剩下的只有真实弹弹play 凭据**（等用户注册应用后 `--dart-define` 注入）。

### UI 驱动注意（这页很容易点歪）

- 弹幕设置页要滚到底再取输入框坐标，否则 `edit_boxes()` 给的下标对不上：
  0=屏蔽词 1=AppId 2=AppSecret 3=账号 token 4=账号 5=密码。
- **每填一个字段就收一次键盘**：键盘弹出会把下半页顶走，继续用旧坐标会点到键盘上
  （表现为「文本被追加到上一个字段」）。`dumpsys input_method` 里的
  `mInputShown=true` 可用来判断该不该按返回。
- 播放器顶栏按钮（搜索弹幕 / 发送弹幕）是带 tooltip 的 IconButton，dump 里以
  content-desc 出现，可以直接按文本点。
