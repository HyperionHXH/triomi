import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/bangumi_public_client.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/player/danmaku_sources_panel.dart';
import 'package:triomi/features/player/data/danmaku_overlay.dart';
import 'package:triomi/features/player/data/danmaku_session.dart';
import 'package:triomi/features/player/data/danmaku_settings.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_client.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_models.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

const item = MediaItem(
  sourceId: 'playback',
  remoteId: '400602',
  type: MediaType.anime,
  title: '作品',
);
const chapter1 = Chapter(
  sourceId: 'playback',
  remoteId: 'ep1',
  title: '第1集',
  number: 1,
);
const chapter2 = Chapter(
  sourceId: 'playback',
  remoteId: 'ep2',
  title: '第2集',
  number: 2,
);

class _Client extends HybridDanmakuClient {
  _Client()
    : this._(
        FakeHttpClient(
          (_) async => throw StateError('No real HTTP in UI tests'),
        ),
      );
  _Client._(FakeHttpClient http)
    : super(http: http, bangumi: BangumiPublicClient(http));
  final calls = <String>[];
  final owners = <SourceRequestCancellation?>[];
  final pending = <String, Completer<List<DanmakuComment>>>{};
  bool failBilibili = false;
  bool gamerAvailable = false;

  List<DanmakuEpisodeChoice> episodes(DanmakuProviderKind kind) => [
    for (var number = 1; number <= 2; number++)
      DanmakuEpisodeChoice(
        provider: kind,
        id: '${kind.name}-$number',
        title: '真实分集 $number',
        number: number.toDouble(),
      ),
    DanmakuEpisodeChoice(
      provider: kind,
      id: '${kind.name}-sp',
      title: 'SP 1',
      number: 1,
      special: true,
    ),
  ];
  Future<List<DanmakuEpisodeChoice>> _episodes(
    DanmakuProviderKind kind,
    String id,
  ) async {
    calls.add('${kind.name}:$id');
    owners.add(SourceRequestCancellation.current);
    return episodes(kind);
  }

  @override
  Future<List<DanmakuEpisodeChoice>> animekoEpisodes(String subjectId) =>
      _episodes(DanmakuProviderKind.animeko, subjectId);
  @override
  Future<List<DanmakuEpisodeChoice>> bilibiliEpisodesForSubject(
    String subjectId,
  ) => _episodes(DanmakuProviderKind.bilibili, subjectId);
  @override
  Future<List<DanmakuEpisodeChoice>> bilibiliEpisodes(String reference) async {
    final result = await _episodes(DanmakuProviderKind.bilibili, reference);
    final id = RegExp(r'/ep(\d+)').firstMatch(reference)?.group(1);
    return [
      ...result,
      if (id != null)
        DanmakuEpisodeChoice(
          provider: DanmakuProviderKind.bilibili,
          id: id,
          title: '明确 URL 分集',
          special: true,
        ),
    ];
  }

  @override
  Future<List<DanmakuEpisodeChoice>> gamerEpisodesForSubject(
    String subjectId,
  ) async => gamerAvailable
      ? _episodes(DanmakuProviderKind.gamer, subjectId)
      : const [];

  @override
  Future<List<DanmakuEpisodeChoice>> gamerEpisodes(String reference) async {
    final id = Uri.parse(reference).queryParameters['sn']!;
    return [
      DanmakuEpisodeChoice(
        provider: DanmakuProviderKind.gamer,
        id: id,
        title: '动画疯明确分集',
        special: true,
      ),
    ];
  }

  @override
  Future<List<DanmakuComment>> comments(DanmakuEpisodeChoice episode) async {
    owners.add(SourceRequestCancellation.current);
    if (failBilibili && episode.provider == DanmakuProviderKind.bilibili) {
      throw StateError('B站 unavailable');
    }
    final gate = pending[episode.id];
    if (gate != null) return gate.future;
    return [
      DanmakuComment(time: 10, text: episode.id),
      const DanmakuComment(time: 20, text: '共享正文'),
    ];
  }
}

Future<void> settleSession() => Future<void>.delayed(Duration.zero);

