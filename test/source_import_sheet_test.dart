import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/sources/sources_page.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _EmptySources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async => const SourceRegistrySnapshot(
    entries: [], failures: [],
  );
}

void main() {
  testWidgets('dismissed import sheet keeps fields alive through exit and reopens empty', (tester) async {
    final database = openTestDatabase();
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      preferencesProvider.overrideWithValue(memoryPreferences()),
      sourcesProvider.overrideWith(_EmptySources.new),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await database.close();
    });
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SourcesPage(initialType: MediaType.anime)),
    ));
    await tester.pumpAndSettle();
    Future<void> open() async {
      await tester.tap(find.text('添加番剧来源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('手动导入规则'));
      await tester.pumpAndSettle();
    }
    Finder inputs() => find.descendant(
      of: find.byType(BottomSheet).last, matching: find.byType(TextField),
    );
    await open();
    await tester.enterText(inputs().first, '{"name":"旧规则"}');
    await tester.enterText(inputs().last, 'https://example.test/old.json');
    Navigator.of(tester.element(find.text('导入番剧规则'))).pop();
    await tester.pump();
    // The route future completes before its reverse animation removes fields.
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.text('导入番剧规则'), findsNothing);
    await open();
    final fields = tester.widgetList<TextField>(inputs()).toList();
    expect(fields.map((field) => field.controller!.text), ['', '']);
    await tester.enterText(inputs().first, '{"name":"新规则"}');
    expect(fields.first.controller!.text, '{"name":"新规则"}');
    Navigator.of(tester.element(find.text('导入番剧规则'))).pop();
    await tester.pumpAndSettle();
  });
}
