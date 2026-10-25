import 'package:media_kit/media_kit.dart';

/// Compressed playback packets only; decoders and surfaces use additional RAM.
/// These are transient per-player buffers, never durable download files.
const playbackForwardBufferBytes = 128 * 1024 * 1024;

/// A whole-episode horizon rather than a short time-based lookahead. The byte
/// budget remains authoritative, including for long/high-bitrate/live streams.
const desktopPlaybackBufferProperties = <String, String>{
  'cache': 'yes',
  // media_kit enables disk caching by default. In that mode mpv's byte limit
  // applies to packet metadata, not the append-only on-disk media payload.
  'cache-on-disk': 'no',
  'demuxer-max-bytes': '$playbackForwardBufferBytes',
  'demuxer-max-back-bytes': '0',
  'cache-secs': '2147483',
  'demuxer-readahead-secs': '2147483',
};

/// Apply before opening media so no packet payload is written to mpv's disk
/// cache. Awaiting the engine also avoids racing media_kit's default options.
Future<void> applyDesktopPlaybackBufferPolicy(NativePlayer player) async {
  await player.waitForPlayerInitialization;
  for (final entry in desktopPlaybackBufferProperties.entries) {
    await player.setProperty(entry.key, entry.value);
  }
}
