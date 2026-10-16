import '../../../core/storage/preferences.dart';

/// Import the former shared shelf choices once; never replace module choices.
Future<void> migrateLibraryPreferences(Preferences preferences) async {
  if (preferences.get<bool>('library.scopedPreferencesMigrated') == true) {
    return;
  }
  final sort = preferences.get<Object?>('library.sort');
  final layout =
      preferences.get<Object?>('library.layout') ??
      preferences.get<Object?>('appearance.coverLayout');
  for (final module in ['manga', 'novel']) {
    if (preferences.get<Object?>('library.$module.sort') == null &&
        sort != null) {
      await preferences.set('library.$module.sort', sort);
    }
    if (preferences.get<Object?>('library.$module.layout') == null &&
        layout != null) {
      await preferences.set('library.$module.layout', layout);
    }
  }
  await preferences.set('library.scopedPreferencesMigrated', true);
}
