import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:unorm_dart/unorm_dart.dart' as unicode;

import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import '../../../core/source/http_client.dart';
import '../../../core/source/source_providers.dart';
import '../../../core/storage/preferences.dart';
import '../../tracking/data/bangumi_client.dart';
import '../../tracking/data/tracking_models.dart';
import '../../tracking/data/tracking_providers.dart';

const animeCollectionStatuses = <String, String>{
  'want': '想看', 'doing': '在看', 'done': '看过',
  'paused': '搁置', 'dropped': '抛弃',
};

class AnimeCollectionEntry {
  const AnimeCollectionEntry({required this.item, required this.status,
    this.progress = 0, required this.updatedAt});
  final MediaItem item;
  final String status;
  final int progress;
  final DateTime updatedAt;
}

class AnimeCollectionSnapshot {
  const AnimeCollectionSnapshot({required this.account, required this.entries,
    required this.loadedAt});
  final String account;
  final List<AnimeCollectionEntry> entries;
  final DateTime loadedAt;
}

/// Account-bound protocol operations. An explicit shelf sync reconciles these
/// states with local favourites; stale-account results are never published.
class AnimeCollectionService {
  AnimeCollectionService({required this.client, required String? Function() token,
    required this.canonical}) : token = token, _identityToken = token();
  final BangumiClient client;
  final String? Function() token;
  final String? _identityToken;
  final Future<MediaItem> Function(MediaItem) canonical;
  Future<void> _writes = Future<void>.value();
  final _requests = SourceRequestCancellation();
  bool _disposed = false;
  void dispose() {
    _disposed = true;
    _requests.cancel();
  }

  String _accountToken() {
    final value = token();
    if (value == null || value.isEmpty) throw StateError('请先在追踪账号设置连接 Bangumi');
    _check(value);
    return value;
  }

  void checkAccount() => _accountToken();

  void _check(String expected) {
    if (_disposed || token() != expected || expected != _identityToken) {
      throw StateError('Bangumi 账号已变化，旧账号的结果未应用；请重新加载');
    }
  }

  Future<int> _subject(MediaItem item) async {
    final subject = await canonical(item);
    final id = int.tryParse(subject.remoteId);
    if (subject.type != MediaType.anime || subject.sourceId != 'bangumi-anime' ||
        id == null || id <= 0) {
      throw StateError('请先选择此季度对应的 Bangumi 动画条目；不会按标题猜测收藏身份');
    }
    return id;
  }

  Future<BangumiCollection?> status(MediaItem item) async {
    final accountToken = _accountToken();
    final id = await _subject(item);
    _check(accountToken);
    final value = await _requests.run(() => client.collection(id, token: accountToken));
    _check(accountToken);
    return value;
  }

