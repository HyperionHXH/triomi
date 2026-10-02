"""开发用夹具服务：给模拟器里的 Triomi 提供确定性的站点数据。

用途：模拟器所在环境没有外网（DNS 被劫持），无法用真实站点验证
「规则引擎 → 发现/搜索/详情/正文 → 阅读器 / 播放器」这条链路。
这里扮演一个漫画站 + 一个番剧站 + Bangumi 放送表，
配合 assets/rules/local-fixture.json、local-fixture-anime.json（仅 debug 播种）使用。

启动：
    python dev_fixture_server.py            # 监听 0.0.0.0:8123

Android 模拟器内访问宿主用 http://10.0.2.2:8123 。
"""

import io
import json
import os
import struct
import sys
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# 追踪服务夹具与本文件同目录（直接运行时脚本搜索路径包含本目录）。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lk_fixture  # noqa: E402
import tracking_fixture  # noqa: E402

PORT = 8123
DAV_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '_dav')
MEDIA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fixture_media')


def png(width: int, height: int, rgb: tuple[int, int, int]) -> bytes:
    """生成纯色 PNG（不依赖 Pillow）。"""

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack('>I', len(data))
            + tag
            + data
            + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    raw = b''
    for _ in range(height):
        raw += b'\x00' + bytes(rgb) * width

    return (
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(raw, 9))
        + chunk(b'IEND', b'')
    )


def list_page(page: int) -> str:
    items = []
    for index in range(1, 7):
        rid = page * 100 + index
        items.append(
            f'''<div class="item">
  <a class="title" href="/manga/{rid}">夹具漫画 {rid}</a>
  <img class="cover" data-src="/img/cover/{rid}.png" />
  <span class="author">作者 {rid}</span>
</div>'''
        )
    return f'''<html><body>
<div class="list">
{''.join(items)}
</div>
<div class="pager"><a href="/list?page={page + 1}">下一页</a></div>
</body></html>'''


def search_page(keyword: str) -> str:
    items = []
    for index in range(1, 4):
        rid = 900 + index
        items.append(
            f'''<div class="item">
  <a class="title" href="/manga/{rid}">{keyword} 结果 {index}</a>
  <img class="cover" data-src="/img/cover/{rid}.png" />
  <span class="author">搜索作者 {index}</span>
</div>'''
        )
    return f'<html><body><div class="list">{"".join(items)}</div></body></html>'


def detail_page(rid: str) -> str:
    chapters = ''.join(
        f'<li><a href="/chapter/{rid}-{n}">第 {n} 话</a></li>' for n in range(1, 6)
    )
    return f'''<html><body>
<h1>夹具漫画 {rid}</h1>
<div class="summary">这是本地夹具源的简介，用于验证详情页字段补全。</div>
<ul class="chapters">{chapters}</ul>
</body></html>'''


def reader_page(chapter: str) -> str:
    pages = ''.join(
        f'<img src="/img/page/{chapter}-{n}.png" />' for n in range(1, 5)
    )
    return f'<html><body><div id="reader">{pages}</div></body></html>'


# ---------------------------------------------------------------- 番剧站 ----

def anime_list_page(page: int) -> str:
    items = []
    for index in range(1, 5):
        rid = page * 50 + index
        items.append(
            f'''<div class="item">
  <a class="title" href="/anime/{rid}">夹具番剧 {rid}</a>
  <img class="cover" data-src="/img/cover/a{rid}.png" />
  <span class="author">动画作者 {rid}</span>
</div>'''
        )
    return f'<html><body><div class="list">{"".join(items)}</div></body></html>'


def anime_detail_page(rid: str) -> str:
    episodes = ''.join(
        f'<li><a href="/play/{rid}-{n}">第 {n} 话</a></li>' for n in range(1, 4)
    )
    return f'''<html><body>
<h1>夹具番剧 {rid}</h1>
<div class="summary">这是本地夹具番剧的简介，用于验证播放器链路。</div>
<ul class="episodes">{episodes}</ul>
</body></html>'''


def anime_play_page(ep: str) -> str:
    # 第 3 话把 HLS（m3u8）放在第一条线路，用来验证视频下载的 HLS 分支；
    # 其余话第一条是渐进式 mp4（真实可播，保持播放链路验证不变）。
    lines = [
        ('线路A', '/video/sample.m3u8'),
        ('线路B', '/video/sample.mp4'),
    ]
    if not ep.endswith('-3'):
        lines.reverse()
    rows = ''.join(
        f'<div class="line"><span class="line-name">{name}</span>'
        f'<a class="line-url" href="{url}">{name} 源</a></div>'
        for name, url in lines
    )
    return f'''<html><body>
<h1>夹具番剧 {ep}</h1>
<div class="lines">{rows}</div>
</body></html>'''


