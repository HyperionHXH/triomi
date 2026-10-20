import '../../../core/storage/preferences.dart';

enum VideoAspectRatio {
  original('原始比例', null),
  ratio16x9('16:9', 16 / 9),
  ratio4x3('4:3', 4 / 3),
  ratio16x10('16:10', 16 / 10),
  ratio21x9('21:9', 21 / 9),
  ratio1x1('1:1', 1);

  const VideoAspectRatio(this.label, this.ratio);
  final String label;
  final double? ratio;
}

class PlayerSettings {
  const PlayerSettings({
    this.speed = 1,
    this.holdSpeed = 2,
    this.autoNext = true,
    this.aspectRatio = VideoAspectRatio.original,
    this.backgroundAudio = false,
    this.volume = 1,
    this.skipSeconds = 80,
  });
  final double speed, holdSpeed, volume;
  final bool autoNext, backgroundAudio;
  final VideoAspectRatio aspectRatio;
  final int skipSeconds;
  static const key = 'player.controls';
  static PlayerSettings load(Preferences preferences) {
    final raw = preferences.get<Map<dynamic, dynamic>>(key) ?? const {};
    double number(String key, double fallback, double min, double max) {
      final value = raw[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    return PlayerSettings(
      speed: number('speed', 1, .5, 3),
      holdSpeed: number('holdSpeed', 2, 1, 3),
      volume: number('volume', 1, 0, 1),
      skipSeconds: number('skipSeconds', 80, 1, 3600).round(),
      autoNext: raw['autoNext'] != false,
      backgroundAudio: raw['backgroundAudio'] == true,
      aspectRatio: VideoAspectRatio.values
          .where((value) => value.name == raw['aspectRatio'])
          .firstOrNull ?? VideoAspectRatio.original,
    );
  }

  PlayerSettings copyWith({
    double? speed,
    double? holdSpeed,
    double? volume,
    bool? autoNext,
    bool? backgroundAudio,
    VideoAspectRatio? aspectRatio,
    int? skipSeconds,
  }) => PlayerSettings(
    speed: speed ?? this.speed,
    holdSpeed: holdSpeed ?? this.holdSpeed,
    volume: volume ?? this.volume,
    autoNext: autoNext ?? this.autoNext,
    backgroundAudio: backgroundAudio ?? this.backgroundAudio,
    aspectRatio: aspectRatio ?? this.aspectRatio,
    skipSeconds: skipSeconds ?? this.skipSeconds,
  );
  Future<void> save(Preferences preferences) => preferences.set(key, {
    'speed': speed,
    'holdSpeed': holdSpeed,
    'volume': volume,
    'autoNext': autoNext,
    'backgroundAudio': backgroundAudio,
    'aspectRatio': aspectRatio.name,
    'skipSeconds': skipSeconds,
  });
}
