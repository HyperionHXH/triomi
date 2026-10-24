import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/models/chapter.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/source_exception.dart';
import '../../../core/source/http_client.dart';
import '../../../core/storage/preferences.dart';
import 'hybrid_danmaku_client.dart';
import 'hybrid_danmaku_models.dart';

class DanmakuSourceState {
  List<DanmakuEpisodeChoice> episodes = const [];
  DanmakuEpisodeChoice? selected;
  List<DanmakuComment> comments = const [];
  bool loading = false;
  String? error;
  double offsetSeconds = 0;
}

/// One player's read-only request ownership and bounded episode corrections.
/// This object never owns or waits for the video decoder.
class DanmakuSession extends ChangeNotifier {
  DanmakuSession({required this._client, required this.preferences}) {
    final saved = preferences.get<Object?>(_selectionKey);
    final names = saved is List ? saved.whereType<String>().toSet() : {saved};
    _selection.addAll(
      saved == null || saved == 'both'
          ? DanmakuProviderKind.values
          : DanmakuProviderKind.values.where(
              (kind) => names.contains(kind.name),
            ),
    );
    try {
      final raw = jsonDecode(preferences.get<String>(_bindingsKey) ?? '{}');
      if (raw is Map) {
        for (final entry
            in raw.entries.toList().reversed.take(128).toList().reversed) {
          if (entry.key is String && entry.value is Map) {
            _bindings[entry.key as String] = Map<String, Object?>.from(
              entry.value as Map,
            );
          }
        }
      }
    } on FormatException {
      // A damaged correction cannot manufacture an upstream episode identity.
    }
  }

  static const _selectionKey = 'danmaku.readonly.sources';
  static const _bindingsKey = 'danmaku.readonly.bindings';
  final Preferences preferences;
  HybridDanmakuClient _client;
  final _bindings = <String, Map<String, Object?>>{};
  final _owners = <DanmakuProviderKind, SourceRequestCancellation>{};
  final _states = {
    for (final kind in DanmakuProviderKind.values) kind: DanmakuSourceState(),
  };
  Future<void> _saving = Future.value();
  int _generation = 0;
  bool _disposed = false;
  bool enabled = false;
  final _selection = <DanmakuProviderKind>{};
  String? subjectId;
  String? associationError;
  String? _bindingKey;
  Chapter? _chapter;
  bool _automatic = true;
  final _references = <DanmakuProviderKind, String>{};
  String? get bindingKey => _bindingKey;

  DanmakuSourceState source(DanmakuProviderKind kind) => _states[kind]!;
  bool includes(DanmakuProviderKind kind) => _selection.contains(kind);

  static bool specialChapter(Chapter chapter) => RegExp(
    r'(?:\b(?:SP|OP|ED|PV|OVA|OAD|ONA|SPECIAL)\s*\d*\b|特别篇|特別篇|特典|总集篇|總集篇|番外|预告|預告)',
    caseSensitive: false,
  ).hasMatch(chapter.title);

  static DanmakuEpisodeChoice? automaticEpisode(
    Chapter chapter,
    List<DanmakuEpisodeChoice> episodes,
  ) {
    final number = chapter.number;
    if (number == null || !number.isFinite || specialChapter(chapter)) {
      return null;
    }
    final matches = episodes
        .where((episode) => !episode.special && episode.number == number)
        .toList();
    return matches.length == 1 ? matches.single : null;
  }

  void configure({
    required MediaItem item,
    required Chapter chapter,
    required String? canonicalSubjectId,
    bool allowAutomatic = true,
    String? error,
    bool force = false,
  }) {
    final key = jsonEncode([
      item.sourceId,
      item.remoteId,
      chapter.sourceId,
      chapter.remoteId,
    ]);
    if (!force &&
        _bindingKey == key &&
        subjectId == canonicalSubjectId &&
        associationError == error &&
        _automatic == allowAutomatic) {
      return;
    }
    _bindingKey = key;
    _chapter = chapter;
    subjectId = canonicalSubjectId;
    associationError = error;
    _automatic = allowAutomatic;
    final binding = _bindings[key];
    _references.clear();
    for (final kind in [
      DanmakuProviderKind.bilibili,
      DanmakuProviderKind.gamer,
    ]) {
      final reference = binding?['${kind.name}Reference'];
      if (reference is String) _references[kind] = reference;
    }
    for (final kind in DanmakuProviderKind.values) {
      final raw = binding?['${kind.name}Offset'];
      source(kind).offsetSeconds = raw is num && raw.isFinite
          ? raw.toDouble().clamp(-3600, 3600)
          : 0;
    }
    restart();
  }