def danmaku_json(ep: str) -> str:
    """弹弹play 格式：comments[].p = 时间,模式,颜色,用户。"""
    comments = []
    for index in range(1, 41):
        comments.append(
            {
                'p': f'{index * 0.75},1,{[16777215, 16744448, 65280][index % 3]},100',
                'm': f'夹具弹幕 {index}（{ep}）',
            }
        )
    comments.append({'p': '2.0,5,16777215,100', 'm': '顶部弹幕'})
    comments.append({'p': '4.0,4,16744448,100', 'm': '底部弹幕'})
    return json.dumps({'code': 0, 'comments': comments}, ensure_ascii=False)


# ---------------------------------------------------------------- 小说站 ----

def novel_list_page(page: int) -> str:
    items = ''.join(
        f'''<div class="item">
  <a class="title" href="/novel/{page * 30 + i}">夹具小说 {page * 30 + i}</a>
  <img class="cover" data-src="/img/cover/n{page * 30 + i}.png" />
  <span class="author">小说作者 {i}</span>
</div>'''
        for i in range(1, 5)
    )
    return f'<html><body><div class="list">{items}</div></body></html>'


def novel_detail_page(rid: str) -> str:
    volumes = ''.join(
        f'<li><a href="/novelchapters/{rid}-{n}">第 {n} 卷</a></li>' for n in range(1, 3)
    )
    return f'''<html><body>
<h1>夹具小说 {rid}</h1>
<div class="summary">这是本地夹具小说的简介，用于验证小说阅读器链路。</div>
<ul class="volumes">{volumes}</ul>
</body></html>'''


def novel_volume_page(key: str) -> str:
    chapters = ''.join(
        f'<li><a href="/novelread/{key}-{n}">第 {n} 章</a></li>' for n in range(1, 7)
    )
    return f'<html><body><ul class="chapters">{chapters}</ul></body></html>'


def novel_read_page(key: str) -> str:
    paragraphs = ''.join(
        f'<p>这是夹具小说《{key}》的第 {n} 个段落。小说阅读器需要把长段落按页面高度切分，'
        f'并保持首行缩进与段距一致；这一句是凑长度的补充说明，用来让段落足够长，'
        f'以便在模拟器的窄屏上至少占满三行。</p>'
        for n in range(1, 25)
    )
    illustration = '<p class="ln-paragraph--indent"><img src="/img/cover/illu.png" width="400" height="300" /></p>'
    return f'<html><body><div id="content">{paragraphs}{illustration}</div></body></html>'


