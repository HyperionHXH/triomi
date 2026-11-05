import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/settings/onboarding_controller.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  test('new installation remains eligible until completion, then never replays on restart', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final preferences = memoryPreferences();
    await initializeOnboarding(preferences, database);
    final first = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
    );
    expect(first.read(onboardingProvider), isTrue);
    first.dispose();
    // An interrupted first run is still a first run; an update is not.
    await initializeOnboarding(preferences, database);
    final resumed = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
    );
    expect(resumed.read(onboardingProvider), isTrue);
    await resumed.read(onboardingProvider.notifier).complete();
    expect(resumed.read(onboardingProvider), isFalse);
    resumed.dispose();
    await initializeOnboarding(preferences, database);
    final restarted = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
    );
    expect(restarted.read(onboardingProvider), isFalse);
    restarted.dispose();
  });

  test('existing settings identify an upgrade and remain unchanged', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final preferences = memoryPreferences();
    await preferences.set('appearance.accent', 'violet');
    await initializeOnboarding(preferences, database);
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);
    expect(container.read(onboardingProvider), isFalse);
    expect(preferences.get<String>('appearance.accent'), 'violet');
  });

  test('existing business records suppress first-run setup even with an empty preference store', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    const manga = MediaItem(
      sourceId: 'test-source',
      remoteId: 'retained-work',
      type: MediaType.manga,
      title: 'Retained manga',
    );
    final library = LibraryRepository(database);
    await library.addToLibrary(manga);
    final preferences = memoryPreferences();
    await initializeOnboarding(preferences, database);
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);
    expect(container.read(onboardingProvider), isFalse);
    expect(await library.isInLibrary(manga.sourceId, manga.remoteId), isTrue);
  });
}
