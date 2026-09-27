import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/novel/data/lk/lk_client.dart';
import 'package:triomi/features/novel/data/lk/lk_source.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

void main() {
  late Preferences preferences;
  late MemorySecureStore secureStore;

  setUp(() {
    preferences = memoryPreferences();
    secureStore = MemorySecureStore();
  });

  LkClient clientOf(FakeHttpClient http) =>
      LkClient(http: http, preferences: preferences, secureStore: secureStore);

  Map<String, dynamic> bodyOf(FakeHttpClient http) =>
      jsonDecode(http.lastRequest.body!) as Map<String, dynamic>;

  group('T5 个人资料', () {
    test('my-home-v1：昵称 / 轻币 / 关注粉丝解析，缺字段降级为 null', () async {
      await secureStore.set('lk.securityKey', 'k-test');
      final http = routingHttpClient(<String, String>{
        '/my-home-v1': jsonEncode(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{
            'profile': <String, Object?>{
              'uid': 42,
              'nickname': '书友甲',
              'sign': '签名',
              'level_name': '初级会员',
              'coin': 128,
            },
            'stats': <String, Object?>{'followers': 12, 'following': 3},
          },
        }),
      });

      final profile = await clientOf(http).myProfile();
      expect(profile.uid, 42);
      expect(profile.nickname, '书友甲');
      expect(profile.signature, '签名');
      expect(profile.levelName, '初级会员');
      expect(profile.coin, 128);
      expect(profile.fansCount, 12);
      expect(profile.followingCount, 3);
      // 缺失的计数是 null（「没有这个数据」），不是 0。
      expect(profile.postCount, isNull);
      expect(bodyOf(http)['security_key'], 'k-test');
    });

    test('my-home-v1：没有 profile 容器时直接吃顶层，昵称有兜底', () async {
      await secureStore.set('lk.securityKey', 'k-test');
      final http = routingHttpClient(<String, String>{
        '/my-home-v1': jsonEncode(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{'uid': 7},
        }),
      });

      final profile = await clientOf(http).myProfile();
      expect(profile.uid, 7);
      expect(profile.nickname, '已登录用户');
      expect(profile.coin, 0);
      expect(profile.fansCount, isNull);
    });

    test('未登录调用：抛 auth 错误并引导登录，不发请求', () async {
      final http = routingHttpClient(const <String, String>{});

      await expectLater(
        clientOf(http).myProfile(),
        throwsA(
          isA<SourceException>()
              .having((error) => error.type, 'type', SourceErrorType.auth)
              .having((error) => error.userMessage, 'message', contains('登录')),
        ),
      );
      expect(http.requests, isEmpty);
    });

    test('关注 / 取关：act 参数正确', () async {
      await secureStore.set('lk.securityKey', 'k-test');
      final http = routingHttpClient(<String, String>{
        '/toggle-user-follow-v1': jsonEncode(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{},
        }),
      });
      final client = clientOf(http);

      await client.setUserFollow(88, follow: true);
      expect(bodyOf(http)['act'], 'follow');
      expect(bodyOf(http)['uid'], 88);

      await client.setUserFollow(88, follow: false);
      expect(bodyOf(http)['act'], 'unfollow');
    });
  });

  group('T5 签到', () {
    test('七日格子解析；领取后连续天数 +1', () async {
      await secureStore.set('lk.securityKey', 'k-test');
      final http = routingHttpClient(<String, String>{
        '/welfare-sign-detail-v1': jsonEncode(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{
            'title': '每日签到',
            'sub_title': '连续签到领轻币',
            'current_day': 3,
            'progress': 2,
            'total_progress': 7,
            'claimed': false,
            'claimable': true,
            'rewards': <Object?>[
              <String, Object?>{'day': 1, 'reward_amount': 5, 'claimed': true},
              <String, Object?>{
                'day': 3,
                'reward_amount': 10,
                'claimable': true,
              },
            ],
          },
        }),
        '/claim-welfare-sign-v1': jsonEncode(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{
            'reward_amount': 10,
            'balance': 138,
            'streak_days': 3,
          },
        }),
      });
      final client = clientOf(http);

      final detail = await client.signDetail();
      expect(detail.title, '每日签到');
      expect(detail.currentDay, 3);
      expect(detail.days, hasLength(2));
      expect(detail.days[1].rewardAmount, 10);
      expect(detail.days[0].claimed, isTrue);
      expect(detail.hasClaimable, isTrue);

      final result = await client.claimSign();
      expect(result.rewardAmount, 10);
      expect(result.balance, 138);
      // 连续天数在签到后 +1（进度 2 → 3）。
      expect(result.streakDays, detail.progress + 1);
    });

    test('消息未读汇总：summary 容器与缺字段降级', () async {
      await secureStore.set('lk.securityKey', 'k-test');
      final http = routingHttpClient(<String, String>{
        '/message-unread-v1': jsonEncode(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{
            'summary': <String, Object?>{
              'unread_count': 5,
              'reply_count': 2,
              'mentions': 1,
            },
          },
        }),
      });

      final summary = await clientOf(http).unreadMessages();
      expect(summary.unreadCount, 5);
      expect(summary.replyCount, 2);
      expect(summary.mentionCount, 1);
      expect(summary.likeCount, 0);
      expect(summary.isEmpty, isFalse);
    });
  });

  group('T5 评论', () {
    test('列表：hot / latest 参数、分页与星级解析，纯图片评论保留', () async {
      final http = routingHttpClient(<String, String>{
        '/get-book-comments': jsonEncode(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{
            'list': <Object?>[
              <String, Object?>{
                'comment_id': 9,
                'content': '不错',
                'rating_stars': 5,
                'like_count': 3,
                'publish_time': '2026-01-01',
                'user': <String, Object?>{'uid': 5, 'nickname': '甲'},
                'interaction_state': <String, Object?>{'liked': true},
              },
              <String, Object?>{
                'comment_id': 10,
                'content': '',
                'resources': <Object?>[
                  <String, Object?>{'url': 'https://example.com/1.jpg'},
                ],
              },
            ],
            'page_info': <String, Object?>{'count': 30, 'next': 2},
          },
        }),
      });
      final client = clientOf(http);

      final page = await client.comments(
        1001,
        sort: 'hot',
        page: 2,
        pageSize: 10,
      );
      expect(page.items, hasLength(2));
      expect(page.items.first.ratingStars, 5);
      expect(page.items.first.liked, isTrue);
      expect(page.items.first.author.nickname, '甲');
      expect(page.items.first.likeCount, 3);
      expect(page.items[1].isImageOnly, isTrue);
      expect(page.items[1].imageUrls, <String>['https://example.com/1.jpg']);
      expect(page.total, 30);
      expect(page.hasMore, isTrue);

      final hotBody = bodyOf(http);
      expect(hotBody['comment_sort'], 'hot');
      expect(hotBody['page'], 2);
      expect(hotBody['pageSize'], 10);
      // 未登录也允许读评论：不带会话，但请求照发。
      expect(hotBody['security_key'], isNull);

      await client.comments(1001, sort: 'latest', page: 1);
      expect(bodyOf(http)['comment_sort'], 'latest');
    });

    test('发表评论：mention_uids 是数组而不是字符串；内容去空白', () async {
      await secureStore.set('lk.securityKey', 'k-test');
      final http = routingHttpClient(<String, String>{
        '/publish-book-comment': jsonEncode(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{},
        }),
      });

      await clientOf(http)
          .publishComment(1001, text: '  回复你  ', mentionUids: <int>[7, 9]);

      final body = bodyOf(http);
      expect(body['content'], '回复你');
      expect(body['mention_uids'], isA<List<dynamic>>());
      expect(body['mention_uids'], <int>[7, 9]);
      expect(body['rating_stars'], 0);
      expect(body['security_key'], 'k-test');
    });

    test('点赞 / 取消：act 与 comment_id', () async {
      await secureStore.set('lk.securityKey', 'k-test');
      final http = routingHttpClient(<String, String>{
        '/like-book-comment': jsonEncode(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{},
        }),
      });
      final client = clientOf(http);

      await client.likeComment(commentId: 77, like: true, bookId: 1001);
      expect(bodyOf(http)['act'], 'like');
      expect(bodyOf(http)['comment_id'], 77);
      expect(bodyOf(http)['book_id'], 1001);

      await client.likeComment(commentId: 77, like: false);
      expect(bodyOf(http)['act'], 'unlike');
    });

    test('评论接口走 pc-comment-proxy；主接口仍走 pc-proxy', () async {
      await secureStore.set('lk.securityKey', 'k-test');
      final http = routingHttpClient(<String, String>{
        '/get-book-comments': jsonEncode(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{'list': <Object?>[]},
        }),
        '/publish-book-comment': jsonEncode(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{},
        }),
      });
      final client = clientOf(http);

      await client.comments(1, sort: 'hot', page: 1);
      expect(
        http.lastRequest.url,
        startsWith('https://api.lightnovel.fun/pc-comment-proxy/'),
      );
      expect(
        http.lastRequest.url,
        contains('/api/new-content-read/get-book-comments'),
      );

      await client.publishComment(1, text: '你好');
      expect(
        http.lastRequest.url,
        startsWith('https://www.lightnovel.fun/api/pc-proxy/'),
      );
    });

    test('注入 base：夹具地址替换后请求打到注入的源', () async {
      await secureStore.set('lk.securityKey', 'k-test');
      final http = routingHttpClient(<String, String>{
        '/get-book-comments': jsonEncode(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{'list': <Object?>[]},
        }),
      });
      final client = LkClient(
        http: http,
        preferences: preferences,
        secureStore: secureStore,
        mainBase: 'http://127.0.0.1:8123/api/pc-proxy/',
        commentBase: 'http://127.0.0.1:8123/pc-comment-proxy/',
      );

      await client.comments(1, sort: 'hot', page: 1);
      expect(
        http.lastRequest.url,
        startsWith('http://127.0.0.1:8123/pc-comment-proxy/'),
      );
    });
  });

  group('T5 LkSource 账号域转发', () {
    test('评论按作品编号转发（latest）', () async {
      final http = routingHttpClient(<String, String>{
        '/get-book-comments': jsonEncode(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{'list': <Object?>[]},
        }),
      });
      final source = LkSource(client: clientOf(http));

      await source.comments('1001', sort: 'latest', page: 1);
      final body = bodyOf(http);
      expect(body['book_id'], 1001);
      expect(body['comment_sort'], 'latest');
    });

    test('非法评论编号：抛解析错误', () async {
      final source = LkSource(
        client: clientOf(routingHttpClient(const <String, String>{})),
      );

      await expectLater(
        source.likeComment('abc', like: true),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.parse,
          ),
        ),
      );
    });
  });
}
