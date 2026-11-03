import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../storage/preferences.dart';
import '../source_providers.dart';
import 'copymanga_preferences.dart';
import 'copymanga_user_agent.dart';

/// Public-image policy only: no registry, account, secure store or cookie jar.
/// Retaining the resolver shares its bounded UA pool across covers and settings
/// changes, while all requests reuse the application's existing connection pool.
final copyMangaCoverUserAgentProvider = Provider<CopyMangaUserAgent>((ref) {
  return CopyMangaUserAgent(
    CopyMangaPreferences(ref.watch(preferencesProvider)),
    ref.watch(sourceHttpClientProvider),
  );
});

final _copyMangaCoverSettingProvider = StreamProvider.autoDispose<Object?>(
  (ref) => ref.watch(preferencesProvider)
      .watch('${copyMangaPreferencePrefix}userAgent')
      .distinct(),
);

/// Resolve outside widget builds, and refresh mounted covers when host settings
/// change. Empty UA explicitly suppresses the host default; `app` yields no
/// override. Only UA can enter these public requests, never account headers.
final copyMangaCoverHeadersProvider =
    FutureProvider.autoDispose<Map<String, String>>((ref) async {
  final resolver = ref.watch(copyMangaCoverUserAgentProvider);
  // Watch every setting event, not just the first stream result. FutureProvider
  // discards superseded resolutions, so a pending desktop/mobile pool download
  // cannot delay or overwrite a later custom/app/none selection.
  ref.watch(_copyMangaCoverSettingProvider);
  await ref.watch(_copyMangaCoverSettingProvider.future);
  final headers = await resolver.headers(const {});
  return Map<String, String>.unmodifiable(headers);
});
