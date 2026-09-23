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