void main() {
  test('independent Gamer toggle retains already loaded pools and persists combinations', () async {
    final prefs = memoryPreferences();
    final client = _Client()..gamerAvailable = true;
    final session = DanmakuSession(client: client, preferences: prefs)
      ..setEnabled(true);
    addTearDown(session.dispose);
    session.configure(
      item: item,
      chapter: chapter1,
      canonicalSubjectId: '400602',
    );
    await settleSession();
    final animekoComments = session
        .source(DanmakuProviderKind.animeko)
        .comments;
    expect(
      session.comments.map((comment) => comment.text),
      contains('gamer-1'),
    );
    await session.selectSources({
      DanmakuProviderKind.bilibili,
      DanmakuProviderKind.animeko,
    });
    expect(
      session.source(DanmakuProviderKind.animeko).comments,
      same(animekoComments),
    );
    expect(
      session.comments.map((comment) => comment.text),
      isNot(contains('gamer-1')),
    );
    await session.selectSources({
      DanmakuProviderKind.gamer,
      DanmakuProviderKind.animeko,
    });
    await settleSession();
    expect(
      session.source(DanmakuProviderKind.animeko).comments,
      same(animekoComments),
    );
    expect(
      session.comments.map((comment) => comment.text),
      containsAll(['gamer-1', 'animeko-1']),
    );
    final reopened = DanmakuSession(client: client, preferences: prefs);
    addTearDown(reopened.dispose);
    expect(DanmakuProviderKind.values.where(reopened.includes), [
      DanmakuProviderKind.animeko,
      DanmakuProviderKind.gamer,
    ]);
  });

  test('manual official Gamer video URL can bind an unassociated special episode without guessing', () async {
    final client = _Client();
    final session = DanmakuSession(
      client: client,
      preferences: memoryPreferences(),
    )..setEnabled(true);
    addTearDown(session.dispose);
    session.configure(item: item, chapter: chapter1, canonicalSubjectId: null);
    await session.setGamerReference(
      'https://ani.gamer.com.tw/animeVideo.php?sn=33254',
    );
    expect(session.source(DanmakuProviderKind.gamer).selected?.id, '33254');
    expect(session.source(DanmakuProviderKind.animeko).selected, isNull);
    for (final bad in [
      'http://ani.gamer.com.tw/animeVideo.php?sn=33254',
      'https://evil.test/animeVideo.php?sn=33254',
      'https://ani.gamer.com.tw/animeVideo.php?sn=x',
    ]) {
      await expectLater(session.setGamerReference(bad), throwsFormatException);
    }
  });

  test('only unique normal episode numbers auto match, never specials or array order', () {
    final client = _Client();
    final episodes = client
        .episodes(DanmakuProviderKind.animeko)
        .reversed
        .toList();
    expect(
      DanmakuSession.automaticEpisode(chapter1, episodes)?.id,
      'animeko-1',
    );
    expect(
      DanmakuSession.automaticEpisode(chapter1, [...episodes, episodes.last]),
      isNull,
    );
    for (final title in ['SP1', 'OVA 1', '第1集 特别篇', 'OAD 1', '特典1']) {
      expect(
        DanmakuSession.automaticEpisode(
          Chapter(
            sourceId: 'playback',
            remoteId: title,
            title: title,
            number: 1,
          ),
          episodes,
        ),
        isNull,
      );
    }
    expect(
      DanmakuSession.automaticEpisode(
        const Chapter(sourceId: 'playback', remoteId: 'unknown', title: '正片'),
        episodes,
      ),
      isNull,
    );
  });

  test(
    'sources arrive progressively, a failed source cannot discard the other',
    () async {
      final client = _Client()..failBilibili = true;
      final session = DanmakuSession(
        client: client,
        preferences: memoryPreferences(),
      )..setEnabled(true);
      addTearDown(session.dispose);
      session.configure(
        item: item,
        chapter: chapter1,
        canonicalSubjectId: '400602',
      );
      await settleSession();
      expect(
        session.source(DanmakuProviderKind.bilibili).error,
        contains('unavailable'),
      );
      expect(
        session.source(DanmakuProviderKind.animeko).comments,
        hasLength(2),
      );
      expect(
        session.comments.map((comment) => comment.text),
        contains('animeko-1'),
      );
      client.failBilibili = false;
      await session.retry(DanmakuProviderKind.bilibili);
      expect(
        session.comments,
        hasLength(3),
      ); // identical time/text from the two pools is shown once
    },
  );

  test('a slow source does not hold back already available comments', () async {
    final client = _Client();
    final gate = client.pending['bilibili-1'] = Completer();
    final session = DanmakuSession(
      client: client,
      preferences: memoryPreferences(),
    )..setEnabled(true);
    addTearDown(session.dispose);
    session.configure(
      item: item,
      chapter: chapter1,
      canonicalSubjectId: '400602',
    );
    await settleSession();
    expect(session.source(DanmakuProviderKind.bilibili).loading, isTrue);
    expect(session.source(DanmakuProviderKind.animeko).loading, isFalse);
    expect(
      session.comments.map((comment) => comment.text),
      contains('animeko-1'),
    );
    gate.complete([const DanmakuComment(time: 5, text: 'late B站')]);
    await settleSession();
    expect(
      session.comments.map((comment) => comment.text),
      containsAll(['late B站', 'animeko-1']),
    );
  });

  test('saved display enabled remains off across reopening', () async {
    final preferences = memoryPreferences();
    await const DanmakuSettings(enabled: false).save(preferences);
    expect(DanmakuSettings.load(preferences).enabled, isFalse);
    await DanmakuSettings.load(preferences)
        .copyWith(enabled: true)
        .save(preferences);
    expect(DanmakuSettings.load(preferences).enabled, isTrue);
  });

  test('quick episode switches, off, retries and disposal cancel owners and reject late text', () async {
    final client = _Client();
    final old = client.pending['animeko-1'] = Completer();
    final session = DanmakuSession(
      client: client,
      preferences: memoryPreferences(),
    )..setEnabled(true);
    session.configure(
      item: item,
      chapter: chapter1,
      canonicalSubjectId: '400602',
    );
    await settleSession();
    final oldOwners = client.owners
        .whereType<SourceRequestCancellation>()
        .toList();
    session.configure(
      item: item,
      chapter: chapter2,
      canonicalSubjectId: '400602',
    );
    expect(session.comments, isEmpty);
    expect(oldOwners.every((owner) => owner.cancelled), isTrue);
    await settleSession();
    old.complete([const DanmakuComment(time: 2, text: '过期第1集')]);
    await settleSession();
    expect(
      session.comments.map((comment) => comment.text),
      isNot(contains('过期第1集')),
    );
    final requests = client.calls.length;
    session.setEnabled(false);
    expect(session.comments, isEmpty);
    await session.retry(DanmakuProviderKind.animeko);
    expect(client.calls, hasLength(requests));
    session.setEnabled(true);
    await settleSession();
    expect(
      session.comments.map((comment) => comment.text),
      contains('animeko-2'),
    );
    session.dispose();
    expect(
      client.owners.whereType<SourceRequestCancellation>().every(
        (owner) => owner.cancelled,
      ),
      isTrue,
    );
  });

  test('no association means no guessed Bangumi ID, but official manual B站 correction works', () async {
    final client = _Client();
    final session = DanmakuSession(
      client: client,
      preferences: memoryPreferences(),
    )..setEnabled(true);
    addTearDown(session.dispose);
    session.configure(item: item, chapter: chapter1, canonicalSubjectId: null);
    await settleSession();
    expect(client.calls, isEmpty);
    for (final url in [
      'https://evil.test/ep1',
      'http://www.bilibili.com/bangumi/play/ep1',
      'https://user@www.bilibili.com/bangumi/play/ep1',
      'https://www.bilibili.com.evil.test/bangumi/play/ep1',
    ]) {
      await expectLater(
        session.setBilibiliReference(url),
        throwsFormatException,
      );
    }
    await session.setBilibiliReference(
      'https://www.bilibili.com/bangumi/play/ep779775',
    );
    expect(
      client.calls.single,
      startsWith('bilibili:https://www.bilibili.com/'),
    );
    expect(session.source(DanmakuProviderKind.bilibili).selected?.id, '779775');
    expect(
      session.source(DanmakuProviderKind.bilibili).selected?.special,
      isTrue,
    );
  });

  test('manual match, independent signed offsets and source selection survive reopening by composite key', () async {
    final preferences = memoryPreferences();
    final client = _Client();
    final session = DanmakuSession(client: client, preferences: preferences)
      ..setEnabled(true);
    session.configure(
      item: item,
      chapter: chapter1,
      canonicalSubjectId: '400602',
    );
    await settleSession();
    await session.chooseEpisode(
      client.episodes(DanmakuProviderKind.animeko).last,
    );
    await session.setOffset(DanmakuProviderKind.animeko, -2.5);
    await session.setOffset(DanmakuProviderKind.bilibili, 3);
    expect(session.comments.first.time, 7.5);
    expect(session.comments.map((comment) => comment.time), contains(13));
    await expectLater(
      session.setOffset(DanmakuProviderKind.animeko, double.nan),
      throwsArgumentError,
    );
    await session.selectSources({DanmakuProviderKind.animeko});
    session.dispose();
    final reopened = DanmakuSession(client: client, preferences: preferences)
      ..setEnabled(true);
    addTearDown(reopened.dispose);
    reopened.configure(
      item: item,
      chapter: chapter1,
      canonicalSubjectId: '400602',
    );
    await settleSession();
    expect(DanmakuProviderKind.values.where(reopened.includes), [
      DanmakuProviderKind.animeko,
    ]);
    expect(
      reopened.source(DanmakuProviderKind.animeko).selected?.special,
      isTrue,
    );
    expect(reopened.source(DanmakuProviderKind.animeko).offsetSeconds, -2.5);
    reopened.configure(
      item: const MediaItem(
        sourceId: 'playback',
        remoteId: 'another-work',
        type: MediaType.anime,
        title: '另一作品',
      ),
      chapter: chapter1,
      canonicalSubjectId: '328609',
    );
    expect(reopened.source(DanmakuProviderKind.animeko).offsetSeconds, 0);
    await reopened.setOffset(DanmakuProviderKind.animeko, 0);
    expect(reopened.source(DanmakuProviderKind.animeko).offsetSeconds, 0);
  });

  test('correction persistence is bounded to 128 episode bindings, not an unbounded history', () async {
    final preferences = memoryPreferences();
    final session = DanmakuSession(client: _Client(), preferences: preferences);
    addTearDown(session.dispose);
    for (var index = 0; index < 132; index++) {
      session.configure(
        item: item,
        chapter: Chapter(
          sourceId: 'playback',
          remoteId: '$index',
          title: '$index',
        ),
        canonicalSubjectId: null,
      );
      await session.setOffset(DanmakuProviderKind.animeko, index.toDouble());
    }
    final bindings = jsonDecode(
      preferences.get<String>('danmaku.readonly.bindings')!,
    ) as Map;
    expect(bindings, hasLength(128));
    expect(
      bindings.keys.any(
        (key) => (jsonDecode(key as String) as List).last == '0',
      ),
      isFalse,
    );
    expect(
      bindings.keys.any(
        (key) => (jsonDecode(key as String) as List).last == '131',
      ),
      isTrue,
    );
  });

  testWidgets(
    'renderer uses video rate, freezes paused, skips late history and clears lanes on rewind',
    (tester) async {
      var clock = 0;
      final controller = DanmakuController(wallClockMs: () => clock)
        ..height = 200;
      addTearDown(controller.dispose);
      controller.configure(
        width: 400,
        laneHeight: 24,
        style: const TextStyle(fontSize: 16),
      );
      controller.update(const Duration(seconds: 100), playing: true, rate: 2);
      clock = 500;
      expect(controller.nowMs, 101000);
      controller.update(const Duration(seconds: 101), playing: false, rate: 2);
      clock = 9000;
      expect(controller.nowMs, 101000);
      controller.load([
        for (var index = 0; index <= 102; index++)
          DanmakuComment(time: index.toDouble(), text: 'text$index'),
      ]);
      controller.update(const Duration(seconds: 102), playing: false);
      expect(controller.active.map((entry) => entry.comment.text), ['text102']);
      controller.seek(Duration.zero);
      controller.update(const Duration(seconds: 1), playing: false);
      expect(controller.active.map((entry) => entry.comment.text), ['text1']);
      controller.applySettings(const DanmakuSettings(blockedWords: ['text']));
      controller.update(const Duration(seconds: 2), playing: false);
      expect(controller.active, isEmpty);
      expect(
        DanmakuController(settings: const DanmakuSettings(enabled: false))
            .enabled,
        isFalse,
      );
    },
  );

  testWidgets('pool controls survive positive and negative keyboard inset transitions', (tester) async {
    final session = DanmakuSession(client: _Client(), preferences: memoryPreferences());
    addTearDown(session.dispose);
    session.configure(item: item, chapter: chapter1, canonicalSubjectId: '400602');
    session.setEnabled(true);
    for (final inset in [0.0, 300.0, -300.0, 0.0]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Builder(builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(viewInsets: EdgeInsets.only(bottom: inset)),
          child: DanmakuSourcesPanel(
            session: session,
            onEnabledChanged: (value) async => session.setEnabled(value),
            onAssociate: () {},
          ),
        ))),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final toggle = find.byKey(const ValueKey('danmaku-source-animeko'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      final wasIncluded = session.includes(DanmakuProviderKind.animeko);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(session.includes(DanmakuProviderKind.animeko), !wasIncluded);
      expect(session.includes(DanmakuProviderKind.gamer), isTrue);
    }
  });

  testWidgets(
    'source failure is visible and retries independently inside the real panel',
    (tester) async {
      final client = _Client()..failBilibili = true;
      final session = DanmakuSession(
        client: client,
        preferences: memoryPreferences(),
      )..setEnabled(true);
      addTearDown(session.dispose);
      session.configure(
        item: item,
        chapter: chapter1,
        canonicalSubjectId: '400602',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DanmakuSourcesPanel(
              session: session,
              onEnabledChanged: (value) async => session.setEnabled(value),
              onAssociate: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('B站 · 读取失败'), findsOneWidget);
      expect(find.text('Animeko · 已载入 2 条'), findsOneWidget);
      final animekoComments = session
          .source(DanmakuProviderKind.animeko)
          .comments;
      client.failBilibili = false;
      await tester.ensureVisible(find.text('重试').first);
      await tester.tap(find.text('重试').first);
      await tester.pumpAndSettle();
      expect(find.text('B站 · 已载入 2 条'), findsOneWidget);
      expect(
        identical(
          session.source(DanmakuProviderKind.animeko).comments,
          animekoComments,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone and short desktop panel scroll, explain read-only sources and offer no send action',
    (tester) async {
      final session = DanmakuSession(
        client: _Client(),
        preferences: memoryPreferences(),
      );
      addTearDown(session.dispose);
      session.configure(
        item: item,
        chapter: chapter1,
        canonicalSubjectId: null,
      );
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final size in [const Size(320, 640), const Size(900, 300)]) {
        session.setEnabled(true);
        await session.selectSources(DanmakuProviderKind.values.toSet());
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 560,
                  child: DanmakuSourcesPanel(
                    session: session,
                    onEnabledChanged: (value) async =>
                        session.setEnabled(value),
                    onAssociate: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.textContaining('只读'), findsOneWidget);
        expect(find.text('发送弹幕'), findsNothing);
        await tester.ensureVisible(
          find.byKey(const ValueKey('danmaku-bilibili-url')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(
          find.byKey(const ValueKey('danmaku-source-animeko')),
        );
        await tester.tap(find.byKey(const ValueKey('danmaku-source-animeko')));
        await tester.pumpAndSettle();
        expect(session.enabled, isTrue);
        expect(session.includes(DanmakuProviderKind.animeko), isFalse);
        expect(session.includes(DanmakuProviderKind.gamer), isTrue);
        await tester.tap(find.byKey(const ValueKey('danmaku-source-off')));
        await tester.pumpAndSettle();
        expect(session.enabled, isFalse);
      }
    },
  );
}
