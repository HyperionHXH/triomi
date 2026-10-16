import '../storage/preferences.dart';
import 'source_catalog.dart';

/// MangaDex 1.0.4 added the optional third content argument.
const mangaDexDataSaverKey = 'sources.mangadex.dataSaver';

bool supportsMangaDexDataSaver(String id, String? version) {
  final parsed = CatalogVersion.tryParse(version ?? '');
  return id == 'mangadex' &&
      parsed != null &&
      parsed.compareTo(const CatalogVersion(1, 0, 4)) >= 0;
}

Map<String, Object?> mangaDexContentOptions(Preferences preferences) => {
  'dataSaver': preferences.get<bool>(mangaDexDataSaverKey) ?? false,
};
