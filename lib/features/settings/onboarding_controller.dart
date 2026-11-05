import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import '../../core/storage/preferences.dart';

/// Device-local startup state; an upgrade must never replay first-install setup.
const onboardingStateKey = 'setup.onboarding.state';
const _pending = 'pending';
const _complete = 'complete';

/// Call before startup maintenance writes any settings. A pre-existing setting
/// or business record identifies an upgrade, even if the other store is empty.
Future<void> initializeOnboarding(
  Preferences preferences,
  AppDatabase database,
) async {
  if (preferences.get<String>(onboardingStateKey) != null) return;
  var existing = preferences.exportAll().isNotEmpty;
  if (!existing) {
    final rows = await database.customSelect('''
      SELECT EXISTS(SELECT 1 FROM sources)
          OR EXISTS(SELECT 1 FROM media_items)
          OR EXISTS(SELECT 1 FROM chapters)
          OR EXISTS(SELECT 1 FROM library_entries)
          OR EXISTS(SELECT 1 FROM histories)
          OR EXISTS(SELECT 1 FROM downloads)
          OR EXISTS(SELECT 1 FROM track_binds) AS existing
    ''').getSingle();
    existing = rows.read<int>('existing') != 0;
  }
  await preferences.set(onboardingStateKey, existing ? _complete : _pending);
  await preferences.flush();
}

class OnboardingController extends Notifier<bool> {
  @override
  bool build() =>
      ref.watch(preferencesProvider).get<String>(onboardingStateKey) ==
      _pending;

  Future<void> complete() async {
    final preferences = ref.read(preferencesProvider);
    await preferences.set(onboardingStateKey, _complete);
    await preferences.flush();
    state = false;
  }
}

final onboardingProvider = NotifierProvider<OnboardingController, bool>(
  OnboardingController.new,
);
