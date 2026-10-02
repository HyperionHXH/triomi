"""D25：开发夹具的 HTTP 接口契约测试辅助。

通过 `dev_fixture_server.Handler` 在 127.0.0.1 随机端口上起测试实例
（不改生产服务器文件），并提供最小 HTTP 客户端与契约表。
"""

from __future__ import annotations

from dataclasses import dataclass, field
import json
from pathlib import Path
import shutil
import tempfile
import threading
from http.server import ThreadingHTTPServer
from typing import Any
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import dev_fixture_server


@dataclass
class FixtureServer:
    server: ThreadingHTTPServer
    thread: threading.Thread
    base: str
    dav_dir: Path

    def stop(self) -> None:
        self.server.shutdown()
        self.server.shutdown()  # 幂等无害；防御重复调用
        self.thread.join(timeout=5)
        self.server.server_close()
        shutil.rmtree(self.dav_dir, ignore_errors=True)


def start_fixture_server() -> FixtureServer:
    """在 127.0.0.1 随机端口上起夹具实例；WebDAV 写目录指到临时目录。"""

    dav_dir = Path(tempfile.mkdtemp(prefix="triomi_d25_dav_"))
    dev_fixture_server.DAV_DIR = str(dav_dir)
    # 测试输出不需要每个请求一行日志。
    dev_fixture_server.Handler.log_message = lambda *args, **kwargs: None
    server = ThreadingHTTPServer(("127.0.0.1", 0), dev_fixture_server.Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address[:2]
    assert host == "127.0.0.1", f"夹具必须只监听回环地址，实际 {host}"
    return FixtureServer(
        server=server,
        thread=thread,
        base=f"http://127.0.0.1:{port}",
        dav_dir=dav_dir,
    )


def request(
    base: str,
    path: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    payload: Any = None,
    raw: bytes | None = None,
    timeout: float = 5.0,
) -> tuple[int, dict[str, str], bytes]:
    """发一个只到 127.0.0.1 的请求，返回 (status, headers, body)。

    4xx/5xx 通过 HTTPError 拿到响应体，调用方按状态码断言。
    """

    assert base.startswith("http://127.0.0.1"), "契约测试只允许访问回环地址"
    body = raw
    if payload is not None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json", **(headers or {})}
    req = Request(base + path, method=method, headers=headers or {}, data=body)
    try:
        with urlopen(req, timeout=timeout) as response:
            return response.status, _lower(response.headers), response.read()
    except HTTPError as error:
        return error.code, _lower(error.headers), error.read()


def _lower(headers: Any) -> dict[str, str]:
    return {key.lower(): value for key, value in headers.items()}


def query(params: dict[str, str]) -> str:
    return "?" + urlencode(params)


@dataclass
class ContractRow:
    endpoint: str
    method: str
    fields: str
    consumer: str
    tested_by: str = ""


@dataclass
class ContractTable:
    rows: list[ContractRow] = field(default_factory=list)

    def add(self, row: ContractRow) -> None:
        self.rows.append(row)


def build_contract_table() -> ContractTable:
    """规则声明端点 → 响应字段 → 消费方 的对应表（docs/FIXTURE_CONTRACTS.md 的数据源）。"""

    table = ContractTable()
    # ---- 漫画（local-fixture.json 规则消费）
    table.add(ContractRow("/list?page=N", "GET", "HTML .item/.title/.cover/.author + .pager 下一页", "local-fixture.json 的 discover/search 规则", "test_list_and_search"))
    table.add(ContractRow("/search?keyword=K", "GET", "HTML .item，关键词回显", "local-fixture.json 的 search 规则", "test_list_and_search"))
    table.add(ContractRow("/manga/{rid}", "GET", "HTML h1/.summary/.chapters a[href]", "local-fixture.json 的 detail 规则", "test_detail_and_images"))
    table.add(ContractRow("/chapter/{rid}-{n}", "GET", "HTML #reader img[src]", "local-fixture.json 的 content 规则", "test_detail_and_images"))
    table.add(ContractRow("/img/cover/{rid}.png · /img/page/…", "GET", "image/png 字节（服务器现场生成）", "封面/正文图片加载", "test_detail_and_images"))
    # ---- 小说（local-fixture-novel.json 消费）
    table.add(ContractRow("/novel/list?page=N", "GET", "HTML .book 列表", "local-fixture-novel.json discover", "test_novel_rule_pages"))
    table.add(ContractRow("/novel/{rid}", "GET", "HTML h1/.intro/章节链接", "local-fixture-novel.json detail", "test_novel_rule_pages"))
    table.add(ContractRow("/novelchapters/{rid}", "GET", "HTML 卷/章两级目录", "local-fixture-novel.json chapters", "test_novel_rule_pages"))
    table.add(ContractRow("/novelread/{rid}-{n}", "GET", "HTML 段落正文", "local-fixture-novel.json content", "test_novel_rule_pages"))
    # ---- 番剧（local-fixture-anime.json / bangumi-anime.json 消费）
    table.add(ContractRow("/calendar", "GET", "JSON Bangumi 放送表形状", "schedule_providers.dart（TRIOMI_SCHEDULE_BASE 注入时不回退镜像）", "test_anime_and_schedule"))
    table.add(ContractRow("/anime/list?page=N · /anime/search?keyword=K", "GET", "HTML 列表", "local-fixture-anime.json discover/search", "test_anime_and_schedule"))
    table.add(ContractRow("/play/{ep}", "GET", "HTML 线路（mp4/HLS m3u8）+ danmaku 地址", "local-fixture-anime.json content；player_page 播放", "test_anime_and_schedule"))
    table.add(ContractRow("/danmaku/{ep}.json", "GET", "JSON 弹幕数组（滚动/顶部/底部）", "player_page._loadDanmaku（规则自带弹幕源）", "test_danmaku"))
    table.add(ContractRow("/video/sample.mp4", "GET", "200 全量 / 206 分段（Content-Range/Length/Accept-Ranges）", "video_downloader（渐进式与 HLS 下载、离线播放）", "test_video_range_full / test_video_range_partial"))
    # ---- 弹弹play（TRIOMI_DANDANPLAY_BASE 指向时）
    table.add(ContractRow("/api/v2/login", "POST", "hash 非空 → success+token；否则 success:false+errorMessage", "dandanplay_client 登录", "test_dandanplay_login_and_comment"))
    table.add(ContractRow("/api/v2/search/episodes?anime=K", "GET", "success + animes[].episodes（关键词回显）", "player 手动匹配弹幕", "test_dandanplay_search"))
    table.add(ContractRow("/api/v2/comment/{id}", "GET", "弹幕数组", "player 拉取弹幕", "test_dandanplay_search"))
    table.add(ContractRow("/api/v2/comment/{id}", "POST", "success + commentId", "弹幕发送（设备 E2E 断言）", "test_dandanplay_login_and_comment"))
    # ---- 追踪（TRIOMI_TRACKING_BASE 指向时）
    table.add(ContractRow("/tracking/bangumi/v0/me", "GET", "401（无 Authorization）/ 200 id+username+nickname", "TrackingService.verify", "test_tracking_auth_and_state"))
    table.add(ContractRow("/tracking/bangumi/v0/users/-/collections/{id}(+/episodes)", "GET/PATCH/POST", "逐集收藏与收藏 upsert；状态可从 /tracking/state 回读", "TrackingService 上报链路", "test_tracking_auth_and_state"))
    table.add(ContractRow("/tracking/anilist (GraphQL)", "POST", "Viewer / SaveMediaListEntry", "AniListClient", "test_tracking_auth_and_state"))
    table.add(ContractRow("/tracking/state · /tracking/reset", "GET/POST", "夹具内存态导出/重置", "设备 E2E 的宿主侧断言", "test_tracking_auth_and_state"))
    # ---- LK（TRIOMI_LK_BASE 指向时）
    table.add(ContractRow("/lk/api/bff/auth-password-login-v1", "POST", "固定 fixture-lk-key + uid 42（任意凭据均可登录）", "LkClient.login", "test_lk_auth_and_state"))
    table.add(ContractRow("/lk/api/…（账号域端点）", "POST", "缺 security_key → 401 请先登录；有 key → 数据信封", "LkClient 账号域（C2）", "test_lk_auth_and_state"))
    table.add(ContractRow("/lk/api/new-content-read/get-book-comments", "POST", "评论分页信封", "详情页评论区", "test_lk_auth_and_state"))
    table.add(ContractRow("/lk/state · /lk/reset", "GET/POST", "夹具内存态导出/重置", "设备 E2E 的宿主侧断言", "test_lk_auth_and_state"))
    # ---- WebDAV（备份同步）
    table.add(ContractRow("/dav/…", "MKCOL/PUT/GET/PROPFIND", "201/405/404/207；PROPFIND 带 getcontentlength+getlastmodified", "webdav_client（备份与双设备同步）", "test_webdav_roundtrip"))
    return table