  void replaceClient(HybridDanmakuClient client) {
    if (identical(_client, client)) return;
    _client = client;
    restart();
  }

  void setEnabled(bool value) {
    if (enabled == value) return;
    enabled = value;
    restart();
  }

  Future<void> selectSources(Set<DanmakuProviderKind> sources) async {
    final previous = Set<DanmakuProviderKind>.of(_selection);
    _selection
      ..clear()
      ..addAll(sources);
    for (final kind in DanmakuProviderKind.values) {
      if (previous.contains(kind) == includes(kind)) continue;
      if (includes(kind)) {
        if (enabled) unawaited(retry(kind));
      } else {
        _owners.remove(kind)?.cancel();
        final state = source(kind);
        state.comments = const [];
        state.episodes = const [];
        state.selected = null;
        state.loading = false;
        state.error = null;
      }
    }
    _notify();
    await preferences.set(_selectionKey, [
      for (final kind in DanmakuProviderKind.values)
        if (includes(kind)) kind.name,
    ]);
  }

  void restart({bool fetch = true}) {
    _generation++;
    for (final owner in _owners.values) {
      owner.cancel();
    }
    _owners.clear();
    for (final state in _states.values) {
      state.comments = const [];
      state.episodes = const [];
      state.selected = null;
      state.error = null;
      state.loading = false;
    }
    _notify();
    if (!fetch || !enabled || _chapter == null) return;
    for (final kind in DanmakuProviderKind.values) {
      if (includes(kind)) unawaited(retry(kind));
    }
  }

  bool _active(
    int generation,
    DanmakuProviderKind kind,
    SourceRequestCancellation owner,
  ) =>
      !_disposed &&
      enabled &&
      includes(kind) &&
      generation == _generation &&
      identical(_owners[kind], owner) &&
      !owner.cancelled;

  Future<void> retry(DanmakuProviderKind kind) async {
    if (!enabled || !includes(kind) || _chapter == null) return;
    _owners.remove(kind)?.cancel();
    final owner = _owners[kind] = SourceRequestCancellation();
    final generation = _generation;
    final state = source(kind);
    state.comments = const [];
    state.error = null;
    state.loading = true;
    state.selected = null;
    state.episodes = const [];
    _notify();
    try {
      final reference = _references[kind];
      final id = subjectId;
      if (id == null && reference == null) return;
      final episodes = await owner.run(
        () => switch (kind) {
          DanmakuProviderKind.animeko => _client.animekoEpisodes(id!),
          DanmakuProviderKind.bilibili =>
            reference != null
                ? _client.bilibiliEpisodes(reference)
                : _client.bilibiliEpisodesForSubject(id!),
          DanmakuProviderKind.gamer =>
            reference != null
                ? _client.gamerEpisodes(reference)
                : _client.gamerEpisodesForSubject(id!),
        },
      );
      if (!_active(generation, kind, owner)) return;
      state.episodes = episodes;
      final savedId = _bindings[_bindingKey]?['${kind.name}Episode'];
      final saved = episodes
          .where((episode) => episode.id == savedId)
          .firstOrNull;
      final explicitId = switch (kind) {
        DanmakuProviderKind.bilibili when reference != null => RegExp(
          r'/play/ep(\d+)/?$',
        ).firstMatch(Uri.parse(reference).path)?.group(1),
        DanmakuProviderKind.gamer
            when reference != null &&
                Uri.parse(reference).path == '/animeVideo.php' =>
          Uri.parse(reference).queryParameters['sn'],
        _ => null,
      };
      final explicit = episodes
          .where((episode) => episode.id == explicitId)
          .firstOrNull;
      state.selected =
          saved ??
          explicit ??
          (explicitId == null && _automatic
              ? automaticEpisode(_chapter!, episodes)
              : null);
      _notify();
      if (state.selected != null) {
        final comments = await owner.run(
          () => _client.comments(state.selected!),
        );
        if (!_active(generation, kind, owner)) return;
        state.comments = comments;
      }
    } catch (error) {
      if (_active(generation, kind, owner)) {
        state.error = SourceException.sanitizeMessage(
          error is SourceException ? error.message ?? '弹幕请求失败' : '$error',
        );
      }
    } finally {
      if (_active(generation, kind, owner)) {
        state.loading = false;
        _notify();
      }
    }
  }

