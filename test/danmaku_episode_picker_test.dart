import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/player/danmaku_episode_picker.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_models.dart';

void main() {
  final episodes = [
    const DanmakuEpisodeChoice(
      provider: DanmakuProviderKind.bilibili,
      id: '780514',
      title: 'OP · 勇者',
      special: true,
    ),
    for (var number = 1; number <= 140; number++)
      DanmakuEpisodeChoice(
        provider: DanmakuProviderKind.bilibili,
        id: '${900000 + number}',
        title: '第$number话 · 正片',
        number: number.toDouble(),
      ),
    const DanmakuEpisodeChoice(
      provider: DanmakuProviderKind.bilibili,
      id: 'alternate',
      title: '第115话 · 另一版本',
      number: 115,
    ),
  ];
  Future<void> open(
    WidgetTester tester,
    ValueChanged<DanmakuEpisodeChoice?> result,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result(
                  await showDialog<DanmakuEpisodeChoice>(
                    context: context,
                    builder: (context) => Dialog(
                      child: SizedBox(
                        width: 500,
                        height: 520,
                        child: DanmakuEpisodePicker(
                          title: '真实分集',
                          episodes: episodes,
                        ),
                      ),
                    ),
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'title filtering picks supplemental upstream identity, not filtered array index',
    (tester) async {
      DanmakuEpisodeChoice? selected;
      await open(tester, (value) => selected = value);
      await tester.enterText(
        find.byKey(const ValueKey('danmaku-episode-search')),
        'OP',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('danmaku-episode-bilibili-780514')),
      );
      await tester.pumpAndSettle();
      expect(
        (selected?.id, selected?.special, selected?.number),
        ('780514', true, null),
      );
    },
  );
  testWidgets(
    'real-number location keeps ambiguous versions explicit and does not count specials',
    (tester) async {
      DanmakuEpisodeChoice? selected;
      await open(tester, (value) => selected = value);
      await tester.enterText(
        find.byKey(const ValueKey('danmaku-episode-number')),
        '115',
      );
      await tester.tap(find.text('定位'));
      await tester.pump();
      expect(find.text('2 个匹配分集'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('danmaku-episode-bilibili-900115')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('danmaku-episode-bilibili-alternate')),
      );
      await tester.pumpAndSettle();
      expect(selected?.id, 'alternate');
    },
  );
  testWidgets('invalid number does not select an unrelated upstream episode', (
    tester,
  ) async {
    DanmakuEpisodeChoice? selected;
    await open(tester, (value) => selected = value);
    await tester.enterText(
      find.byKey(const ValueKey('danmaku-episode-number')),
      '9999',
    );
    await tester.tap(find.text('定位'));
    await tester.pump();
    expect(find.text('此来源没有该集号；特别篇请按标题查找'), findsOneWidget);
    expect(selected, isNull);
    await tester.tap(find.byTooltip('关闭分集选择'));
    await tester.pumpAndSettle();
  });
}
