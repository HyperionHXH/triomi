"""轻之国度（LK）夹具：pc-proxy 信封接口 + pc-comment-proxy 评论接口。

模拟器无外网，端到端验证时把 LK 的 base 指到这里：
`--dart-define=TRIOMI_LK_BASE=http://10.0.2.2:8123/lk`
（客户端拼成 `.../lk/pc-proxy/...` 与 `.../lk/pc-comment-proxy/...`）。

状态存在内存里，`GET /lk/state` 供宿主断言：
- 签到是否真的改到了站点状态（余额 / 连续天数）；
- 发表评论、点赞是否真的落库（`published` / `liked`）；
- `chapter_requests` 记录正文接口实际收到的参数，用于核对
  「chapter_id 被当成 book_id」这类参数问题。
"""

import json
import threading

_lock = threading.Lock()

BOOK_ID = 1001
VOLUME_ID = 2001
CHAPTER_IDS = (3001, 3002)

_COIN_BASE = 128
_SIGN_REWARD = 10
_DAYS = 7


def _seed_comments() -> dict[int, list[dict]]:
    return {
        BOOK_ID: [
            {
                "comment_id": 501,
                "content": "这本真的很上头，推荐！",
                "rating_stars": 5,
                "like_count": 12,
                "publish_time": "2026-08-01 10:00",
                "user": {"uid": 5, "nickname": "书友甲"},
                "interaction_state": {"liked": False},
            },
            {
                "comment_id": 502,
                "content": "",
                "like_count": 3,
                "publish_time": "2026-08-02 10:00",
                "user": {"uid": 6, "nickname": "书友乙"},
                "resources": [{"url": "http://10.0.2.2:8123/img/page/p1.png"}],
            },
            {
                "comment_id": 503,
                "content": "第三卷有点拖",
                "rating_stars": 3,
                "like_count": 1,
                "publish_time": "2026-08-03 10:00",
                "user": {"uid": 7, "nickname": "书友丙"},
                "reply_preview": [
                    {
                        "comment_id": 504,
                        "content": "同感",
                        "user": {"uid": 8, "nickname": "书友丁"},
                    }
                ],
            },
        ]
    }


_comments: dict[int, list[dict]] = _seed_comments()


def _seed_messages() -> dict[str, list[dict]]:
    """分类消息：回复 / @ / 点赞 / 新粉丝 / 系统通知。

    「提到我的」与「回复我的」共用 `message-replies-v1`，用 filter 区分。
    """
    return {
        "reply": [
            {
                "message_id": "r1",
                "user": {"uid": 5, "nickname": "书友甲"},
                "title": "回复了我的评论",
                "content": "同感，这段我也很喜欢。",
                "quote_text": "这本真的很上头",
                "related_title": "夹具轻小说",
                "created_at": "2026-09-20 10:00",
                "unread": True,
                "target_book_id": BOOK_ID,
            },
            {
                "message_id": "r2",
                "user": {"uid": 6, "nickname": "书友乙"},
                "title": "回复了我的评论",
                "content": "第三卷确实有点拖。",
                "created_at": "2026-09-19 10:00",
                "unread": False,
            },
        ],
        "mention": [
            {
                "message_id": "m1",
                "user": {"uid": 7, "nickname": "书友丙"},
                "title": "在评论里提到了我",
                "content": "@夹具书友 一起看吗？",
                "created_at": "2026-09-21 10:00",
                "unread": True,
            }
        ],
        "like": [
            {
                "message_id": "l1",
                "user": {"uid": 8, "nickname": "书友丁"},
                "title": "赞了我的评论",
                "content": "赞了你的评论",
                "created_at": "2026-09-18 10:00",
                "unread": True,
            },
            {
                "message_id": "l2",
                "user": {"uid": 9, "nickname": "书友戊"},
                "title": "赞了我的评论",
                "content": "赞了你的评论",
                "created_at": "2026-09-17 10:00",
                "unread": False,
            },
        ],
        "fan": [],
        "system": [
            {
                "message_id": "s1",
                "title": "系统通知",
                "content": "你的作品已通过审核。",
                "created_at": "2026-09-15 10:00",
                "unread": True,
                "target_book_id": BOOK_ID,
                "related_title": "夹具轻小说",
            }
        ],
    }


def _seed_dm() -> dict:
    return {
        "conversations": [
            {
                "conversation_id": "c1",
                "peer_uid": 66,
                "user": {"uid": 66, "nickname": "私信书友"},
                "last_message": "方便交流一下第三章吗？",
                "unread_count": 1,
                "updated_at": "2026-09-22 10:00",
            }
        ],
        "messages": [
            {
                "message_id": "d1",
                "conversation_id": "c1",
                "peer_uid": 66,
                "sender": {"uid": 42, "nickname": "夹具书友"},
                "content": "你好，有什么想聊的？",
                "created_at": "2026-09-22 09:58",
                "mine": True,
            },
            {
                "message_id": "d2",
                "conversation_id": "c1",
                "peer_uid": 66,
                "sender": {"uid": 66, "nickname": "私信书友"},
                "content": "方便交流一下第三章吗？",
                "created_at": "2026-09-22 10:00",
                "mine": False,
            },
        ],
    }


