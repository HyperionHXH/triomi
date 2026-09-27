"""宿主侧自测 LK 夹具端点（不依赖 app）。"""
import json
import urllib.error
import urllib.request

BASE = 'http://127.0.0.1:8123'


def post(path, payload):
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(
        BASE + path, data=data, headers={'Content-Type': 'application/json'}, method='POST'
    )
    with urllib.request.urlopen(req) as response:
        return response.status, json.loads(response.read().decode('utf-8'))


def get(path):
    with urllib.request.urlopen(BASE + path) as response:
        return response.status, json.loads(response.read().decode('utf-8'))


def main():
    post('/lk/reset', {})
    key = {'security_key': 'fixture-lk-key'}

    status, body = post('/lk/pc-proxy/api/bff/auth-password-login-v1', {'username': 'a', 'password': 'b'})
    assert status == 200 and body['code'] == 0, body
    assert body['data']['auth']['security_key'], body
    print('login ok:', body['data']['user']['nickname'])

    status, body = post('/lk/pc-proxy/api/bff/my-home-v1', key)
    profile = body['data']['profile']
    stats = body['data']['stats']
    assert profile['coin'] == 128 and stats['followers'] == 12, body
    print('profile ok:', profile['nickname'], profile['coin'], stats)

    status, body = post('/lk/pc-proxy/api/bff/my-home-v1', {})
    assert body['code'] == 401, body
    print('unauthenticated ok: 401')

    status, body = post('/lk/pc-proxy/api/bff/welfare-sign-detail-v1', key)
    detail = body['data']
    assert len(detail['rewards']) == 7 and detail['claimable'] is True, body
    print('sign detail ok: day', detail['current_day'], 'progress', detail['progress'])

    status, body = post('/lk/pc-proxy/api/bff/claim-welfare-sign-v1', key)
    claim = body['data']
    assert claim['streak_days'] == 3 and claim['balance'] == 138, body
    print('claim ok:', claim)

    status, body = post('/lk/pc-proxy/api/bff/message-unread-v1', key)
    summary = body['data']['summary']
    assert summary['unread_count'] == 8 and summary['dm_count'] == 1, body
    print('unread ok:', summary)

    status, body = post('/lk/pc-proxy/api/bff/message-replies-v1', dict(key, page=0, page_size=20))
    replies = body['data']['list']
    assert [item['message_id'] for item in replies] == ['r1', 'r2'], body
    assert body['data']['pagination']['total'] == 2, body
    print('messages(reply) ok:', [item['message_id'] for item in replies])

    status, body = post('/lk/pc-proxy/api/bff/message-replies-v1', dict(key, filter='mention', page=0, page_size=20))
    assert [item['message_id'] for item in body['data']['list']] == ['m1'], body
    print('messages(mention) ok (filter=mention)')

    status, body = post('/lk/pc-proxy/api/bff/message-likes-v1', dict(key, page=0, page_size=1))
    assert len(body['data']['list']) == 1 and body['data']['pagination']['has_more'] is True, body
    print('messages(like, page size 1) ok: has_more=', body['data']['pagination']['has_more'])

    status, body = post('/lk/pc-proxy/api/bff/message-fans-v1', dict(key, page=0, page_size=20))
    assert body['data']['list'] == [], body
    print('messages(fan) ok: empty list')

    status, body = post('/lk/pc-proxy/api/bff/dm-conversations-v1', dict(key, page=1, page_size=20))
    conversations = body['data']['list']
    assert conversations[0]['peer_uid'] == 66, body
    print('dm conversations ok:', conversations[0]['user']['nickname'])

    status, body = post('/lk/pc-proxy/api/bff/dm-messages-v1', dict(key, peer_uid=66, page=1, page_size=20))
    assert [item['message_id'] for item in body['data']['list']] == ['d1', 'd2'], body
    print('dm messages ok:', [item['content'] for item in body['data']['list']])

    status, body = post('/lk/pc-proxy/api/bff/message-mark-read-v1', dict(key, scope='category', category='like', ts=1, nonce='abc'))
    assert body['code'] == 0, body
    status, body = post('/lk/pc-proxy/api/bff/message-unread-v1', key)
    after = body['data']['summary']
    assert after['like_count'] == 0 and after['unread_count'] == 5, body
    print('mark read ok: like_count ->', after['like_count'], 'unread ->', after['unread_count'])

    status, body = post('/lk/pc-proxy/api/bff/dm-mark-read-v1', dict(key, ts=1, nonce='abc'))
    assert body['code'] == 0, body
    status, body = post('/lk/pc-proxy/api/bff/dm-conversations-v1', dict(key, page=1, page_size=20))
    assert body['data']['list'][0]['unread_count'] == 0, body
    print('dm mark read ok: unread_count -> 0')

    status, body = post('/lk/pc-proxy/api/bff/message-likes-v1', {})
    assert body['code'] == 401, body
    print('messages unauthenticated ok: 401')

    status, body = post('/lk/pc-proxy/api/bff/home-feed-v1', {})
    assert body['data']['list'][0]['book_id'] == 1001, body
    print('feed ok:', body['data']['list'][0]['title'])

    status, body = post('/lk/pc-proxy/api/new-content-read/get-book-detail', {'book_id': 1001})
    assert body['data']['book_id'] == 1001, body
    print('detail ok:', body['data']['title'], body['data']['rating_score_10'])

    status, body = post('/lk/pc-proxy/api/new-content-read/get-book-volumes', {'book_id': 1001})
    assert len(body['data']['list']) == 1, body
    status, body = post('/lk/pc-proxy/api/new-content-read/get-volume-chapters', {'book_id': 1001, 'volume_id': 2001})
    assert len(body['data']['list']) == 2, body
    print('volumes/chapters ok:', [c['title'] for c in body['data']['list']])

    status, body = post('/lk/pc-comment-proxy/api/new-content-read/get-book-comments', {'book_id': 1001, 'comment_sort': 'hot', 'page': 1, 'pageSize': 20})
    items = body['data']['list']
    assert len(items) == 3 and body['data']['page_info']['count'] == 3, body
    print('comments(hot) ok:', [c['comment_id'] for c in items])

    status, body = post('/lk/pc-comment-proxy/api/new-content-read/get-book-comments', {'book_id': 1001, 'comment_sort': 'latest', 'page': 1, 'pageSize': 2})
    print('comments(latest, page 1 size 2):', [c['comment_id'] for c in body['data']['list']], 'next=', body['data']['page_info']['next'])

    status, body = post('/lk/pc-proxy/api/discuss/publish-book-comment', dict(key, book_id=1001, content='夹具发表', mention_uids=[7, 9], rating_stars=4))
    assert body['code'] == 0, body
    status, body = post('/lk/pc-comment-proxy/api/new-content-read/get-book-comments', {'book_id': 1001, 'comment_sort': 'latest', 'page': 1, 'pageSize': 20})
    assert body['data']['list'][0]['content'] == '夹具发表', body
    assert body['data']['list'][0]['mention_uids'] == [7, 9], body
    print('publish ok, latest first =', body['data']['list'][0]['content'])

    status, body = post('/lk/pc-proxy/api/discuss/like-book-comment', dict(key, book_id=1001, comment_id=501, act='like'))
    assert body['data']['liked'] is True, body
    status, body = post('/lk/pc-comment-proxy/api/new-content-read/get-book-comments', {'book_id': 1001, 'comment_sort': 'hot', 'page': 1, 'pageSize': 20})
    liked = [c for c in body['data']['list'] if c['comment_id'] == 501][0]
    assert liked['like_count'] == 13 and liked['interaction_state']['liked'] is True, liked
    print('like ok: count', liked['like_count'], liked['interaction_state'])

    status, body = post('/lk/pc-proxy/api/new-content-read/get-chapter-detail', {'book_id': 1001, 'chapter_id': 3001})
    assert '夹具正文' in body['data']['body_snapshot']['body_html'], body
    print('chapter ok')

    status, body = get('/lk/state')
    print('state:', json.dumps(body, ensure_ascii=False))
    assert body['streak'] == 3 and body['coin'] == 138 and len(body['published']) == 1, body
    assert body['liked'] == [501], body
    assert body['chapterRequests'] == [{'book_id': 1001, 'chapter_id': 3001}], body

    try:
        post('/lk/pc-proxy/api/nope', {})
        raise AssertionError('未登记端点应当返回 404')
    except urllib.error.HTTPError as error:
        assert error.code == 404, error.code
        print('unregistered endpoint ok: 404')

    print('\nALL LK FIXTURE CHECKS PASSED')


if __name__ == '__main__':
    main()
