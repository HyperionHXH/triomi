import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/mihon_source.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/sources/mihon_extensions_sheet.dart';

import 'fixtures/fake_preferences.dart';

class _Sources extends SourceRegistryController {
  _Sources(this.snapshot);
  final SourceRegistrySnapshot snapshot;

  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

void main() {
  testWidgets(
    'unknown probe guides explicit enabling before guarded settings',
    (tester) async {
      const package = 'extension.unknown';
      const action = '请先手动启用，再打开来源设置并重试';
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('triomi-probe-ui-'),
      ))!;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        messenger.setMockMethodCallHandler(paths, null);
        await tester.runAsync(() => directory.delete(recursive: true));
      });
      try {
        final preferences = memoryPreferences();
        await preferences.set('mihon.installedPackages', {package: '1.6.1'});
        await preferences.set('mihon.hostStatus', {
          package: {
            'ok': true,
            'name': 'Probe example',
            'lang': 'zh',
            'versionCode': 106001,
            'filterProbe': 'unknown',
          },
        });
        final source = MihonSource(
          packageName: package,
          hostSourceId: '1',
          name: 'Probe example',
          lang: 'zh',
          enabled: false,
          apkPath: null,
          versionCode: 106001,
          signerSha256: null,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(preferences),
              sourcesProvider.overrideWith(
                () => _Sources(
                  SourceRegistrySnapshot(
                    entries: [
                      SourceEntry(
                        descriptor: source.descriptor,
                        source: source,
                        enabled: false,
                      ),
                    ],
                    failures: const [],
                  ),
                ),
              ),
            ],
            child: const MaterialApp(
              home: Scaffold(body: MihonExtensionsSheet()),
            ),
          ),
        );
        // initState resolves the support path through real filesystem I/O.
        // Yield outside the fake clock and bound both I/O waits and UI frames.
        final guidance = find.textContaining('筛选待验证，$action');
        for (
          var attempt = 0;
          attempt < 60 && guidance.evaluate().isEmpty;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(guidance, findsOneWidget);
        await tester.tap(guidance);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.textContaining('筛选探测未完成；'), findsOneWidget);
        expect(find.textContaining('$action。'), findsOneWidget);
        expect(preferences.get<List<Object?>>('mihon.enabledPackages'), isNull);
        await tester.ensureVisible(find.text('来源设置'));
        await tester.tap(find.text('来源设置'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.textContaining('此来源已停用；请先'), findsOneWidget);
        expect(find.text('规则与来源设置'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
