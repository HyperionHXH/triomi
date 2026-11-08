import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/settings/windows_update_storage.dart';

void main() {
  late Directory directory;
  late WindowsUpdateStorage storage;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'triomi-win-update-retain-',
    );
    storage = WindowsUpdateStorage(rootOverride: directory);
  });
  tearDown(() async {
    WindowsUpdateStorage.active.clear();
    await directory.delete(recursive: true);
  });
  test(
    'pending verified update survives reopening and explicit cache cleanup',
    () async {
      final stage = await directory.createTemp('bundle-');
      await File('${stage.path}/verified-bundle.zip').writeAsBytes([1, 2, 3]);
      await storage.save(stage, {
        'sha256': 'a' * 64,
        'version': '0.15.3',
        'versionCode': 188,
        'windowsRevision': 1,
      });
      final reopened = WindowsUpdateStorage(
        rootOverride: Directory(directory.path),
      );
      final result = await reopened.inspect(clear: true);
      expect(result['removedBytes'], 0);
      expect(await File('${stage.path}/verified-bundle.zip').readAsBytes(), [
        1,
        2,
        3,
      ]);
      expect(
        (await reopened.metadata(
          (await reopened.stages()).single,
        ))?['windowsRevision'],
        1,
      );
    },
  );
  test('completed helper stages are reclaimable immediately after the native lease ends', () async {
    final stage = await directory.createTemp('bundle-');
    await File('${stage.path}/verified-bundle.zip').writeAsBytes([1, 2, 3]);
    await storage.save(stage, {'sha256': 'a' * 64, 'windowsRevision': 1});
    final install = await Directory('${stage.path}/install-completed').create();
    await File('${install.path}/outcome.txt')
        .writeAsString('success\nInstalled and restarted.\n');
    final result = await storage.inspect(maintain: true);
    expect(await stage.exists(), isFalse);
    expect(result['removedBytes'], greaterThan(3));
    expect(result['protectedBytes'], 0);
  });

  test('active writes and native handoffs cannot be reclaimed while abandoned stages can', () async {
    final active = await directory.createTemp('bundle-');
    final handedOff = await directory.createTemp('bundle-');
    final abandoned = await directory.createTemp('bundle-');
    for (final stage in [active, handedOff, abandoned]) {
      await File('${stage.path}/verified-bundle.zip').writeAsBytes([1, 2, 3]);
    }
    WindowsUpdateStorage.active.add(active.absolute.path);
    await File('${handedOff.path}/installing').writeAsString('native lease');
    await File('${directory.path}/unrelated.zip').writeAsBytes([4, 5]);
    final result = await storage.inspect(clear: true);
    expect(await active.exists(), isTrue);
    expect(await handedOff.exists(), isTrue);
    expect(await abandoned.exists(), isFalse);
    expect(await File('${directory.path}/unrelated.zip').readAsBytes(), [4, 5]);
    expect(result['removedBytes'], 3);
    expect(result['protectedBytes'], greaterThanOrEqualTo(6));
  });
  test('symlink stage members never become deletion targets', () async {
    final stage = await directory.createTemp('bundle-');
    final outside = await Directory.systemTemp.createTemp(
      'triomi-outside-update-',
    );
    addTearDown(() => outside.delete(recursive: true));
    final original = await File('${outside.path}/keep')
        .writeAsString('user data');
    try {
      await Link('${stage.path}/alias').create(outside.path);
    } on FileSystemException {
      // Windows link creation needs Developer Mode or explicit privilege.
      markTestSkipped('Windows symbolic-link privilege is unavailable');
      return;
    }
    final result = await storage.inspect(clear: true);
    expect(await original.readAsString(), 'user data');
    expect(await stage.exists(), isTrue);
    expect(result['skippedFiles'], 1);
  });
}
