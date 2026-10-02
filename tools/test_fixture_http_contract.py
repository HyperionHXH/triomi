"""D25：开发夹具 HTTP 接口的离线契约测试。

所有请求只到 127.0.0.1 随机端口（端口 0 由内核分配，不抢占 8123）；
WebDAV 写目录指向临时目录，teardown 服务/线程/文件全部清理。
断言的是夹具的**实际**契约（docs/FIXTURE_CONTRACTS.md 与此同步）。
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path
from urllib.parse import quote

from fixture_contract_helpers import (
    build_contract_table,
    request,
    start_fixture_server,
)


def open_media(name: str) -> bytes:
    return (Path(__file__).with_name("fixture_media") / name).read_bytes()


class FixtureHttpContractTest(unittest.TestCase):
    server = None
    base = ""

    @classmethod
    def setUpClass(cls) -> None:
        fixture = start_fixture_server()
        cls.server = fixture
        cls.base = fixture.base

    @classmethod
    def tearDownClass(cls) -> None:
        if cls.server is not None:
            cls.server.stop()

    # ------------------------------------------------------ 漫画 / 图片

    def test_list_and_search(self) -> None:
        status, _, body = request(self.base, "/list?page=2")
        self.assertEqual(status, 200)
        text = body.decode("utf-8")
        self.assertIn("夹具漫画 20", text, msg=text[:200])
        self.assertIn("/list?page=3", text, msg="触底分页有下一页链接")

        status, _, body = request(self.base, "/search?q=" + quote("火影"))
        self.assertEqual(status, 200)
        self.assertIn("火影 结果 1", body.decode("utf-8"), msg="关键词回显")

    def test_detail_and_images(self) -> None:
        status, _, body = request(self.base, "/manga/100")
        self.assertEqual(status, 200)
        text = body.decode("utf-8")
        self.assertIn("夹具漫画 100", text)
        self.assertIn("/chapter/100-1", text)

        status, _, body = request(self.base, "/chapter/100-1")
        self.assertEqual(status, 200)
        self.assertIn("/img/page/100-1-1.png", body.decode("utf-8"))

        status, headers, body = request(self.base, "/img/cover/100.png")
        self.assertEqual(status, 200)
        self.assertEqual(headers["content-type"], "image/png")
        self.assertTrue(body.startswith(b"\x89PNG"), msg="现场生成的 PNG 魔数")

    # ------------------------------------------------------ 小说

    def test_novel_rule_pages(self) -> None:
        for path, marker in (
            ("/novel/list?page=1", "小说"),
            ("/novel/500", "小说"),
            ("/novelchapters/500", "章"),
            ("/novelread/500-1", "夹具小说"),
        ):
            status, _, body = request(self.base, path)
            self.assertEqual(status, 200, msg=path)
            self.assertIn(marker, body.decode("utf-8"), msg=path)

    # ------------------------------------------------------ 番剧 / 放送表 / 弹幕

    def test_anime_and_schedule(self) -> None:
        status, _, body = request(self.base, "/calendar")
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertIsInstance(payload, list, msg="放送表是 Bangumi calendar 形状")

        status, _, body = request(self.base, "/anime/list?page=1")
        self.assertEqual(status, 200)
        self.assertIn("夹具番剧", body.decode("utf-8"))

        status, _, body = request(self.base, "/anime/search?q=" + quote("刀"))
        self.assertEqual(status, 200)
        self.assertIn("刀 番剧结果 1", body.decode("utf-8"))

        status, _, body = request(self.base, "/play/51-1")
        self.assertEqual(status, 200)
        text = body.decode("utf-8")
        self.assertIn("/video/sample.mp4", text, msg="线路 B 是 mp4")
        self.assertIn("/video/sample.m3u8", text, msg="线路 A 是 HLS")
        # 弹幕地址不在播放页里，而是规则 content.danmaku 声明（玩家加载时拼）。
        rule = json.loads(
            (Path(__file__).resolve().parent.parent / "assets/rules/local-fixture-anime.json")
            .read_text(encoding="utf-8")
        )
        rule_text = json.dumps(rule, ensure_ascii=False)
        self.assertIn("/danmaku/", rule_text, msg="规则声明弹幕地址")

    def test_danmaku(self) -> None:
        status, _, body = request(self.base, "/danmaku/51-1.json")
        self.assertEqual(status, 200)
        payload = json.loads(body)
        # 弹弹play 信封：{code, comments:[{p:"时间,模式,颜色,uid", m:文本}]}。
        self.assertEqual(payload["code"], 0)
        comments = payload["comments"]
        self.assertGreaterEqual(len(comments), 40)
        modes = {comment["p"].split(",")[1] for comment in comments}
        self.assertIn("1", modes, msg="滚动弹幕")
        self.assertIn("5", modes, msg="顶部弹幕")
        self.assertIn("4", modes, msg="底部弹幕")

    # ------------------------------------------------------ 视频 / Range

    def test_video_full_download_summary(self) -> None:
        status, headers, body = request(self.base, "/video/sample.mp4")
        self.assertEqual(status, 200)
        self.assertEqual(headers["content-type"], "video/mp4")
        self.assertEqual(headers["accept-ranges"], "bytes")
        expected = open_media("sample.mp4")
        self.assertEqual(headers["content-length"], str(len(expected)))
        self.assertEqual(body, expected, msg="全量下载与磁盘字节一致")

    def test_video_range_partial(self) -> None:
        expected = open_media("sample.mp4")
        size = len(expected)

        status, headers, body = request(
            self.base, "/video/sample.mp4", headers={"Range": "bytes=0-99"},
        )
        self.assertEqual(status, 206)
        self.assertEqual(headers["content-range"], f"bytes 0-99/{size}")
        self.assertEqual(headers["content-length"], "100")
        self.assertEqual(body, expected[:100])

        status, headers, body = request(
            self.base, "/video/sample.mp4", headers={"Range": "bytes=-50"},
        )
        self.assertEqual(status, 206, msg="后缀区间取最后 N 字节")
        self.assertEqual(
            headers["content-range"], f"bytes {size - 50}-{size - 1}/{size}",
        )
        self.assertEqual(body, expected[-50:])

        status, headers, body = request(
            self.base,
            "/video/sample.mp4",
            headers={"Range": f"bytes={size - 10}-{size + 999}"},
        )
        self.assertEqual(status, 206, msg="跨末尾区间钳到末尾（HTTP 语义允许）")
        self.assertEqual(
            headers["content-range"], f"bytes {size - 10}-{size - 1}/{size}",
        )
        self.assertEqual(body, expected[-10:])

    def test_video_range_out_of_bounds_returns_416(self) -> None:
        size = len(open_media("sample.mp4"))
        status, headers, body = request(
            self.base, "/video/sample.mp4", headers={"Range": f"bytes={size}-"},
        )
        self.assertEqual(status, 416, msg="起点越界必须 416，否则 Content-Length 为负")
        self.assertEqual(headers["content-range"], f"bytes */{size}")
        self.assertEqual(body, b"")

    def test_video_range_invalid_forms_all_return_416(self) -> None:
        """D51：非法数字/多区间/倒序/越界统一 416，服务器不再打 ValueError traceback。"""
        size = len(open_media("sample.mp4"))
        invalid_ranges = {
            "非法数字（起点）": "bytes=abc",
            "非法数字（终点）": "bytes=0-xyz",
            "非法数字（后缀）": "bytes=-abc",
            "多个区间": "bytes=0-9,20-29",
            "倒序区间": "bytes=10-5",
            "起点越界": f"bytes={size}-",
            "起点越界（带终点）": f"bytes={size + 100}-{size + 200}",
        }
        for label, header in invalid_ranges.items():
            status, headers, body = request(
                self.base, "/video/sample.mp4", headers={"Range": header},
            )
            self.assertEqual(status, 416, msg=label)
            self.assertEqual(headers["content-range"], f"bytes */{size}", msg=label)
            self.assertEqual(body, b"", msg=label)
            self.assertEqual(headers.get("content-length"), "0", msg=label)

        # 合法区间回归：前缀 / 后缀 / 跨末尾钳位保持 206（已有专项用例，
        # 这里再抽查一次防回归）。
        status, headers, body = request(
            self.base, "/video/sample.mp4", headers={"Range": "bytes=0-9"},
        )
        self.assertEqual(status, 206)
        self.assertEqual(len(body), 10)

    # ------------------------------------------------------ 弹弹play

    def test_dandanplay_login_and_comment(self) -> None:
        status, _, body = request(
            self.base,
            "/api/v2/login",
            method="POST",
            payload={"hash": "fixture-hash", "appId": "app", "ts": 0},
        )
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertTrue(payload["success"], msg=payload)
        self.assertEqual(payload["token"], "fixture-dandanplay-token")

        status, _, body = request(
            self.base,
            "/api/v2/login",
            method="POST",
            payload={"appId": "app"},
        )
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertFalse(payload["success"], msg="缺 hash 按失败回执")
        self.assertIn("errorMessage", payload)

        status, _, body = request(
            self.base,
            "/api/v2/comment/9001",
            method="POST",
            payload={"text": "contract", "time": 1.5},
        )
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(body)["success"])

    def test_dandanplay_search(self) -> None:
        status, _, body = request(
            self.base, "/api/v2/search/episodes?anime=" + quote("契约"),
        )
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertIn("契约", payload["animes"][0]["animeTitle"], msg="关键词回显")

        status, _, body = request(self.base, "/api/v2/comment/9001")
        self.assertEqual(status, 200)
        self.assertIn("comments", json.loads(body))

    # ------------------------------------------------------ 追踪

    def test_tracking_auth_and_state(self) -> None:
        status, _, _ = request(self.base, "/tracking/bangumi/v0/me")
        self.assertEqual(status, 401, msg="无 Authorization 拒绝")

        auth = {"Authorization": "Bearer fixture-token"}
        status, _, body = request(
            self.base, "/tracking/bangumi/v0/me", headers=auth,
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["username"], "triomi-fixture")

        status, _, _ = request(
            self.base,
            "/tracking/bangumi/v0/users/-/collections/51",
            method="POST",
            headers=auth,
            payload={"type": 3},
        )
        # 夹具契约：204（官方 Bangumi 是 202——差异记录于 FIXTURE_CONTRACTS.md，
        # 客户端按 2xx 判定，不受影响）。
        self.assertEqual(status, 204)

        status, _, _ = request(
            self.base,
            "/tracking/bangumi/v0/users/-/collections/51/episodes",
            method="PATCH",
            headers=auth,
            payload={"episode_id": [101], "type": 2},
        )
        self.assertEqual(status, 204, msg="夹具的逐集 PATCH 回 204")

        status, _, body = request(self.base, "/tracking/state")
        state = json.loads(body)
        self.assertIn("51", state["watchedEpisodes"], msg="PATCH 落进内存态（camelCase）")

        status, _, _ = request(self.base, "/tracking/reset", method="POST")
        self.assertEqual(status, 200)
        _, _, body = request(self.base, "/tracking/state")
        self.assertEqual(json.loads(body)["watchedEpisodes"], {})

    # ------------------------------------------------------ LK

    def test_lk_auth_and_state(self) -> None:
        status, _, body = request(
            self.base,
            "/lk/pc-proxy/api/bff/auth-password-login-v1",
            method="POST",
            payload={"username": "u", "password": "p"},
        )
        self.assertEqual(status, 200)
        payload = json.loads(body)
        key = payload["data"]["auth"]["security_key"]
        self.assertEqual(key, "fixture-lk-key")

        # 站点契约：业务失败走 HTTP 200 + 信封 code（pc-proxy 同款），
        # 客户端 _unwrapResponse 按 code != 0 分类错误。
        status, _, body = request(
            self.base,
            "/lk/pc-proxy/api/bff/my-home-v1",
            method="POST",
            payload={"security_key": ""},
        )
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertEqual(payload["code"], 401)
        self.assertIn("请先登录", payload["message"])

        status, _, body = request(
            self.base,
            "/lk/pc-proxy/api/bff/my-home-v1",
            method="POST",
            payload={"security_key": key},
        )
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertEqual(payload["code"], 0)
        self.assertEqual(payload["data"]["profile"]["uid"], 42)

        status, _, body = request(self.base, "/lk/state")
        self.assertIn("coin", json.loads(body))

    # ------------------------------------------------------ WebDAV

    def test_webdav_roundtrip(self) -> None:
        status, _, _ = request(self.base, "/dav/triomi/", method="MKCOL")
        self.assertIn(status, (201, 405), msg="新建 201，已存在 405")

        status, _, _ = request(
            self.base, "/dav/triomi/backup.zip", method="PUT", raw=b"contract-bytes",
        )
        self.assertEqual(status, 201)

        status, headers, body = request(self.base, "/dav/triomi/backup.zip")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"contract-bytes")
        self.assertIn("last-modified", headers)

        status, _, body = request(
            self.base, "/dav/triomi/backup.zip", method="PROPFIND",
        )
        self.assertEqual(status, 207)
        text = body.decode("utf-8")
        self.assertIn("getcontentlength", text)
        self.assertIn("14", text, msg="长度字段可解析")

        status, _, _ = request(self.base, "/dav/triomi/missing.zip", method="PROPFIND")
        self.assertEqual(status, 404)
        status, _, _ = request(self.base, "/dav/triomi/missing.zip")
        self.assertEqual(status, 404)

    # ------------------------------------------------------ 契约表自检

    def test_contract_table_covers_declared_endpoints(self) -> None:
        table = build_contract_table()
        endpoints = {row.endpoint.split(" ")[0].split("?")[0] for row in table.rows}
        known_prefixes = (
            "/list", "/search", "/manga/", "/chapter/", "/img/",
            "/novel", "/novelchapters/", "/novelread/",
            "/calendar", "/anime/", "/play/", "/danmaku/", "/video/",
            "/api/v2/", "/tracking/", "/lk/", "/dav/",
        )
        for endpoint in endpoints:
            self.assertTrue(
                endpoint.startswith(known_prefixes),
                msg=f"契约表出现了夹具不存在的端点：{endpoint}",
            )
        self.assertGreaterEqual(len(table.rows), 20)


if __name__ == "__main__":
    unittest.main()
