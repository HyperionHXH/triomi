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
    List<Map<String, Object?>>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<List<Map<String, Object?>>>(
                    context: context,
                    builder: (_) =>
                        MangaFiltersDialog(fresh: filters, saved: const []),
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
    await tester.tap(first);
    await tester.pump();
    await tester.tap(first);
    await tester.tap(find.widgetWithText(FilterChip, '完结'));
    await tester.tap(find.widgetWithText(FilledButton, '应用'));
    await tester.pumpAndSettle();
    final children = result!.single['state'] as List;
    expect(children.map((dynamic row) => (row as Map)['state']), [2, 0, true]);
    expect(((filters.single['state'] as List).first as Map)['state'], 0);
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
