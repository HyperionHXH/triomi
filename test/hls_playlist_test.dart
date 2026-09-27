import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/features/downloads/data/hls_playlist.dart';

void main() {
  final base = Uri.parse('https://cdn.example.com/hls/index.m3u8?token=abc');

  group('HLS 播放列表解析', () {
    test('媒体列表：分段按顺序解析，相对地址按列表地址补全', () {
      final playlist = HlsPlaylist.parse('''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:9.9,
seg-1.ts
#EXTINF:9.9,
sub/seg-2.ts
#EXTINF:9.9,
/abs/seg-3.ts
''', base);

      expect(playlist.isMaster, isFalse);
      expect(playlist.encrypted, isFalse);
      expect(playlist.segments.map((uri) => uri.toString()), <String>[
        'https://cdn.example.com/hls/seg-1.ts',
        'https://cdn.example.com/hls/sub/seg-2.ts',
        'https://cdn.example.com/abs/seg-3.ts',
      ]);
    });

    test('主列表：取最高带宽变体（相对地址）', () {
      final playlist = HlsPlaylist.parse('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
high/index.m3u8
''', base);

      expect(playlist.isMaster, isTrue);
      expect(playlist.variants, hasLength(2));
      expect(
        playlist.bestVariant.toString(),
        'https://cdn.example.com/hls/high/index.m3u8',
      );
    });

    test('主列表没声明带宽时取第一个', () {
      final playlist = HlsPlaylist.parse('''
#EXTM3U
#EXT-X-STREAM-INF:RESOLUTION=640x360
a.m3u8
#EXT-X-STREAM-INF:RESOLUTION=1280x720
b.m3u8
''', base);

      expect(playlist.bestVariant.toString(), contains('a.m3u8'));
    });

    test('fMP4：EXT-X-MAP 作为初始化段，落盘扩展名应为 mp4', () {
      final playlist = HlsPlaylist.parse('''
#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXTINF:6,
s1.m4s
#EXTINF:6,
s2.m4s
''', base);

      expect(playlist.isFragmentedMp4, isTrue);
      expect(
        playlist.initSegment.toString(),
        'https://cdn.example.com/hls/init.mp4',
      );
      expect(playlist.segments, hasLength(2));
    });

    test('加密流：METHOD 非 NONE 标记为加密（含 SAMPLE-AES）', () {
      final aes = HlsPlaylist.parse('''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x1
#EXTINF:6,
s1.ts
''', base);
      expect(aes.encrypted, isTrue);

      final sampleAes = HlsPlaylist.parse('''
#EXTM3U
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x"
#EXTINF:6,
s1.m4s
''', base);
      expect(sampleAes.encrypted, isTrue);

      final plain = HlsPlaylist.parse('''
#EXTM3U
#EXT-X-KEY:METHOD=NONE
#EXTINF:6,
s1.ts
''', base);
      expect(plain.encrypted, isFalse);
    });

    test('不是 m3u8 / 没有分段：报解析错误', () {
      expect(HlsPlaylist.looksLikeHls('#EXTM3U\nx.ts'), isTrue);
      expect(HlsPlaylist.looksLikeHls('<html></html>'), isFalse);

      expect(
        () => HlsPlaylist.parse('<html>403</html>', base),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.parse,
          ),
        ),
      );
      expect(
        () => HlsPlaylist.parse('#EXTM3U\n#EXT-X-VERSION:3', base),
        throwsA(
          isA<SourceException>().having(
            (error) => error.message,
            'message',
            contains('没有分段'),
          ),
        ),
      );
    });
  });
}
