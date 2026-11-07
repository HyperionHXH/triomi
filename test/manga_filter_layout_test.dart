import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/manga/manga_filters_dialog.dart';

void main() {
  testWidgets('group tags wrap horizontally and preserve tri-state positions', (
    tester,
  ) async {
    final filters = <Map<String, Object?>>[
      {
        'name': '题材',
        'type': 'group',
        'state': [
          {'name': '奇幻', 'type': 'tri', 'state': 0},
          {'name': '日常', 'type': 'tri', 'state': 0},
          {'name': '完结', 'type': 'check', 'state': false},
        ],
      },
    ];
    var saved = <Map<String, Object?>>[];
    final changes = <List<Map<String, Object?>>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () {
                  showDialog<void>(
                    context: context,
                    builder: (_) => MangaFiltersDialog(
                      fresh: filters,
                      saved: saved,
                      onChanged: (rows) {
                        saved = rows;
                        changes.add(rows);
                      },
                    ),
                  );
                },
                child: const Text('open'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final first = find.widgetWithText(FilterChip, '奇幻');
    final second = find.widgetWithText(FilterChip, '日常');
    expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
    expect(find.text('应用'), findsNothing);
    expect(find.text('取消'), findsNothing);
    expect(find.text('保存已应用搜索'), findsNothing);
    expect(
      tester.getCenter(find.widgetWithText(TextButton, '重置')).dy,
      tester.getCenter(find.widgetWithText(FilledButton, '完成')).dy,
    );
    await tester.tap(first);
    await tester.pump();
    await tester.tap(first);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, '完结'));
    await tester.pump();
    final children = saved.single['state'] as List;
    expect(children.map((dynamic row) => (row as Map)['state']), [2, 0, true]);
    expect(changes, hasLength(3));
    expect(
      (changes.first.single['state'] as List).map(
        (dynamic row) => (row as Map)['state'],
      ),
      [1, 0, false],
    );
    expect(((filters.single['state'] as List).first as Map)['state'], 0);
    await tester.tap(find.widgetWithText(FilledButton, '完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, '完结')).selected,
      true,
    );
    expect(
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, '奇幻')).avatar,
      isA<Icon>().having((icon) => icon.icon, 'icon', Icons.remove),
    );
  });

  for (final dismissal in ['close', 'barrier', 'back']) {
    testWidgets('filter edits survive $dismissal dismissal', (tester) async {
      final filters = <Map<String, Object?>>[
        {'name': '完结', 'type': 'check', 'state': false},
      ];
      var saved = <Map<String, Object?>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => MangaFiltersDialog(
                    fresh: filters,
                    saved: saved,
                    onChanged: (rows) => saved = rows,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '完结'));
      await tester.pump();
      expect(saved.single['state'], true);
      switch (dismissal) {
        case 'close':
          await tester.tap(find.byTooltip('关闭筛选'));
        case 'barrier':
          await tester.tapAt(const Offset(4, 4));
        case 'back':
          await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(find.byType(MangaFiltersDialog), findsNothing);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '完结'))
            .selected,
        true,
      );
      expect(filters.single['state'], false);
    });
  }

  testWidgets('schema mismatch waits for reset before emitting defaults', (
    tester,
  ) async {
    final fresh = <Map<String, Object?>>[
      {'name': '完结', 'type': 'check', 'state': false},
      {
        'name': '排序',
        'type': 'sort',
        'state': null,
        'values': ['人气', '更新'],
      },
    ];
    final changes = <List<Map<String, Object?>>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MangaFiltersDialog(
          fresh: fresh,
          saved: const [
            {'name': '旧题材', 'type': 'check', 'state': true},
          ],
          onChanged: changes.add,
        ),
      ),
    );
    expect(find.textContaining('请重置后重新选择'), findsOneWidget);
    await tester.tap(
      find.widgetWithText(FilterChip, '完结'),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(changes, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, '重置'));
    await tester.pumpAndSettle();
    expect(changes.single[0]['state'], false);
    expect(changes.single[1]['state'], isNull);
    expect(find.textContaining('请重置后重新选择'), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, '完结'));
    await tester.pump();
    expect(changes.last[0]['state'], true);
    expect(changes.first[0]['state'], false);
  });

  testWidgets('narrow large text filters have no layout overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: MangaFiltersDialog(
            fresh: [
              {
                'name': '题材',
                'type': 'group',
                'state': [
                  for (var i = 0; i < 20; i++)
                    {'name': '很长的原始来源标签名称$i', 'type': 'tri', 'state': 0},
                ],
              },
              {
                'name': '语言',
                'type': 'select',
                'state': 0,
                'values': ['很长的来源原始语言选项名称', '英文'],
              },
              {
                'name': '标签',
                'type': 'multi',
                'state': <String>[],
                'values': ['很长的来源原始多选标签名称', '连载'],
              },
              {
                'name': '很长的来源排序名称',
                'type': 'sort',
                'state': {'index': 0, 'ascending': true},
                'values': ['很长的来源排序选项名称'],
              },
            ],
            saved: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('查找题材选项'), findsOneWidget);
  });
}
