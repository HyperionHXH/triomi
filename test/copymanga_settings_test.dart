import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/copymanga/copymanga_js_source.dart';
import 'package:triomi/core/source/copymanga/copymanga_preferences.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/sources/copymanga_settings_sheet.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 't2_js_source_test.dart' show FakeJsRuntime, jsRuleText;

CopyMangaJsSource _source() {
  final rule = jsonDecode(jsRuleText()) as Map<String, dynamic>;
  rule['id'] = 'copymanga';
  rule['version'] = '1.1.0';
  return CopyMangaJsSource(rule: SourceRule.parseJson(jsonEncode(rule)),
    runtime: FakeJsRuntime(functions: {'searchTags'}, responses: {
      'searchTags': [{'id': 'rexue', 'label': '热血'}],
    }),
    http: FakeHttpClient((_) async => throw StateError('No HTTP expected')),
    preferences: CopyMangaPreferences(memoryPreferences()), secureStore: MemorySecureStore());
}

Future<void> _reveal(WidgetTester tester, Finder target) => tester.scrollUntilVisible(
  target, 250, scrollable: find.byType(Scrollable).first, maxScrolls: 60,
);

void main() {
  testWidgets('Copy settings persists real resolution and comment options without credentials', (tester) async {
    final source = _source();
    addTearDown(source.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CopyMangaSettingsSheet(source: source))));
    expect(find.text('拷贝漫画设置'), findsOneWidget);
    final resolution = find.byKey(const ValueKey('copymanga-resolution'));
    await _reveal(tester, resolution);
    await tester.tap(resolution);
    await tester.pumpAndSettle();
    await tester.tap(find.text('800').last);
    await tester.pumpAndSettle();
    expect(source.settings.value('resolution'), '800');
    expect(source.settings.preferences.get<String>('sources.copymanga.resolution'), '800');
    final comments = find.byKey(const ValueKey('copymanga-showChapterComments'));
    await _reveal(tester, comments);
    await tester.tap(comments);
    await tester.pumpAndSettle();
    expect(source.settings.value('showChapterComments'), true);
    expect(find.byType(TextField), findsNothing);
    expect(jsonEncode(source.settings.preferences.exportAll()), isNot(contains('token')));
  });

  testWidgets('theme refresh loads online taxonomy and persists selected path word', (tester) async {
    final source = _source();
    addTearDown(source.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CopyMangaSettingsSheet(source: source))));
    final refresh = find.text('从站点刷新主题标签');
    await _reveal(tester, refresh);
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    final theme = find.byKey(const ValueKey('copymanga-theme'));
    await tester.drag(find.byType(ListView), const Offset(0, 250));
    await tester.pumpAndSettle();
    await _reveal(tester, theme);
    await tester.tap(theme);
    await tester.pumpAndSettle();
    await tester.tap(find.text('热血').last);
    await tester.pumpAndSettle();
    expect((source.settings.requestOptions['filters'] as Map)['theme'], 'rexue');
  });

  testWidgets('invalid comment regex is rejected with visible error and no stored value', (tester) async {
    final source = _source();
    addTearDown(source.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CopyMangaSettingsSheet(source: source))));
    final edit = find.text('吐槽正则屏蔽');
    await _reveal(tester, edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '[');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(source.settings.value('commentRegex'), '');
    await tester.drag(find.byType(ListView), const Offset(0, 10000));
    await tester.pumpAndSettle();
    expect(find.textContaining('设置未保存'), findsOneWidget);
  });
}
