# 弹幕接入暂缓说明

## 结论

Triomi 本版本暂不开放弹幕入口、手动匹配和发送。播放器仍保留协议字段 `content.danmakuUrl`，但当前版本不主动加载或显示，避免把不可核验的第三方应用凭据当作公开能力。

## Kazumi 调研结果

- Kazumi 的 WebDAV 使用公开的 `kazumiSync` 目录；WebDAV 地址、用户名和密码来自本机设置。
- Kazumi 的[凭据源码](https://github.com/Predidit/Kazumi/blob/main/lib/utils/dandan_credentials.dart)只读取构建时注入的 `DANDANAPI_APPID` / `DANDANAPI_KEY`，并说明由 CI secrets 提供；公开源码没有可供其他应用复用的密钥。
- 未逆向 MSI 提取私有应用密钥，也不复用 Kazumi 的应用身份。用户自己的 WebDAV 账号与这些应用密钥不是同一种凭据。
- [弹弹play官方接入指南](https://doc.dandanplay.com/open)明确要求应用申请审核并使用分配的 AppId/AppSecret；本轮未确认可供Triomi直接发布的免申请公共服务。来源自行提供且允许访问的弹幕地址与官方应用凭据是两条独立路径，不能拿别的应用密钥代替审核。

## 可恢复条件

1. 来源规则明确声明一个用户可访问的弹幕 JSON 地址时，可在后续版本重新开启只读加载；地址必须由来源规则负责，不能从播放器猜测或绕过权限。
2. 用户拥有自己申请的弹弹play AppId/AppSecret 时，可在后续版本重新开启手动匹配；发送弹幕还需要用户自己的账号 token。
3. 在上述条件满足前，只保留本地设置模型和协议解析代码，不显示入口，不发起弹弹play搜索/发送请求。

本说明不记录任何账号、密码、token 或 AppSecret。
