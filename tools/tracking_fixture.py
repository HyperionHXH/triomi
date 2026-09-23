"""追踪服务夹具（Bangumi REST v0 + AniList GraphQL）。

模拟器无外网，端到端验证时把两个 base 指到这里：
`--dart-define=TRIOMI_TRACKING_BASE=http://10.0.2.2:8123/tracking`
（客户端会拼成 `.../tracking/bangumi/v0/...` 与 `.../tracking/anilist`）。

状态存在内存里，`GET /tracking/state` 供宿主侧断言「进度真的报上来了」。
"""

import json
import re
import threading

_lock = threading.Lock()

# 已收藏条目：subject_id -> {"type": int, "ep_status": int}
_collections: dict[int, dict] = {}
# 逐集已看：subject_id -> [全局剧集 id]
_watched_episodes: dict[int, list[int]] = {}
# AniList 条目：media_id -> {"status": str, "progress": int}
_anilist: dict[int, dict] = {}

_EPISODES = [(101 + index, index + 1) for index in range(12)]
_SEARCH = [
    {
        "id": 12,
        "name": "ちょびっツ",
        "name_cn": "人形电脑天使心",
        "eps": 27,
        "images": {"common": "https://lain.bgm.tv/pic/cover/c/12.jpg"},
    },
    {
        "id": 51,
        "name": "夹具番剧 51",
        "name_cn": "夹具番剧 51（中文名）",
        "eps": 12,
        "images": {"common": "http://10.0.2.2:8123/img/cover/n51.png"},
    },
]


def reset() -> None:
    with _lock:
        _collections.clear()
        _watched_episodes.clear()
        _anilist.clear()


def state() -> str:
    with _lock:
        return json.dumps(
            {
                "collections": _collections,
                "watchedEpisodes": _watched_episodes,
                "anilist": _anilist,
            },
            ensure_ascii=False,
        )


def _subject_id(path: str) -> int | None:
    match = re.search(r"/collections/(-?\d+)", path)
    return int(match.group(1)) if match else None


def handle(method: str, path: str, body: str, auth: str) -> tuple[int, str, str]:
    """返回 (status, body, content_type)。path 是 /tracking/... 开头。"""
    # ---------------------------------------------------------- Bangumi
    if "/tracking/bangumi" in path:
        # 官方要求鉴权；夹具只要求 token 非空，且把 token 回显在错误里便于排查。
        if not auth:
            return 401, json.dumps({"title": "Unauthorized"}), "application/json"

        if path.endswith("/v0/me"):
            return (
                200,
                json.dumps({"id": 1, "username": "triomi-fixture", "nickname": "夹具用户"}),
                "application/json",
            )

        if "/v0/search/subjects" in path:
            return (
                200,
                json.dumps({"data": _SEARCH, "total": len(_SEARCH)}),
                "application/json",
            )

        if "/episodes" in path and method == "GET":
            subject = _subject_id(path) or 0
            with _lock:
                watched_ids = set(_watched_episodes.get(subject, []))
            return (
                200,
                json.dumps(
                    {
                        "data": [
                            {"id": eid, "ep": ep, "type": 2 if eid in watched_ids else 0}
                            for eid, ep in _EPISODES
                        ]
                    }
                ),
                "application/json",
            )

        if "/episodes" in path and method == "PATCH":
            subject = _subject_id(path) or 0
            payload = json.loads(body or "{}")
            ids = [int(value) for value in payload.get("episode_id", [])]
            with _lock:
                _watched_episodes[subject] = sorted(set(ids))
            return 204, "", "application/json"

        if path.endswith("/v0/episodes") or "/v0/episodes?" in path:
            return (
                200,
                json.dumps(
                    {"data": [{"id": eid, "ep": ep} for eid, ep in _EPISODES]}
                ),
                "application/json",
            )

        subject = _subject_id(path)
        if subject is not None:
            with _lock:
                current = _collections.get(subject)
            if method == "GET":
                if current is None:
                    return 404, json.dumps({"title": "Not Found"}), "application/json"
                return (
                    200,
                    json.dumps(
                        {"subject_id": subject, "type": current["type"], "ep_status": current["ep_status"]}
                    ),
                    "application/json",
                )
            payload = json.loads(body or "{}")
            with _lock:
                entry = _collections.setdefault(subject, {"type": 3, "ep_status": 0})
                if "type" in payload:
                    entry["type"] = int(payload["type"])
                if "ep_status" in payload:
                    entry["ep_status"] = int(payload["ep_status"])
            return 204, "", "application/json"

    # ---------------------------------------------------------- AniList
    if "/tracking/anilist" in path:
        payload = json.loads(body or "{}")
        query = payload.get("query", "")
        variables = payload.get("variables") or {}

        if "SaveMediaListEntry" in query:
            media_id = int(variables.get("mediaId", 0))
            with _lock:
                entry = _anilist.setdefault(media_id, {"status": "CURRENT", "progress": 0})
                if variables.get("status"):
                    entry["status"] = variables["status"]
                if variables.get("progress") is not None:
                    entry["progress"] = int(variables["progress"])
                snapshot = dict(entry)
            return (
                200,
                json.dumps({"data": {"SaveMediaListEntry": {"id": media_id, **snapshot}}}),
                "application/json",
            )

        if "mediaListEntry" in query:
            media_id = int(variables.get("id", 0))
            with _lock:
                entry = _anilist.get(media_id)
            return (
                200,
                json.dumps(
                    {
                        "data": {
                            "Media": {
                                "mediaListEntry": None
                                if entry is None
                                else {"id": media_id, **entry}
                            }
                        }
                    }
                ),
                "application/json",
            )

        if "Page" in query:
            return (
                200,
                json.dumps(
                    {
                        "data": {
                            "Page": {
                                "media": [
                                    {
                                        "id": 51,
                                        "title": {"romaji": "Fixture Anime 51", "native": "夹具番剧 51"},
                                        "episodes": 12,
                                        "coverImage": {"medium": "http://10.0.2.2:8123/img/cover/n51.png"},
                                    }
                                ]
                            }
                        }
                    }
                ),
                "application/json",
            )

        if "Viewer" in query:
            return (
                200,
                json.dumps({"data": {"Viewer": {"id": 1, "name": "fixture-anilist"}}}),
                "application/json",
            )

        return 200, json.dumps({"errors": [{"message": "unhandled fixture query"}]}), "application/json"

    return 404, "not found", "text/plain"
