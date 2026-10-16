import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'preferences.dart';

const incognitoPreferenceKey = 'privacy.incognito';

/// Incognito suppresses new reading/playback progress and automatic remote
/// progress reports; it is not a cache purge, network anonymity or app lock.
final incognitoProvider = StreamProvider<bool>((ref) {
  final prefs = ref.watch(preferencesProvider);
  return prefs
      .watch(incognitoPreferenceKey)
      .map((_) => prefs.get<bool>(incognitoPreferenceKey) ?? false);
});
