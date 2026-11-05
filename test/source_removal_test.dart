import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/sources/sources_page.dart';

import 'fixtures/fake_preferences.dart';

const failure = SourceFailure(
  id: 'broken-rule',
  name: '旧规则',
  type: MediaType.manga,
  message: '旧规则格式无效',
);

void main() {
  testWidgets(
    'failed rule can be removed after confirmation and cancellation keeps it',
    (tester) async {
      final controller = _RemovalSources(
        const SourceRegistrySnapshot(entries: [], failures: [failure]),
      );
      await _pumpSources(tester, controller);
      await tester.tap(find.byTooltip('移除来源 旧规则'));
      await tester.pumpAndSettle();
      expect(find.textContaining('书架、阅读记录和已下载内容保留'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(controller.removed, isEmpty);
      expect(find.text('旧规则'), findsOneWidget);
      await tester.tap(find.byTooltip('移除来源 旧规则'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();
      expect(controller.removed, ['broken-rule']);
      expect(find.text('旧规则'), findsNothing);
      expect(find.text('已移除「旧规则」'), findsOneWidget);
    },
  );

  testWidgets('failed removal stays visible and reports the failure', (
    tester,
  ) async {
    final controller = _RemovalSources(
      const SourceRegistrySnapshot(entries: [], failures: [failure]),
      rejectRemoval: true,
    );
    await _pumpSources(tester, controller);
    await tester.tap(find.byTooltip('移除来源 旧规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(find.text('旧规则'), findsOneWidget);
    expect(find.textContaining('移除来源失败：'), findsOneWidget);
    expect(find.text('已移除「旧规则」'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'native adapter has no removal action while bundled JSON remains removable',
    (tester) async {
      final controller = _RemovalSources(
        SourceRegistrySnapshot(
          entries: [
            SourceEntry(
              descriptor: native.descriptor,
              source: native,
              enabled: true,
            ),
            SourceEntry(
              descriptor: bundled.descriptor,
              source: bundled,
              enabled: true,
              ruleText: '{"id":"bundled"}',
            ),
          ],
          failures: const [],
        ),
      );
      await _pumpSources(tester, controller);
      expect(find.byTooltip('原生适配器更多操作'), findsNothing);
      await tester.tap(find.byTooltip('随包规则更多操作'));
      await tester.pumpAndSettle();
      expect(find.text('移除来源'), findsOneWidget);
    },
  );
}

const native = _Source('native', '原生适配器');
const bundled = _Source('bundled', '随包规则');

Future<void> _pumpSources(
  WidgetTester tester,
  _RemovalSources controller,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(memoryPreferences()),
        sourcesProvider.overrideWith(() => controller),
      ],
      child: const MaterialApp(home: SourcesPage(initialType: MediaType.manga)),
    ),
  );
  await tester.pumpAndSettle();
}

class _RemovalSources extends SourceRegistryController {
  _RemovalSources(this.snapshot, {this.rejectRemoval = false});
  SourceRegistrySnapshot snapshot;
  final bool rejectRemoval;
  final List<String> removed = [];

  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;

  @override
  Future<void> remove(String id) async {
    if (rejectRemoval) throw StateError('Database removal rejected');
    removed.add(id);
    snapshot = SourceRegistrySnapshot(
      entries: snapshot.entries
          .where((entry) => entry.descriptor.id != id)
          .toList(),
      failures: snapshot.failures.where((entry) => entry.id != id).toList(),
    );
    state = AsyncData(snapshot);
  }
}

class _Source implements ContentSource {
  const _Source(this.id, this.name);
  final String id;
  final String name;

  @override
  bool get isReady => true;

  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: name,
    type: MediaType.manga,
    kind: SourceKind.builtin,
  );
}
