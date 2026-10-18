import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/features/detail/chapter_download_picker.dart';

void main() {
  Future<void> openPicker(
    WidgetTester tester, {
    required MediaType type,
    required List<Chapter> chapters,
    required ValueChanged<Set<String>?> onResult,
    bool supportsContent = true,
    bool enlargedPhone = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(enlargedPhone ? 2 : 1),
            viewInsets: enlargedPhone
                ? const EdgeInsets.only(bottom: 180)
                : EdgeInsets.zero,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => onResult(
                await showChapterDownloadPicker(
                  context,
                  item: MediaItem(
                    sourceId: 'site',
                    remoteId: 'book',
                    type: type,
                    title: 'Book',
                  ),
                  chapters: chapters,
                  supportsContent: supportsContent,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  for (final type in MediaType.values) {
    testWidgets(
      '$type starts empty, rejects locked and returns only chosen identity',
      (tester) async {
        Set<String>? result;
        await openPicker(
          tester,
          type: type,
          chapters: const [
            Chapter(sourceId: 'site', remoteId: 'one', title: 'One'),
            Chapter(sourceId: 'site', remoteId: 'two', title: 'Two'),
            Chapter(
              sourceId: 'site',
              remoteId: 'locked',
              title: 'Locked',
              locked: true,
            ),
          ],
          onResult: (value) => result = value,
        );
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(const ValueKey('download-chapter:2')),
              )
              .onChanged,
          isNull,
        );
        await tester.tap(find.byKey(const ValueKey('download-chapter:1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
        expect(result, {'two'});
      },
    );
  }

  testWidgets('cancel never produces a default full-directory selection', (
    tester,
  ) async {
    var returned = false;
    Set<String>? result = {'must-be-replaced'};
    await openPicker(
      tester,
      type: MediaType.novel,
      chapters: const [
        Chapter(sourceId: 'site', remoteId: 'one', title: 'One'),
      ],
      onResult: (value) {
        returned = true;
        result = value;
      },
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(result, isNull);
  });

  testWidgets(
    'anime playlist switch clears selection and duplicate episode titles do not mix',
    (tester) async {
      Set<String>? result;
      await openPicker(
        tester,
        type: MediaType.anime,
        chapters: const [
          Chapter(
            sourceId: 'site',
            remoteId: 'a:1',
            title: 'Episode 1',
            volumeTitle: 'List A',
          ),
          Chapter(
            sourceId: 'site',
            remoteId: 'b:1',
            title: 'Episode 1',
            volumeTitle: 'List B',
          ),
          Chapter(
            sourceId: 'site',
            remoteId: 'b:2',
            title: 'Episode 2',
            volumeTitle: 'List B',
            locked: true,
          ),
        ],
        onResult: (value) => result = value,
      );
      await tester.tap(find.byKey(const ValueKey('download-chapter:0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('List B · 2集').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('全选当前列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(result, {'b:1'});
    },
  );

  for (final type in [MediaType.manga, MediaType.novel]) {
    testWidgets('$type supports cross-volume subset and explicit clear', (
      tester,
    ) async {
      Set<String>? result;
      await openPicker(
        tester,
        type: type,
        chapters: const [
          Chapter(
            sourceId: 'site',
            remoteId: 'a:1',
            title: 'A1',
            volumeTitle: 'Volume A',
          ),
          Chapter(
            sourceId: 'site',
            remoteId: 'b:1',
            title: 'B1',
            volumeTitle: 'Volume B',
          ),
          Chapter(
            sourceId: 'site',
            remoteId: 'b:2',
            title: 'B2',
            volumeTitle: 'Volume B',
          ),
        ],
        onResult: (value) => result = value,
      );
      await tester.tap(find.text('全选当前卷'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空选择'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('download-chapter:0')));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Volume B · 2章').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('download-chapter:2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(result, {'a:1', 'b:2'});
    });
  }

  testWidgets(
    'ambiguous, foreign, empty and unavailable identities cannot be selected',
    (tester) async {
      await openPicker(
        tester,
        type: MediaType.anime,
        chapters: const [
          Chapter(
            sourceId: 'site',
            remoteId: 'same',
            title: 'A',
            volumeTitle: 'List A',
          ),
          Chapter(
            sourceId: 'site',
            remoteId: 'same',
            title: 'B',
            volumeTitle: 'List B',
          ),
          Chapter(
            sourceId: 'other',
            remoteId: 'foreign',
            title: 'Foreign',
            volumeTitle: 'List A',
          ),
          Chapter(
            sourceId: 'site',
            remoteId: '',
            title: 'Empty',
            volumeTitle: 'List A',
          ),
        ],
        onResult: (_) {},
      );
      for (final tile in tester.widgetList<CheckboxListTile>(
        find.byType(CheckboxListTile),
      )) {
        expect(tile.onChanged, isNull);
      }
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await openPicker(
        tester,
        type: MediaType.novel,
        supportsContent: false,
        chapters: const [
          Chapter(sourceId: 'site', remoteId: 'one', title: 'One'),
        ],
        onResult: (_) {},
      );
      expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile))
            .onChanged,
        isNull,
      );
    },
  );

  testWidgets('large catalog stays lazy on a 200 percent phone with keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await openPicker(
      tester,
      type: MediaType.novel,
      enlargedPhone: true,
      chapters: [
        for (var index = 0; index < 5000; index++)
          Chapter(
            sourceId: 'site',
            remoteId: '$index',
            title: 'Chapter $index',
          ),
      ],
      onResult: (_) {},
    );
    expect(find.byType(CheckboxListTile).evaluate().length, lessThan(30));
    expect(find.text('Chapter 4999'), findsNothing);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a live picker source change clears an earlier selection', (
    tester,
  ) async {
    final identity = ValueNotifier('old');
    addTearDown(identity.dispose);
    final chapters = const [
      Chapter(sourceId: 'site', remoteId: 'one', title: 'One'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: identity,
            builder: (_, remoteId, _) => ChapterDownloadPicker(
              item: MediaItem(
                sourceId: 'site',
                remoteId: remoteId,
                type: MediaType.novel,
                title: 'Book',
              ),
              chapters: chapters,
              supportsContent: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    identity.value = 'new';
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });
}
