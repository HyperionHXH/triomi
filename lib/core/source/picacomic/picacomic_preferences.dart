import '../../storage/preferences.dart';

const picaQualities = ['original', 'low', 'medium', 'high'];
const picaSorts = ['dd', 'da', 'ld', 'vd'];

/// Non-secret settings only. Account state belongs exclusively to SecureStore.
class PicacomicPreferences {
  PicacomicPreferences(this.preferences);
  final Preferences preferences;

  String get quality {
    final value = preferences.get<Object?>('picacomic.quality');
    return picaQualities.contains(value) ? value as String : 'original';
  }

  String get sort {
    final value = preferences.get<Object?>('picacomic.sort');
    return picaSorts.contains(value) ? value as String : 'dd';
  }

  String get blocked => preferences.get<String>('picacomic.blocked') ?? '';

  Map<String, Object?> get requestOptions => {
    'sort': sort,
    'blocked': blocked
        .split(RegExp('[,，]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(),
  };

  Future<void> set(String key, String value) async {
    if (key == 'quality' && !picaQualities.contains(value) ||
        key == 'sort' && !picaSorts.contains(value) ||
        !const ['quality', 'sort', 'blocked'].contains(key) ||
        value.length > 2000) {
      throw ArgumentError('哔咔设置无效');
    }
    await preferences.set('picacomic.$key', value);
  }
}
