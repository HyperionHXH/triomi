# 开发夹具 HTTP 接口契约（D25）

> 契约表由 `tools/fixture_contract_helpers.py` 的 `build_contract_table()` 维护，
> `tools/test_fixture_http_contract.py` 在 127.0.0.1 随机端口上对**真实存在的
> 端点**逐项验证（起服务实例不修改 `dev_fixture_server.py`，WebDAV 写目录指向
> 临时目录，teardown 服务/线程/文件全清）。机器可读数据源见该 helper；
> 本文档是人读摘要，两边由「契约表自检」用例防漂移。

## 端点 → 响应字段 → 消费方

| 端点 | 方法 | 响应要点 | 消费方 |
|---|---|---|---|
| `/list?page=N` | GET | HTML `.item/.title/.cover/.author` + `.pager` 下一页 | `assets/rules/local-fixture.json`（discover） |
| `/search?q=K` | GET | HTML 列表；**参数名是 `q`**，缺省回显「夹具」 | `local-fixture.json`（search） |
| `/manga/{rid}` | GET | HTML `h1/.summary/.chapters a[href]` | `local-fixture.json`（detail） |
| `/chapter/{rid}-{n}` | GET | HTML `#reader img[src=/img/page/{rid}-{n}-{页}.png]` | `local-fixture.json`（content） |
| `/img/cover/{rid}.png`、`/img/page/…` | GET | 现场 PNG 字节 | 封面/正文加载 |
| `/novel/list?page=N`、`/novel/{rid}`、`/novelchapters/{rid}`、`/novelread/{rid}-{n}` | GET | HTML（详情/两级目录/段落正文，含段内插图与 `ln-paragraph--indent` 缩进） | `assets/rules/local-fixture-novel.json` |
| `/calendar` | GET | JSON，Bangumi 放送表（calendar）形状 | `schedule_providers.dart`（`TRIOMI_SCHEDULE_BASE` 注入时**不回退镜像**） |
| `/anime/list?page=N`、`/anime/search?q=K` | GET | HTML 列表（搜索参数名同样是 `q`） | `local-fixture-anime.json` |
| `/play/{ep}` | GET | HTML 线路列表：线路A=HLS `/video/sample.m3u8`、线路B=mp4 `/video/sample.mp4` | `local-fixture-anime.json`（content）→ 播放器 |
| `/danmaku/{ep}.json` | GET | 弹弹play 信封 `{code:0, comments:[{p:"时间,模式,颜色,uid", m}]}`，40 条滚动 + 顶部(5) + 底部(4)；地址由**规则 `content.danmaku` 声明**，播放页不写 | `player_page._loadDanmaku`（规则自带弹幕源无需凭据） |
| `/video/sample.mp4` | GET | 全量 200（`Content-Length`=文件大小、`Accept-Ranges: bytes`）；Range → 206 + `Content-Range`；跨末尾区间钳到末尾；后缀区间 `bytes=-N` 支持；**非法数字/多区间/倒序/越界统一 416 + `bytes */size`（D51，不再抛 ValueError）** | `video_downloader`（渐进式/HLS 下载、离线播放） |
| `/api/v2/login`（弹弹play） | POST | body 带 `hash` → `{success:true, token:"fixture-dandanplay-token"}`；否则 `{success:false, errorMessage}` | `dandanplay_client` 登录 |
| `/api/v2/search/episodes?anime=K` | GET | `{success, animes:[{animeTitle(回显关键词), episodes[]}]}` | 播放器手动匹配弹幕 |
| `/api/v2/comment/{id}` | GET/POST | GET 弹幕数组；POST `{success:true, commentId}`（服务端日志打印发送内容，E2E 靠它断言） | 弹幕拉取/发送 |
| `/tracking/bangumi/v0/me` | GET | 无 Authorization → 401；有 → `{id, username:"triomi-fixture", nickname}` | `TrackingService.verify` |
| `/tracking/bangumi/v0/users/-/collections/{id}` | POST | **204**（官方 Bangumi 是 202——差异见下） | 收藏 upsert |
| `/tracking/bangumi/v0/users/-/collections/{id}/episodes` | GET/PATCH | 逐集收藏；PATCH 回 **204** | 番剧进度上报 |
| `/tracking/anilist`（GraphQL） | POST | Viewer / SaveMediaListEntry | `AniListClient` |
| `/tracking/state`、`/tracking/reset` | GET/POST | 夹具内存态导出/重置（`collections`/`watchedEpisodes`/`anilist`，camelCase） | 设备 E2E 的宿主侧断言 |
| `/lk/pc-proxy/api/bff/auth-password-login-v1` | POST | 任意凭据可登录：`{code:0, data:{auth:{security_key:"fixture-lk-key", uid:42}, user:{…}}}` | `LkClient.login` |
| `/lk/pc-proxy/api/bff/…`（账号域全套） | POST | **业务失败走 HTTP 200 + 信封 `code≠0`**（如空 security_key → `{code:401, message:"请先登录…"}`，与站点 pc-proxy 一致；客户端 `_unwrapResponse` 按 code 分类） | `LkClient` 账号域（C2） |
| `/lk/pc-comment-proxy/api/…`、`api/dynamic/upload-image-v1` | POST | 评论分页/发表/点赞/配图 multipart | 详情页评论区（W6/W10） |
| `/lk/state`、`/lk/reset` | GET/POST | 夹具内存态（coin/streak/评论/上传…）导出与重置 | 设备 E2E 断言 |
| `/dav/…` | MKCOL/PUT/GET/PROPFIND | MKCOL 新建 201/已存在 405；PUT 201；GET 200+`Last-Modified`；PROPFIND 207（`getcontentlength`+`getlastmodified`）/404 | `webdav_client`（备份、双设备同步） |

## LNS 夹具覆盖范围说明

LNS（轻书架）没有 HTTP 夹具：它走 **SignalR over WebSocket**，设备联调使用
真实账号与真实站点（见 `handoff/README.md` 的真实账号记录）；`LnsGateway`
的协议行为由 `t4_test.dart`（握手/帧协议/限流/降级）与
`d9_protocol_fixture_test.dart`、`lns_lifecycle_boundary_test.dart`
（解析容错/生命周期）在单测层覆盖。因此本契约表不含 LNS 端点，
也不伪造「LNS 离线夹具已验证」。

## 已知粗糙点（现状固化，交 Codex 决定是否修）

1. 收藏 upsert 夹具回 **204** 而官方是 **202**：客户端按 2xx 判定，行为不受
   影响；若未来某处开始区分 202/204，需要先改夹具。
2. 搜索端点的关键词参数名是 **`q`**（不是 `keyword`），与规则文件
   `local-fixture*.json` 的 searchUrl 一致；契约测试已按 `q` 断言。

## 运行方式

```bash
cd triomi
python -m unittest discover -s tools -p "test_*.py" -v
# 其中的 test_fixture_http_contract 自动起停 127.0.0.1 随机端口实例，
# 不依赖 8123 端口上的常驻夹具，也不依赖 Android 路径。
```