  Future<void> chooseEpisode(DanmakuEpisodeChoice episode) async {
    final kind = episode.provider;
    if (!enabled ||
        !includes(kind) ||
        !source(kind).episodes.any((value) => value.id == episode.id)) {
      return;
    }
    _owners.remove(kind)?.cancel();
    final owner = _owners[kind] = SourceRequestCancellation();
    final generation = _generation;
    final state = source(kind);
    state.comments = const [];
    state.selected = episode;
    state.loading = true;
    state.error = null;
    _remember('${kind.name}Episode', episode.id);
    _notify();
    try {
      final comments = await owner.run(() => _client.comments(episode));
      if (_active(generation, kind, owner)) state.comments = comments;
    } catch (error) {
      if (_active(generation, kind, owner)) {
        state.error = SourceException.sanitizeMessage(
          error is SourceException ? error.message ?? '弹幕请求失败' : '$error',
        );
      }
    } finally {
      if (_active(generation, kind, owner)) {
        state.loading = false;
        _notify();
      }
    }
    await _saving;
  }

  Future<void> setBilibiliReference(String reference) async {
    final uri = Uri.tryParse(reference.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        !{
          'www.bilibili.com',
          'bilibili.com',
          'm.bilibili.com',
        }.contains(uri.host.toLowerCase()) ||
        !RegExp(r'^/bangumi/(?:play/(?:ep|ss)\d+|media/md\d+)/?$')
            .hasMatch(uri.path)) {
      throw const FormatException('请输入 B站官方 HTTPS 剧集、季度或媒体 URL');
    }
    _references[DanmakuProviderKind.bilibili] = uri.toString();
    _remember('bilibiliReference', uri.toString());
    _remember('bilibiliEpisode', null);
    await retry(DanmakuProviderKind.bilibili);
    await _saving;
  }

  Future<void> setGamerReference(String reference) async {
    final uri = Uri.tryParse(reference.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        !{'ani.gamer.com.tw', 'anime.gamer.com.tw'}.contains(uri.host) ||
        !{'/animeVideo.php', '/animeRef.php'}.contains(uri.path) ||
        !RegExp(r'^[1-9]\d*$').hasMatch(uri.queryParameters['sn'] ?? '')) {
      throw const FormatException(
        '请输入动画疯官方 animeVideo.php 或 animeRef.php HTTPS URL',
      );
    }
    final normalized = uri
        .replace(
          queryParameters: {'sn': uri.queryParameters['sn']},
          fragment: '',
        )
        .toString();
    _references[DanmakuProviderKind.gamer] = normalized;
    _remember('gamerReference', normalized);
    _remember('gamerEpisode', null);
    await retry(DanmakuProviderKind.gamer);
    await _saving;
  }

  Future<void> resetMatch(DanmakuProviderKind kind) async {
    _remember('${kind.name}Episode', null);
    if (kind != DanmakuProviderKind.animeko) {
      _references.remove(kind);
      _remember('${kind.name}Reference', null);
    }
    await retry(kind);
    await _saving;
  }

  Future<void> setOffset(DanmakuProviderKind kind, double seconds) async {
    if (!seconds.isFinite || seconds.abs() > 3600) {
      throw ArgumentError('偏移需为 -3600 至 3600 之间的有限秒数');
    }
    source(kind).offsetSeconds = seconds;
    _remember('${kind.name}Offset', seconds);
    _notify();
    await _saving;
  }

  void _remember(String field, Object? value) {
    final key = _bindingKey;
    if (key == null) return;
    final binding = _bindings.remove(key) ?? <String, Object?>{};
    if (value == null) {
      binding.remove(field);
    } else {
      binding[field] = value;
    }
    _bindings[key] = binding;
    while (_bindings.length > 128) {
      _bindings.remove(_bindings.keys.first);
    }
    final encoded = jsonEncode(_bindings);
    _saving = _saving
        .catchError((Object _) {})
        .then((_) => preferences.set(_bindingsKey, encoded));
  }

  List<DanmakuComment> get comments {
    final result = <DanmakuComment>[];
    final seen = <(int, String)>{};
    if (!enabled) return result;
    for (final kind in DanmakuProviderKind.values) {
      if (!includes(kind)) continue;
      final state = source(kind);
      for (final comment in state.comments) {
        final time = comment.time + state.offsetSeconds;
        if (!time.isFinite ||
            time < 0 ||
            comment.text.isEmpty ||
            !seen.add(((time * 1000).round(), comment.text))) {
          continue;
        }
        result.add(
          DanmakuComment(
            time: time,
            text: comment.text,
            mode: comment.mode,
            color: comment.color,
            user: comment.user.isEmpty ? '' : '${kind.name}:${comment.user}',
          ),
        );
      }
    }
    return result..sort((a, b) => a.time.compareTo(b.time));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    for (final owner in _owners.values) {
      owner.cancel();
    }
    _owners.clear();
    super.dispose();
  }
}
