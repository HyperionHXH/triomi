# 弹幕接入暂缓说明

## 结论

Triomi 本版本暂不开放弹幕入口、手动匹配和发送。播放器仍保留协议字段 `content.danmakuUrl`，但当前版本不主动加载或显示，避免把不可核验的第三方应用凭据当作公开能力。

## Kazumi 调研结果

- Kazumi 的 WebDAV 使用公开的 `kazumiSync` 目录；WebDAV 地址、用户名和密码来自本机设置。
- Kazumi 的[凭据源码](https://github.com/Predidit/Kazumi/blob/main/lib/utils/dandan_credentials.dart)只读取构建时注入的 `DANDANAPI_APPID` / `DANDANAPI_KEY`，并说明由 CI secrets 提供；公开源码没有可供其他应用复用的密钥。
- 未逆向 MSI 提取私有应用密钥，也不复用 Kazumi 的应用身份。用户自己的 WebDAV 账号与这些应用密钥不是同一种凭据。
- [弹弹play官方接入指南](https://doc.dandanplay.com/open)要求申请审核并使用分配的 AppId/AppSecret。这只限制官方 API 的接入，不代表弹幕只能来自弹弹play，也不代表其他项目的服务器可以任意供第三方应用调用。

## 不复用私有密钥的替代路径

| 路径 | 是否需要弹弹play应用审核 | Triomi 当前状态 |
| --- | --- | --- |
| 来源规则提供允许读取的弹幕地址 | 不需要；仍须遵守来源自身的授权要求 | 已有 `content.danmakuUrl` 字段及弹弹play兼容 JSON 解析，当前开关关闭；没有内置可验证的来源 |
| 用户自己的本地 XML / JSON 弹幕文件 | 不需要联网接入审核 | 尚未实现文件选择与 XML 解析，不能把协议保留称为已支持导入 |
| 用户自托管的兼容服务 | 服务部署本身不需要弹弹play应用审核；每个上游的访问要求仍独立存在 | 已调研，尚未实现自定义端点设置 |
| 官方搜索、匹配及发送 | 需要自己的应用身份；发送另需用户身份 | 暂不开放 |

自托管项目示例：[huangxd-/danmu_api](https://github.com/huangxd-/danmu_api)。其公开文档提供兼容的 `/api/v2/search/episodes`、`/api/v2/comment/:commentId`，以及本地弹幕库和 XML/JSON 格式处理。它自己的部署访问 token 不等于弹弹play的 AppId/AppSecret；不能由“开源、可部署”推导出所有上游都免授权，也不内置网上不明归属的代理地址。

## 可恢复条件

1. 来源明确提供可访问且允许应用读取的弹幕地址后，可先开放该来源的只读弹幕；恢复前需验证切集竞态和失败隔离，不能只翻转全局开关。
2. 本地文件或自托管端点须完成真实导入/配置、解析和播放器验收后再显示入口，不能展示不可用按钮。
3. 用户拥有自己申请的官方 AppId/AppSecret 时，再恢复官方匹配；发送还需要用户自己的账号 token。
4. 当前继续隐藏不可用入口，不发起弹弹play搜索/发送请求。没有提取其他已安装应用的私有应用身份。

本说明不记录任何账号、密码、token 或 AppSecret。
