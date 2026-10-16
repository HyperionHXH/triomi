import '../../../core/storage/preferences.dart';

class PlayerSettings {
  const PlayerSettings({
    this.speed = 1,
    this.holdSpeed = 2,
    this.autoNext = true,
    this.fit = 'contain',
    this.backgroundAudio = false,
    this.volume = 1,
  });
  final double speed, holdSpeed, volume;
  final bool autoNext, backgroundAudio;
  final String fit;
  static const key = 'player.controls';
  static PlayerSettings load(Preferences preferences) {
    final raw = preferences.get<Map<dynamic, dynamic>>(key) ?? const {};
    double number(String key, double fallback, double min, double max) {
      final value = raw[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    final fit = raw['fit'];
    return PlayerSettings(
      speed: number('speed', 1, .5, 3),
      holdSpeed: number('holdSpeed', 2, 1, 3),
      volume: number('volume', 1, 0, 1),
      autoNext: raw['autoNext'] != false,
      backgroundAudio: raw['backgroundAudio'] == true,
      fit: const ['contain', 'cover', 'fill'].contains(fit)
          ? fit as String
          : 'contain',
    );
  }

  PlayerSettings copyWith({
    double? speed,
    double? holdSpeed,
    double? volume,
    bool? autoNext,
    bool? backgroundAudio,
    String? fit,
  }) => PlayerSettings(
    speed: speed ?? this.speed,
    holdSpeed: holdSpeed ?? this.holdSpeed,
    volume: volume ?? this.volume,
    autoNext: autoNext ?? this.autoNext,
    backgroundAudio: backgroundAudio ?? this.backgroundAudio,
    fit: fit ?? this.fit,
  );
  Future<void> save(Preferences preferences) => preferences.set(key, {
    'speed': speed,
    'holdSpeed': holdSpeed,
    'volume': volume,
    'autoNext': autoNext,
    'backgroundAudio': backgroundAudio,
    'fit': fit,
  });
}
