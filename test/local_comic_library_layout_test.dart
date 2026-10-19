import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/local/local_comic_library_page.dart';

import 'fixtures/test_database.dart';

void main() {
  for (final scenario in [
    (size: const Size(393, 852), scale: 1.0),
    (size: const Size(320, 720), scale: 2.0),
    (size: const Size(640, 360), scale: 2.0),
  ]) {
    testWidgets(
      'local comic empty state stays inset and clear of import action '
      '${scenario.size} ${scenario.scale}x',
      (tester) async {
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = openTestDatabase();
        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [databaseProvider.overrideWithValue(db)],
              child: MaterialApp(
                theme: AppTheme.light(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scenario.scale)),
                  child: child!,
                ),
                home: const LocalComicLibraryPage(),
              ),
            ),
          );
          for (var attempt = 0; attempt < 8; attempt++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump();
          }
          final emptyText = find.textContaining('尚未导入本地漫画');
          await tester.ensureVisible(emptyText);
          await tester.pumpAndSettle();
          final rect = tester.getRect(emptyText);
          expect(rect.left, greaterThanOrEqualTo(24));
          expect(rect.right, lessThanOrEqualTo(scenario.size.width - 24));
          expect(tester.widget<Text>(emptyText).textAlign, TextAlign.center);
          final actionRect = tester.getRect(find.byType(FloatingActionButton));
          expect(rect.bottom, lessThanOrEqualTo(actionRect.top));
          await tester.drag(
            find.byType(CustomScrollView),
            Offset(0, -scenario.size.height),
          );
          await tester.pumpAndSettle();
          final message = find.textContaining('点击右下角');
          final messageRect = tester.getRect(message);
          expect(messageRect.left, greaterThanOrEqualTo(24));
          expect(
            messageRect.right,
            lessThanOrEqualTo(scenario.size.width - 24),
          );
          expect(messageRect.top, greaterThanOrEqualTo(0));
          expect(messageRect.bottom, lessThanOrEqualTo(actionRect.top));
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await tester.runAsync(db.close);
        }
      },
    );
  }
}
