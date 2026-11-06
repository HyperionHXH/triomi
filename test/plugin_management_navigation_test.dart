import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/sources/mihon_extensions_sheet.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    support = await Directory.systemTemp.createTemp('plugin-navigation-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => support.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    await support.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester, {String? initialQuery}) async {
    final preferences = memoryPreferences();
    await preferences.set('sources.filters.mihon', {'query': 'stale'});
    final http = FakeHttpClient(
      (_) async => throw StateError('No repository configured'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          sourceHttpClientProvider.overrideWithValue(http),
        ],
        child: MaterialApp(
          home: MihonExtensionsSheet(initialQuery: initialQuery),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(http.requests, isEmpty);
    expect(preferences.get<Object?>('mihon.repositories'), isNull);
  }

  testWidgets(
    'search is optional and Back closes it before leaving the library',
    (tester) async {
      await open(tester);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byTooltip('搜索插件'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(MihonExtensionsSheet), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'add is a separate destination and starts with no installed search',
    (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('搜索插件'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'installed query');
      await tester.tap(find.byTooltip('添加插件'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      final page = tester.widget<MihonExtensionsSheet>(
        find.byType(MihonExtensionsSheet).last,
      );
      expect(page.browse, isTrue);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'missing-source query activates browse search without seeding repositories',
    (tester) async {
      await open(tester, initialQuery: 'missing source');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'missing source',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('rules return reloads packages and membership before toggling', (
    tester,
  ) async {
    const removed = 'extension.removed';
    const retained = 'extension.retained';
    const host = MethodChannel('triomi/platform');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(host, (_) async => {'ok': true});
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(host, null),
    );
    final preferences = memoryPreferences();
    await preferences.set('mihon.installedPackages', {
      removed: '1',
      retained: '1',
    });
    await preferences.set('mihon.enabledPackages', [removed]);
    await preferences.set('mihon.hostStatus', {
      removed: {'ok': true, 'name': 'Removed'},
      retained: {'ok': true, 'name': 'Retained'},
    });
    final http = FakeHttpClient(
      (_) async => throw StateError('No repository configured'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          sourceHttpClientProvider.overrideWithValue(http),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => MihonExtensionsSheet(
              onRules: () async {
                await Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        onPressed: () async {
                          await preferences.set('mihon.installedPackages', {
                            retained: '1',
                          });
                          await preferences.set(
                            'mihon.enabledPackages',
                            <String>[],
                          );
                          await preferences.set('mihon.hostStatus', {
                            retained: {'ok': true, 'name': 'Retained'},
                          });
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        child: const Text('Apply settings'),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    Future<void> settlePreferences() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    await settlePreferences();
    expect(find.widgetWithText(ListTile, 'Removed'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('规则与来源设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply settings'));
    await settlePreferences();
    expect(find.widgetWithText(ListTile, 'Removed'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Retained'), findsOneWidget);
    await tester.tap(find.byTooltip('插件操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启用'));
    await tester.pumpAndSettle();
    expect(preferences.get<List<Object?>>('mihon.enabledPackages'), [retained]);
    expect(http.requests, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