def _unread_seed() -> dict[str, int]:
    return {
        "unread_count": 8,
        "reply_count": 2,
        "mention_count": 1,
        "like_count": 3,
        "system_count": 1,
        "dm_count": 1,
        "fan_count": 0,
    }


_messages: dict[str, list[dict]] = _seed_messages()
_dm: dict = _seed_dm()
_unread: dict[str, int] = _unread_seed()
_mark_read_requests: list[dict] = []
_liked: set[int] = set()
_signed_days: list[int] = [1, 2]
_streak = 2
_coin = _COIN_BASE
_published: list[dict] = []
_like_requests: list[int] = []
_chapter_requests: list[dict] = []
_next_comment_id = 9001


def reset() -> None:
    global _comments, _liked, _signed_days, _streak, _coin
    global _published, _like_requests, _chapter_requests, _next_comment_id
    global _messages, _dm, _unread, _mark_read_requests
    with _lock:
        _comments = _seed_comments()
        _liked = set()
        _signed_days = [1, 2]
        _streak = 2
        _coin = _COIN_BASE
        _published = []
        _like_requests = []
        _chapter_requests = []
        _next_comment_id = 9001
        _messages = _seed_messages()
        _dm = _seed_dm()
        _unread = _unread_seed()
        _mark_read_requests = []


def state() -> str:
    with _lock:
        return json.dumps(
            {
                "coin": _coin,
                "streak": _streak,
                "signedDays": list(_signed_days),
                "published": _published,
                "liked": sorted(_liked),
                "likeRequests": _like_requests,
                "chapterRequests": _chapter_requests,
                "commentCount": sum(len(items) for items in _comments.values()),
                "unread": dict(_unread),
                "markReadRequests": _mark_read_requests,
            },
            ensure_ascii=False,
        )


def _ok(data: object) -> tuple[int, str, str]:
    return 200, json.dumps({"code": 0, "data": data}, ensure_ascii=False), "application/json"


def _fail(status: int, message: str) -> tuple[int, str, str]:
    """业务失败走 HTTP 200 + 信封里的 code（与站点 pc-proxy 一致，
    客户端 `_post` 也是按 `code != 0` 分类错误的）。"""
    return 200, json.dumps({"code": status, "message": message}, ensure_ascii=False), "application/json"


def _book(book_id: int = BOOK_ID) -> dict:
    return {
        "book_id": book_id,
        "title": "夹具轻小说",
        "author_name": "作者甲",
        "summary_short": "一本用于端到端验证的夹具轻小说。",
        "cover_url": "http://10.0.2.2:8123/img/cover/n51.png",
        "rating_score_10": 8.6,
        "visible_tags": ["奇幻", "连载"],
    }


def _sign_detail() -> dict:
    with _lock:
        days = [
            {
                "day": day,
                "reward_amount": _SIGN_REWARD,
                "claimed": day in _signed_days,
                "claimable": day not in _signed_days and day == _streak + 1,
            }
            for day in range(1, _DAYS + 1)
        ]
        return {
            "title": "每日签到",
            "sub_title": "连续签到领取轻币",
            "current_day": min(_streak + 1, _DAYS),
            "progress": _streak,
            "total_progress": _DAYS,
            "claimed": (_streak + 1) in _signed_days,
            "claimable": (_streak + 1) not in _signed_days,
            "rewards": days,
        }