def calendar_json() -> str:
    """Bangumi /calendar 格式的精简版。"""
    def item(rid: str, name: str, score: float) -> dict:
        return {
            'id': rid,
            'name': name,
            'name_cn': f'{name}（夹具）',
            'air_date': '2026-09-01',
            'rating': {'score': score},
            'images': {'large': '/img/cover/b1.png'},
            'url': f'/anime/{rid}',
        }

    labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日']
    return json.dumps(
        [
            {
                'weekday': {'id': index + 1, 'cn': label},
                'items': [
                    item(str(index * 10 + 1), '夹具新番甲', 7.8),
                    item(str(index * 10 + 2), '夹具新番乙', 8.6),
                ],
            }
            for index, label in enumerate(labels)
        ],
        ensure_ascii=False,
    )


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # 开发期保留请求日志，便于排查"请求到底发没发出来"。
        print(f'[fixture] {self.address_string()} {fmt % args}', flush=True)

    # ---------------------------------------------------------- WebDAV 夹具
    # 只实现同步需要的最小集合：MKCOL / PUT / GET / PROPFIND（Basic 认证忽略）。
    def _dav_path(self, path: str) -> str:
        rel = path[len('/dav'):].strip('/')
        target = os.path.join(DAV_DIR, rel)
        # 防目录穿越
        root = os.path.abspath(DAV_DIR)
        target = os.path.abspath(target)
        if not target.startswith(root):
            target = root
        return target

    def _dav_get(self, path: str) -> bool:
        target = self._dav_path(path)
        if not os.path.isfile(target):
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return True
        with open(target, 'rb') as handle:
            data = handle.read()
        stat = os.stat(target)
        modified = time.strftime('%a, %d %b %Y %H:%M:%S GMT', time.gmtime(stat.st_mtime))
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Last-Modified', modified)
        self.end_headers()
        self.wfile.write(data)
        return True

    def _dav_put(self, path: str) -> bool:
        target = self._dav_path(path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length) if length else b''
        with open(target, 'wb') as handle:
            handle.write(body)
        self.send_response(201)
        self.send_header('Content-Length', '0')
        self.end_headers()
        return True

    def _dav_mkcol(self, path: str) -> bool:
        target = self._dav_path(path)
        if os.path.isdir(target):
            self.send_response(405)
        else:
            os.makedirs(target, exist_ok=True)
            self.send_response(201)
        self.send_header('Content-Length', '0')
        self.end_headers()
        return True

    def _dav_propfind(self, path: str) -> bool:
        target = self._dav_path(path)
        if not os.path.exists(target):
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return True
        if os.path.isfile(target):
            stat = os.stat(target)
            modified = time.strftime('%a, %d %b %Y %H:%M:%S GMT', time.gmtime(stat.st_mtime))
            xml = (
                '<?xml version="1.0" encoding="utf-8"?>'
                '<D:multistatus xmlns:D="DAV:"><D:response><D:href>'
                f'{path}</D:href><D:propstat><D:status>HTTP/1.1 200 OK</D:status>'
                '<D:prop><D:getcontentlength>'
                f'{stat.st_size}</D:getcontentlength>'
                f'<D:getlastmodified>{modified}</D:getlastmodified>'
                '</D:prop></D:propstat></D:response></D:multistatus>'
            )
        else:
            xml = (
                '<?xml version="1.0" encoding="utf-8"?>'
                '<D:multistatus xmlns:D="DAV:"><D:response><D:href>'
                f'{path}/</D:href><D:propstat><D:status>HTTP/1.1 200 OK</D:status>'
                '<D:prop><D:resourcetype><D:collection/></D:resourcetype>'
                '</D:prop></D:propstat></D:response></D:multistatus>'
            )
        body = xml.encode('utf-8')
        self.send_response(207)
        self.send_header('Content-Type', 'application/xml; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        return True

    def _send(self, body: bytes, content_type: str) -> None:
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_PUT(self):  # noqa: N802
        path = urlparse(self.path).path
        if path.startswith('/dav'):
            self._dav_put(path)
            return
        self.send_response(404)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_MKCOL(self):  # noqa: N802
        path = urlparse(self.path).path
        if path.startswith('/dav'):
            self._dav_mkcol(path)
            return
        self.send_response(404)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_PROPFIND(self):  # noqa: N802
        path = urlparse(self.path).path
        if path.startswith('/dav'):
            self._dav_propfind(path)
            return
        self.send_response(404)
        self.send_header('Content-Length', '0')
        self.end_headers()

    # ---------------------------------------------------------- 追踪服务夹具
    def _tracking(self, method: str) -> None:
        parsed = urlparse(self.path)
        path = parsed.path

        if path == '/tracking/state':
            self._send(tracking_fixture.state().encode('utf-8'),
                       'application/json; charset=utf-8')
            return
        if path == '/tracking/reset':
            tracking_fixture.reset()
            self._send(b'{"ok": true}', 'application/json; charset=utf-8')
            return

        length = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(length).decode('utf-8') if length else ''
        status, body, content_type = tracking_fixture.handle(
            method, path, raw, self.headers.get('Authorization') or '')

        self.send_response(status)
        if body:
            data = body.encode('utf-8')
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_header('Content-Length', '0')
            self.end_headers()

    # ---------------------------------------------------------- 轻之国度夹具
    def _lk(self, method: str) -> None:
        """LK 的 pc-proxy / pc-comment-proxy 接口（`--dart-define=TRIOMI_LK_BASE`）。"""
        parsed = urlparse(self.path)
        path = parsed.path

        if path == '/lk/state':
            self._send(lk_fixture.state().encode('utf-8'),
                       'application/json; charset=utf-8')
            return
        if path == '/lk/reset':
            lk_fixture.reset()
            self._send(b'{"ok": true}', 'application/json; charset=utf-8')
            return

        length = int(self.headers.get('Content-Length') or 0)
        # 评论配图是 multipart：体里含二进制，不能按 utf-8 严格解码（会直接抛
        # UnicodeDecodeError 让请求 500）；用 replace 保留长度并容错。
        raw = (
            self.rfile.read(length).decode('utf-8', errors='replace')
            if length
            else ''
        )
        status, body, content_type = lk_fixture.handle(method, path, raw)

        self.send_response(status)
        if body:
            data = body.encode('utf-8')
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_header('Content-Length', '0')
            self.end_headers()

    def do_POST(self):  # noqa: N802
        path = urlparse(self.path).path
        if path.startswith('/lk/'):
            self._lk('POST')
            return

        if path.startswith('/tracking'):
            self._tracking('POST')
            return

        if path == '/api/v2/login':
            # 弹弹play 登录夹具：body 里带 hash 即视为登录成功，返回固定
            # token。E2E 时用 --dart-define=TRIOMI_DANDANPLAY_BASE 指向本服务。
            length = int(self.headers.get('Content-Length') or 0)
            raw = self.rfile.read(length).decode('utf-8') if length else ''
            try:
                payload = json.loads(raw) if raw else {}
            except ValueError:
                payload = {}
            if isinstance(payload, dict) and payload.get('hash'):
                self._send(
                    json.dumps({
                        'success': True,
                        'token': 'fixture-dandanplay-token',
                        'userId': 1,
                    }).encode('utf-8'),
                    'application/json; charset=utf-8',
                )
            else:
                self._send(
                    json.dumps({
                        'success': False,
                        'errorMessage': '缺少 hash',
                    }).encode('utf-8'),
                    'application/json; charset=utf-8',
                )
            return

        if path.startswith('/api/v2/comment/'):
            episode_id = path.rsplit('/', 1)[-1]
            length = int(self.headers.get('Content-Length') or 0)
            raw = self.rfile.read(length).decode('utf-8') if length else ''
            try:
                payload = json.loads(raw) if raw else {}
            except ValueError:
                payload = {}
            # 把内容也打出来：设备端 E2E 就是靠这行日志断言「弹幕真的发出去了」。
            print(
                f'[dandanplay] comment sent to episode {episode_id}: '
                f'{payload.get("text")!r} @ {payload.get("time")}s'
            )
            self._send(
                json.dumps({'success': True, 'commentId': 9}).encode('utf-8'),
                'application/json; charset=utf-8',
            )
            return

        self.send_response(404)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_PATCH(self):  # noqa: N802
        path = urlparse(self.path).path
        if path.startswith('/tracking'):
            self._tracking('PATCH')
            return
        self.send_response(404)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def _send_range_not_satisfiable(self, size: int) -> None:
        """RFC 7233：任何不可满足/非法的 Range 一律 416 + bytes */size。"""
        self.send_response(416)
        self.send_header('Content-Range', f'bytes */{size}')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path.startswith('/tracking'):
            self._tracking('GET')
            return

        if path.startswith('/lk/'):
            self._lk('GET')
            return

        if path.startswith('/dav'):
            self._dav_get(path)
            return

        if path == '/list':
            page = int(query.get('page', ['1'])[0])
            self._send(list_page(page).encode('utf-8'), 'text/html; charset=utf-8')
            return

        if path == '/search':
            keyword = query.get('q', ['夹具'])[0]
            self._send(
                search_page(keyword).encode('utf-8'), 'text/html; charset=utf-8'
            )
            return

        if path.startswith('/manga/'):
            self._send(
                detail_page(path.rsplit('/', 1)[-1]).encode('utf-8'),
                'text/html; charset=utf-8',
            )
            return

        if path.startswith('/chapter/'):
            self._send(
                reader_page(path.rsplit('/', 1)[-1]).encode('utf-8'),
                'text/html; charset=utf-8',
            )
            return

        if path.startswith('/img/cover/'):
            self._send(png(120, 180, (80, 140, 220)), 'image/png')
            return

        if path.startswith('/img/page/'):
            self._send(png(600, 900, (240, 240, 235)), 'image/png')
            return

        if path == '/calendar':
            self._send(
                calendar_json().encode('utf-8'),
                'application/json; charset=utf-8',
            )
            return

        if path == '/anime/search':
            keyword = query.get('q', ['夹具'])[0]
            items = ''.join(
                f'''<div class="item">
  <a class="title" href="/anime/9{i}">{keyword} 番剧结果 {i}</a>
  <img class="cover" data-src="/img/cover/a9{i}.png" />
  <span class="author">番剧作者 {i}</span>
</div>'''
                for i in range(1, 4)
            )
            self._send(
                f'<html><body><div class="list">{items}</div></body></html>'.encode(
                    'utf-8'
                ),
                'text/html; charset=utf-8',
            )
            return

        if path == '/anime/list':
            page = int(query.get('page', ['1'])[0])
            self._send(
                anime_list_page(page).encode('utf-8'),
                'text/html; charset=utf-8',
            )
            return

        if path.startswith('/anime/'):
            self._send(
                anime_detail_page(path.rsplit('/', 1)[-1]).encode('utf-8'),
                'text/html; charset=utf-8',
            )
            return

        if path == '/novel/list':
            page = int(query.get('page', ['1'])[0])
            self._send(
                novel_list_page(page).encode('utf-8'),
                'text/html; charset=utf-8',
            )
            return

        if path.startswith('/novelchapters/'):
            self._send(
                novel_volume_page(path.rsplit('/', 1)[-1]).encode('utf-8'),
                'text/html; charset=utf-8',
            )
            return

        if path.startswith('/novelread/'):
            self._send(
                novel_read_page(path.rsplit('/', 1)[-1]).encode('utf-8'),
                'text/html; charset=utf-8',
            )
            return

        if path.startswith('/novel/'):
            self._send(
                novel_detail_page(path.rsplit('/', 1)[-1]).encode('utf-8'),
                'text/html; charset=utf-8',
            )
            return

        if path.startswith('/play/'):
            self._send(
                anime_play_page(path.rsplit('/', 1)[-1]).encode('utf-8'),
                'text/html; charset=utf-8',
            )
            return

        if path.startswith('/danmaku/'):
            ep = path.rsplit('/', 1)[-1].removesuffix('.json')
            self._send(
                danmaku_json(ep).encode('utf-8'),
                'application/json; charset=utf-8',
            )
            return

        if path == '/api/v2/search/episodes':
            # 弹幕搜索夹具：固定返回一部剧两集，供「手动匹配 → 发送弹幕」E2E
            # （真实接口按 anime 关键词匹配，这里把关键词回显出来便于确认请求）。
            query = parse_qs(urlparse(self.path).query)
            keyword = (query.get('anime') or ['?'])[0]
            self._send(
                json.dumps(
                    {
                        'success': True,
                        'animes': [
                            {
                                'animeId': 9001,
                                'animeTitle': f'夹具番剧（{keyword}）',
                                'episodes': [
                                    {'episodeId': 9001, 'episodeTitle': '第 1 话'},
                                    {'episodeId': 9002, 'episodeTitle': '第 2 话'},
                                ],
                            }
                        ],
                    },
                    ensure_ascii=False,
                ).encode('utf-8'),
                'application/json; charset=utf-8',
            )
            return

        if path.startswith('/api/v2/comment/'):
            # `comments()` 走 GET（query 里的 withRelated 已被剥离），返回弹幕列表。
            episode_id = path.rsplit('/', 1)[-1]
            self._send(
                danmaku_json(f'ep{episode_id}').encode('utf-8'),
                'application/json; charset=utf-8',
            )
            return

        if path.startswith('/video/'):
            name = path.rsplit('/', 1)[-1]
            file_path = os.path.join(MEDIA_DIR, name)
            if not os.path.isfile(file_path):
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b'video fixture missing')
                return
            size = os.path.getsize(file_path)
            range_header = self.headers.get('Range')
            start, end = 0, size - 1
            partial = False
            if range_header and range_header.startswith('bytes='):
                # mpv/播放器会先发 Range 请求；不支持的话部分内核会一直缓冲。
                # 非法数字/多区间/倒序/越界统一 416，不让 ValueError 在
                # 服务器线程里打 traceback（D51）。
                spec_list = range_header.split('=', 1)[1]
                if ',' in spec_list:
                    # 多区间本夹具不支持：统一 416，不静默取第一个区间。
                    self._send_range_not_satisfiable(size)
                    return
                spec = spec_list.strip()
                start_s, _, end_s = spec.partition('-')
                try:
                    if not start_s and end_s:
                        # 后缀区间 `bytes=-N`：取最后 N 字节。
                        length_suffix = int(end_s)
                        start = max(size - length_suffix, 0)
                        end = size - 1
                    else:
                        start = int(start_s) if start_s else 0
                        end = int(end_s) if end_s else size - 1
                except ValueError:
                    self._send_range_not_satisfiable(size)
                    return
                if start > end or start >= size:
                    # 越界/倒序区间必须回 416，否则 Content-Length 会是负数。
                    self._send_range_not_satisfiable(size)
                    return
                end = min(end, size - 1)
                partial = True
            length = end - start + 1
            print(
                f'[fixture] video {name} range={range_header} -> {start}-{end} ({length}B)',
                flush=True,
            )
            self.send_response(206 if partial else 200)
            self.send_header('Content-Type', 'video/mp4')
            self.send_header('Content-Length', str(length))
            self.send_header('Accept-Ranges', 'bytes')
            if partial:
                self.send_header(
                    'Content-Range', f'bytes {start}-{end}/{size}'
                )
            self.end_headers()
            with open(file_path, 'rb') as media:
                media.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = media.read(min(262144, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
            return

        self.send_response(404)
        self.end_headers()
        self.wfile.write(b'not found')


if __name__ == '__main__':
    server = ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
    print(f'fixture server listening on 0.0.0.0:{PORT}', flush=True)
    server.serve_forever()
