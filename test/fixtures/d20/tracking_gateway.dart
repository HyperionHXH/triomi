import 'dart:async';
import 'dart:convert';

import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';

import '../fake_http_client.dart';

/// D20 追踪并发夹具：可编程的 Bangumi/AniList 网关。
///
/// 并发控制：
/// - [gate]：置位后所有请求挂起，直到 [release]；用于「早请求晚返回」；
/// - [throwFor]：按请求注入 401/429/超时等分类异常（真实层语义：抛异常）。
class TrackingGateway {
  TrackingGateway({
    this.remoteWatched = 0,
    this.anilistProgress = 0,
    this.episodeCatalog = const <double>[1, 2, 3],
  });

  /// 逐集收藏里 type==2 的条数（远端已看集数）。
  int remoteWatched;

  /// AniList 远端进度。
  int anilistProgress;

  /// Bangumi 剧集目录（ep 缺失时客户端按顺序补号）。
  final List<double> episodeCatalog;

  final List<SourceRequest> requests = <SourceRequest>[];
  final List<String> patchBodies = <String>[];

  /// 按请求抛出的异常（返回 null 表示不抛）。
  SourceException? Function(SourceRequest request)? throwFor;

  Completer<void>? _gate;

  set gate(Completer<void>? value) => _gate = value;

  void release() {
    _gate?.complete();
    _gate = null;
  }

  int get patchCount =>
      requests.where((request) => request.method == 'PATCH').length;

  FakeHttpClient build() => FakeHttpClient(handler);

  Future<SourceResponse> handler(SourceRequest request) async {
    requests.add(request);
    final gate = _gate;
    if (gate != null) await gate.future;
    final thrown = throwFor?.call(request);
    if (thrown != null) throw thrown;

    final url = request.url;
    if (url.contains('bgm.test')) {
      if (url.contains('/episodes?limit')) {
        return _json(<String, Object?>{
          'data': <Object?>[
            for (var index = 0; index < remoteWatched; index++)
              <String, Object?>{'type': 2},
          ],
        }, url);
      }
      if (url.contains('/v0/episodes?')) {
        return _json(<String, Object?>{
          'data': <Object?>[
            for (var index = 0; index < episodeCatalog.length; index++)
              <String, Object?>{
                'id': 101 + index,
                if (episodeCatalog[index] > 0) 'ep': episodeCatalog[index],
              },
          ],
        }, url);
      }
      if (request.method == 'PATCH') {
        patchBodies.add(request.body ?? '');
        return SourceResponse(statusCode: 204, url: url, body: '');
      }
      if (request.method == 'POST') {
        return SourceResponse(statusCode: 204, url: url, body: '');
      }
      if (url.contains('/collections/')) {
        return _json(<String, Object?>{
          'subject_id': 12,
          'type': 3,
          'ep_status': 0,
        }, url);
      }
    }
    if (url.contains('anilist.test')) {
      final body = request.body ?? '';
      if (body.contains('SaveMediaListEntry')) {
        return _json(<String, Object?>{
          'data': <String, Object?>{
            'SaveMediaListEntry': <String, Object?>{'id': 77},
          },
        }, url);
      }
      return _json(<String, Object?>{
        'data': <String, Object?>{
          'Media': <String, Object?>{
            'mediaListEntry': <String, Object?>{
              'id': 77,
              'status': 'CURRENT',
              'progress': anilistProgress,
            },
          },
        },
      }, url);
    }
    return SourceResponse(statusCode: 404, url: url, body: 'unrouted');
  }

  SourceResponse _json(Map<String, Object?> payload, String url) =>
      SourceResponse(
        statusCode: 200,
        url: url,
        body: jsonEncode(payload),
      );
}