def handle(method: str, path: str, body: str) -> tuple[int, str, str]:
    """path 形如 /lk/pc-proxy/api/bff/my-home-v1。"""
    global _coin, _streak, _next_comment_id
    global _unread, _messages, _dm, _mark_read_requests

    parts = path.strip("/").split("/")
    endpoint = "/".join(parts[2:]) if len(parts) > 2 else ""

    try:
        payload = json.loads(body) if body else {}
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}

    session = str(payload.get("security_key") or "")

    # ------------------------------------------------------------ 解析
    if endpoint == "api/bff/auth-password-login-v1":
        return _ok(
            {
                "auth": {"security_key": "fixture-lk-key", "uid": 42},
                "user": {"nickname": "夹具书友"},
            }
        )

    if endpoint == "api/bff/auth-session-v1":
        return _ok({"logged_in": bool(session)})

    # ------------------------------------------------------------ 账号域（需登录）
    if endpoint in {
        "api/bff/my-home-v1",
        "api/bff/welfare-sign-detail-v1",
        "api/bff/claim-welfare-sign-v1",
        "api/bff/message-unread-v1",
        "api/bff/message-replies-v1",
        "api/bff/message-likes-v1",
        "api/bff/message-fans-v1",
        "api/bff/message-system-v1",
        "api/bff/message-mark-read-v1",
        "api/bff/dm-conversations-v1",
        "api/bff/dm-messages-v1",
        "api/bff/dm-mark-read-v1",
        "api/bff/bookshelf-v1",
        "api/new-content-read/toggle-book-shelf",
        "api/discuss/publish-book-comment",
        "api/discuss/like-book-comment",
    } and not session:
        return _fail(401, "请先登录轻之国度账号")

    if endpoint == "api/bff/my-home-v1":
        with _lock:
            coin = _coin
            streak = _streak
        return _ok(
            {
                "profile": {
                    "uid": 42,
                    "nickname": "夹具书友",
                    "sign": "夹具签名",
                    "level_name": "初级会员",
                    "coin": coin,
                },
                "stats": {"followers": 12, "following": 3, "publish_articles": 1},
            }
        )

    if endpoint == "api/bff/welfare-sign-detail-v1":
        return _ok(_sign_detail())

    if endpoint == "api/bff/claim-welfare-sign-v1":
        with _lock:
            next_day = _streak + 1
            if next_day not in _signed_days and next_day <= _DAYS:
                _signed_days.append(next_day)
                _streak = next_day
                _coin += _SIGN_REWARD
            reward = _SIGN_REWARD if next_day in _signed_days else 0
            return _ok(
                {"reward_amount": reward, "balance": _coin, "streak_days": _streak}
            )

    if endpoint == "api/bff/message-unread-v1":
        with _lock:
            return _ok({"summary": dict(_unread)})

    # ------------------------------------------------------------ 消息中心
    if endpoint in {
        "api/bff/message-replies-v1",
        "api/bff/message-likes-v1",
        "api/bff/message-fans-v1",
        "api/bff/message-system-v1",
    }:
        category = {
            "api/bff/message-replies-v1": (
                "mention" if payload.get("filter") == "mention" else "reply"
            ),
            "api/bff/message-likes-v1": "like",
            "api/bff/message-fans-v1": "fan",
            "api/bff/message-system-v1": "system",
        }[endpoint]
        page = int(payload.get("page") or 0)
        page_size = int(payload.get("page_size") or 20)
        with _lock:
            items = list(_messages.get(category, []))
        start = max(0, page * page_size)
        window = items[start : start + page_size]
        total = len(items)
        has_more = start + page_size < total
        return _ok(
            {
                "list": window,
                "pagination": {
                    "page": page,
                    "page_size": page_size,
                    "total": total,
                    "has_more": has_more,
                },
            }
        )

    if endpoint == "api/bff/dm-conversations-v1":
        with _lock:
            items = list(_dm["conversations"])
        return _ok({"list": items, "pagination": {"total": len(items)}})

    if endpoint == "api/bff/dm-messages-v1":
        peer_uid = int(payload.get("peer_uid") or 0)
        with _lock:
            items = [
                item for item in _dm["messages"] if item["peer_uid"] == peer_uid
            ]
        return _ok({"list": items, "pagination": {"total": len(items)}})

    if endpoint == "api/bff/message-mark-read-v1":
        category = str(payload.get("category") or "")
        with _lock:
            _mark_read_requests.append(
                {
                    "endpoint": endpoint,
                    "category": category,
                    "scope": str(payload.get("scope") or ""),
                    "hasNonce": bool(payload.get("nonce")),
                    "hasTs": bool(payload.get("ts")),
                }
            )
            key = {
                "reply": "reply_count",
                "mention": "mention_count",
                "like": "like_count",
                "fan": "fan_count",
                "system": "system_count",
            }.get(category)
            if key:
                _unread["unread_count"] = max(
                    0, _unread["unread_count"] - int(_unread.get(key) or 0)
                )
                _unread[key] = 0
            for item in _messages.get(category, []):
                item["unread"] = False
        return _ok({})

    if endpoint == "api/bff/dm-mark-read-v1":
        with _lock:
            _mark_read_requests.append(
                {
                    "endpoint": endpoint,
                    "category": "dm",
                    "hasNonce": bool(payload.get("nonce")),
                    "hasTs": bool(payload.get("ts")),
                }
            )
            _unread["unread_count"] = max(
                0, _unread["unread_count"] - int(_unread.get("dm_count") or 0)
            )
            _unread["dm_count"] = 0
            for item in _dm["conversations"]:
                item["unread_count"] = 0
        return _ok({})

    # ------------------------------------------------------------ 作品 / 目录 / 正文
    if endpoint == "api/bff/home-feed-v1":
        return _ok({"list": [_book()], "page_info": {"has_more": False}})

    if endpoint == "api/bff/bookshelf-v1":
        return _ok({"list": [_book()], "page_info": {"has_more": False}})

    if endpoint == "api/new-content-read/get-book-detail":
        book_id = int(payload.get("book_id") or BOOK_ID)
        book = _book(book_id)
        book["alternate_versions"] = [{"book_id": 1002, "title": "夹具轻小说（全本）"}]
        return _ok(book)

    if endpoint == "api/new-content-read/get-book-volumes":
        return _ok(
            {"list": [{"volume_id": VOLUME_ID, "title": "第一卷"}], "page_info": {}}
        )

    if endpoint == "api/new-content-read/get-volume-chapters":
        return _ok(
            {
                "list": [
                    {
                        "chapter_id": CHAPTER_IDS[0],
                        "volume_id": VOLUME_ID,
                        "title": "第一章 起点",
                        "chapter_no": 1,
                    },
                    {
                        "chapter_id": CHAPTER_IDS[1],
                        "volume_id": VOLUME_ID,
                        "title": "第二章 付费章",
                        "chapter_no": 2,
                        "locked": True,
                    },
                ],
                "page_info": {},
            }
        )

    if endpoint == "api/new-content-read/get-chapter-detail":
        with _lock:
            _chapter_requests.append(dict(payload))
        chapter_id = int(payload.get("chapter_id") or CHAPTER_IDS[0])
        return _ok(
            {
                "chapter_id": chapter_id,
                "volume_id": int(payload.get("volume_id") or VOLUME_ID),
                "title": "第一章 起点",
                "book_title": "夹具轻小说",
                "volume_title": "第一卷",
                "body_snapshot": {
                    "body_html": "<p>夹具正文第一段。</p><p>第二段。</p>",
                    "body_text": "夹具正文第一段。第二段。",
                },
            }
        )

    if endpoint in {
        "api/new-content-read/toggle-book-shelf",
        "api/new-content-read/save-book-history",
    }:
        return _ok({})

    if endpoint == "api/new-content-read/unlock-chapter":
        return _ok({"success": True})

    # ------------------------------------------------------------ 评论
    if endpoint == "api/new-content-read/get-book-comments":
        book_id = int(payload.get("book_id") or BOOK_ID)
        sort = str(payload.get("comment_sort") or "hot")
        page = int(payload.get("page") or 1)
        page_size = int(payload.get("pageSize") or 20)
        with _lock:
            items = list(_comments.get(book_id, []))
        if sort == "latest":
            # 最新在前：按发布时间倒序。
            items.sort(
                key=lambda item: str(item.get("publish_time") or ""), reverse=True
            )
        else:
            # 最热在前：按点赞数倒序。
            items.sort(
                key=lambda item: int(item.get("like_count") or 0), reverse=True
            )
        start = max(0, (page - 1) * page_size)
        window = items[start : start + page_size]
        total = len(items)
        has_next = start + page_size < total
        return _ok(
            {
                "list": window,
                "page_info": {"count": total, "next": 1 if has_next else 0},
                "comment_sort": sort,
            }
        )

    if endpoint == "api/discuss/publish-book-comment":
        book_id = int(payload.get("book_id") or BOOK_ID)
        mentions = payload.get("mention_uids")
        entry = {
            "comment_id": _next_comment_id,
            "content": str(payload.get("content") or ""),
            "rating_stars": int(payload.get("rating_stars") or 0),
            "like_count": 0,
            "publish_time": "2026-09-27 12:00",
            "user": {"uid": 42, "nickname": "夹具书友"},
            "mention_uids": mentions if isinstance(mentions, list) else [],
        }
        with _lock:
            _comments.setdefault(book_id, []).insert(0, entry)
            _published.append(entry)
            _next_comment_id += 1
        return _ok({})

    if endpoint == "api/discuss/like-book-comment":
        comment_id = int(payload.get("comment_id") or 0)
        act = str(payload.get("act") or "like")
        with _lock:
            _like_requests.append(comment_id)
            if act == "like":
                _liked.add(comment_id)
            else:
                _liked.discard(comment_id)
            for items in _comments.values():
                for item in items:
                    if int(item.get("comment_id") or 0) == comment_id:
                        base = int(item.get("like_count") or 0)
                        item["like_count"] = base + 1 if act == "like" else max(0, base - 1)
                        item["interaction_state"] = {"liked": act == "like"}
        return _ok({"liked": act == "like"})

    return 404, json.dumps({"code": 404, "message": f"未登记的 LK 端点：{endpoint}"}), "application/json"
