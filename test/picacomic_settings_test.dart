import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/picacomic/picacomic_js_source.dart';
import 'package:triomi/core/source/picacomic/picacomic_preferences.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/sources/picacomic_settings_sheet.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/portable_rule_test_support.dart';
import 't2_js_source_test.dart' show FakeJsRuntime;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SourceRule rule;
  setUpAll(() async {
    rule = SourceRule.parseJson(
      await readSourceRuleAsset('assets/rules/picacomic-js.json'),
    );
  });
  for (final save in [true, false]) {
    testWidgets(
      save
          ? 'Pica source settings save non-secret filter without login or network'
          : 'Pica source settings cancel preserves the prior non-secret filter',
      (tester) async {
        final preferences = memoryPreferences();
        final settings = PicacomicPreferences(preferences);
        await settings.set('blocked', 'prior-fixture');
        final http = FakeHttpClient(
          (_) async => throw StateError('No network'),
        );
        final source = PicacomicJsSource(
          rule: rule,
          runtime: FakeJsRuntime(),
          http: http,
          secureStore: MemorySecureStore(),
          preferences: settings,
        );
        addTearDown(source.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => FilledButton(
                  onPressed: () => showPicacomicSettingsSheet(context, source),
                  child: const Text('Open fixture settings'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open fixture settings'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('哔咔漫画 · 来源设置'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'updated-fixture');
        final action = find.widgetWithText(TextButton, '取消');
        final saveAction = find.widgetWithText(FilledButton, '保存');
        await tester.ensureVisible(save ? saveAction : action);
        await tester.tap(save ? saveAction : action);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(AlertDialog), findsNothing);
        expect(settings.blocked, save ? 'updated-fixture' : 'prior-fixture');
        expect(source.isLoggedIn, false);
        expect(http.requests, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