  Future<AnimeCollectionSnapshot> load() async {
    final accountToken = _accountToken();
    final me = await _requests.run(() => client.me(accountToken));
    _check(accountToken);
    if (me.id <= 0) throw const FormatException('Bangumi 账号身份无效');
    final entries = <AnimeCollectionEntry>[];
    final ids = <int>{};
    var offset = 0;
    int? total;
    while (true) {
      final page = await _requests.run(() => client.animeCollections('${me.id}', token: accountToken,
        offset: offset));
      _check(accountToken);
      total ??= page.total;
      if (page.total != total || offset + page.rows.length > total) {
        throw StateError('Bangumi 收藏分页发生变化，请重新加载完整列表');
      }
      for (final row in page.rows) {
        final subject = row['subject'];
        final rawId = row['subject_id'] ?? (subject is Map ? subject['id'] : null);
        final id = int.tryParse('$rawId');
        final state = TrackStatusMap.bangumiLocal[row['type']];
        if (subject is! Map || id == null || id <= 0 || state == null) {
          throw const FormatException('Bangumi 动画收藏格式无效，未替换已有列表');
        }
        if (subject['type'] != null && subject['type'] != 2 ||
            subject['id'] != null && '${subject['id']}' != '$id') {
          throw const FormatException('Bangumi 收藏条目身份不一致，未应用列表');
        }
        if (!ids.add(id)) throw StateError('Bangumi 收藏分页发生变化，请重新加载完整列表');
        final images = subject['images'];
        final rating = subject['rating'];
        final translated = '${subject['name_cn'] ?? ''}'.trim();
        entries.add(AnimeCollectionEntry(
          item: MediaItem(sourceId: 'bangumi-anime', remoteId: '$id',
            type: MediaType.anime,
            title: translated.isEmpty ? '${subject['name'] ?? id}' : translated,
            url: 'https://bgm.tv/subject/$id',
            coverUrl: images is Map ? '${images['common'] ?? images['large'] ?? ''}' : null,
            rating: rating is Map && rating['score'] is num
              ? (rating['score'] as num).toDouble() : null),
          status: state,
          progress: (row['ep_status'] as num?)?.toInt() ?? 0,
          updatedAt: DateTime.tryParse('${row['updated_at']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
        ));
      }
      offset += page.rows.length;
      if (offset >= page.total) break;
      if (page.rows.isEmpty) throw StateError('Bangumi 收藏分页中断；已有列表未替换');
    }
    _check(accountToken);
    return AnimeCollectionSnapshot(account: me.nickname.isEmpty ? me.username : me.nickname,
      entries: List.unmodifiable(entries), loadedAt: DateTime.now());
  }

  Future<void> updateStatus(MediaItem item, String status) {
    if (!animeCollectionStatuses.containsKey(status)) {
      throw ArgumentError.value(status, 'status');
    }
    final accountToken = _accountToken();
    final operation = _writes.then((_) async {
      _check(accountToken);
      final id = item.sourceId == 'bangumi-anime' && item.type == MediaType.anime
          ? int.tryParse(item.remoteId) : await _subject(item);
      if (id == null || id <= 0) throw StateError('Bangumi 动画身份无效');
      _check(accountToken);
      await _requests.run(() => client.upsertCollection(id, token: accountToken, status: status));
      _check(accountToken);
    });
    // A failed write must not poison the next explicit user attempt.
    _writes = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<BangumiCollection> updateReview(MediaItem item, {
    required int rate, required String comment, required bool private,
    String? newStatus,
  }) {
    if (rate < 0 || rate > 10 ||
        newStatus != null && !animeCollectionStatuses.containsKey(newStatus)) {
      throw ArgumentError('评分或收藏状态无效');
    }
    final accountToken = _accountToken();
    final operation = _writes.then((_) async {
      _check(accountToken);
      final id = await _subject(item);
      _check(accountToken);
      final current = await _requests.run(() => client.collection(id, token: accountToken));
      _check(accountToken);
      if (current == null && newStatus == null) {
        throw StateError('Bangumi 收藏已不存在，请重新打开并明确选择收藏状态。');
      }
      final normalizedComment = unicode.nfc(comment.trim());
      final isWant = current?.type == 1 ||
          current == null && newStatus == 'want';
      final effectiveRate = isWant ? 0 : rate;
      await _requests.run(() => client.updateReview(id, token: accountToken,
        rate: effectiveRate, comment: normalizedComment, private: private,
        newStatus: current == null ? newStatus : null));
      _check(accountToken);
      final confirmed = await _requests.run(() => client.collection(id, token: accountToken));
      _check(accountToken);
      if (confirmed == null || confirmed.rate != effectiveRate ||
          unicode.nfc(confirmed.comment.trim()) != normalizedComment ||
          confirmed.private != private) {
        throw StateError('评分与吐槽已提交，但读回尚未确认；请重试读取或提交。');
      }
      return confirmed;
    });
    _writes = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }
}

final _bangumiAccountChangesProvider = StreamProvider<Object?>((ref) =>
  ref.watch(preferencesProvider).watch(TrackingServiceKind.bangumi.tokenKey));

final animeCollectionServiceProvider = Provider<AnimeCollectionService>((ref) {
  ref.watch(_bangumiAccountChangesProvider);
  final tracking = ref.watch(trackingServiceProvider);
  final service = AnimeCollectionService(
    client: BangumiClient(http: ref.watch(sourceHttpClientProvider),
      baseUrl: ref.watch(trackingBaseUrlOverridesProvider).bangumi ?? BangumiClient.defaultBaseUrl),
    token: () => tracking.tokenOf(TrackingServiceKind.bangumi),
    canonical: ref.watch(trackingSyncProvider).canonical,
  );
  ref.onDispose(service.dispose);
  return service;
});

