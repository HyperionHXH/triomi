import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_restore_preview.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/features/profile/backup_restore_dialog.dart';

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      'restore preview explains unsupported rules and preserves explicit choices on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.physicalSize = const Size(1000, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        BackupRestoreOptions? options;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    options = await confirmBackupRestore(
                      context,
                      const BackupRestorePreview(
                        incomingWins: 1,
                        localWins: 0,
                        equalTimestampConflicts: 0,
                        byteHash: 'fixture',
                        incomingSourceRules: 1,
                        unsupportedSourceRules: 2,
                        incomingApkPackages: 1,
                      ),
                      target: 'Isolated fixture',
                    );
                  },
                  child: const Text('Restore'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Restore'));
        await tester.pumpAndSettle();
        expect(find.textContaining('另有 2 个规则'), findsOneWidget);
        final ruleSwitch = find.widgetWithText(SwitchListTile, '恢复规则定义（保持停用）');
        expect(tester.widget<SwitchListTile>(ruleSwitch).value, false);
        await tester.tap(ruleSwitch);
        await tester.pumpAndSettle();
        if (platform == TargetPlatform.iOS) {
          expect(find.textContaining('iOS不能运行APK扩展'), findsOneWidget);
          expect(find.text('暂存APK包（不加载、不导入信任）'), findsNothing);
        } else {
          final apkSwitch = find.widgetWithText(
            SwitchListTile,
            '暂存APK包（不加载、不导入信任）',
          );
          await tester.ensureVisible(apkSwitch);
          await tester.tap(apkSwitch);
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('确认合并当前备份'));
        await tester.pumpAndSettle();
        expect(options?.restoreSourceRules, true);
        expect(options?.restoreApkPackages, platform != TargetPlatform.iOS);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets(
    'unsupported-only backup cannot opt into restoring incompatible code',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => confirmBackupRestore(
                  context,
                  const BackupRestorePreview(
                    incomingWins: 0,
                    localWins: 0,
                    equalTimestampConflicts: 0,
                    byteHash: 'fixture',
                    unsupportedSourceRules: 1,
                  ),
                  target: 'Isolated fixture',
                ),
                child: const Text('Restore'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, '恢复规则定义（保持停用）'),
      );
      expect(tile.value, false);
      expect(tile.onChanged, isNull);
    },
  );
}
