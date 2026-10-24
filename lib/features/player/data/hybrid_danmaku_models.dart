/// Read-only providers selected for Triomi; no dandanplay app credentials.
enum DanmakuProviderKind { bilibili, animeko, gamer }

/// Timeline time is always seconds, color is RGB, modes are 1/4/5.
class DanmakuComment {
  const DanmakuComment({
    required this.time,
    required this.text,
    this.mode = 1,
    this.color = 0xFFFFFF,
    this.user = '',
  });
  final double time;
  final String text;
  final int mode;
  final int color;
  final String user;
}

/// A verified upstream episode, not a playback-site episode identifier.
class DanmakuEpisodeChoice {
  const DanmakuEpisodeChoice({
    required this.provider,
    required this.id,
    required this.title,
    this.number,
    this.special = false,
    this.cid,
    this.aid,
    this.durationMs,
  });
  final DanmakuProviderKind provider;
  final String id;
  final String title;
  final double? number;
  final bool special;
  final int? cid;
  final int? aid;
  final int? durationMs;
}
