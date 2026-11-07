import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/mihon_installer.dart';
import 'package:triomi/core/source/mihon_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

MihonExtension extension(String package, {int version = 1, String? icon}) =>
    MihonExtension(
      name: package,
      packageName: package,
      apkUrl: 'https://repo.example/$package.apk',
      iconUrl: icon ?? 'https://repo.example/icon/$package.png',
      extensionLib: '1.4',
      versionCode: version,
      versionName: '$version.0',
      sources: const [],
    );

void main() {
  test('known matching versions recover only artwork and keep trust', () async {
    final preferences = memoryPreferences();
    final original = <String, Object?>{
      'versionName': '1.0',
      'versionCode': 1,
      'signerSha256': 'pinned-publisher',
      'sha256': 'verified-apk',
      'enabled': false,
      'sources': [
        {'id': '123', 'name': 'source'},
      ],
    };
    await preferences.set('mihon.installedPackages', {
      'installed': '1.0',
      'outdated': '0.0',
    });
    await preferences.set('mihon.hostStatus', {
      'installed': original,
      'outdated': {'versionName': '0.0', 'versionCode': 0},
      'already': {...original, 'iconUrl': 'https://old.example/already.png'},
      'invalid': original,
    });
    final installer = MihonInstaller(
      preferences: preferences,
      http: FakeHttpClient(
        (_) async => throw StateError('no network expected'),
      ),
    );
    final recovered = await installer.cacheRepositoryIcons([
      extension('installed'),
      extension('outdated'),
      extension('already'),
      extension('unknown'),
      extension('invalid', icon: 'file:///private/icon.png'),
    ]);
    expect(recovered, {'installed': 'https://repo.example/icon/installed.png'});
    final statuses = preferences.get<Map<dynamic, dynamic>>(
      'mihon.hostStatus',
    )!;
    expect(statuses['installed'], {
      ...original,
      'iconUrl': 'https://repo.example/icon/installed.png',
    });
    expect(statuses['outdated'], {'versionName': '0.0', 'versionCode': 0});
    expect(statuses['invalid'], original);
    expect(statuses.containsKey('unknown'), isFalse);
    expect(
      (statuses['already'] as Map)['iconUrl'],
      'https://old.example/already.png',
    );
    expect(preferences.get<Map<dynamic, dynamic>>('mihon.installedPackages'), {
      'installed': '1.0',
      'outdated': '0.0',
    });
    expect(
      await installer.cacheRepositoryIcons([extension('installed')]),
      isEmpty,
    );
  });
}
