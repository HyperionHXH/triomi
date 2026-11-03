import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/jmcomic/jmcomic_image.dart';

import 'fixtures/portable_rule_test_support.dart';

Future<Uint8List> _rowFixture(int width, int height) async {
  final bytes = Uint8List.fromList([
    for (var y = 0; y < height; y++)
      for (var x = 0; x < width; x++) ...[y, x, 127, 255],
  ]);
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final image = (await codec.getNextFrame()).image;
  try {
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

Future<Uint8List> _pixels(List<int> bytes) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
  final image = (await codec.getNextFrame()).image;
  try {
    final pixels = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    return pixels.buffer.asUint8List(
      pixels.offsetInBytes,
      pixels.lengthInBytes,
    );
  } finally {
    image.dispose();
    codec.dispose();
  }
}

class _ByteAdapter implements HttpClientAdapter {
  _ByteAdapter(this.bytes);
  final List<int> bytes;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(bytes, 200);
  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sourceRuleTest(
    'JM image strip counts match Python MD5 vectors at every protocol boundary',
    () {
      for (final entry in [
        (220979, 0),
        (220980, 10),
        (268849, 10),
        (268850, 6),
        (421925, 18),
        (421926, 14),
        (500000, 12),
      ]) {
        expect(
          jmImageRows(
            'https://cdn.example.invalid/media/photos/${entry.$1}/00001.jpg',
          ),
          entry.$2,
        );
      }
      expect(
        jmImageRows('https://cdn.example.invalid/media/albums/500000_3x4.jpg'),
        0,
      );
      expect(
        jmImageRows(
          'https://cdn.example.invalid/media/photos/500000/500000_3x4.jpg',
        ),
        0,
      );
    },
  );

  for (final pair in [(220980, 23), (500000, 29), (421926, 28)]) {
    sourceRuleTest(
      'JM restores every RGBA pixel, including remainder rows: chapter ${pair.$1}, height ${pair.$2}',
      () async {
        const width = 3;
        final height = pair.$2;
        final url =
            'https://cdn.example.invalid/media/photos/${pair.$1}/00001.jpg';
        final rows = jmImageRows(url), chunk = height ~/ rows;
        final chunks = [
          for (var i = 0; i < rows; i++)
            [
              for (
                var y = i * chunk;
                y < (i == rows - 1 ? height : (i + 1) * chunk);
                y++
              )
                y,
            ],
        ];
        final expectedRows = chunks.reversed.expand((x) => x).toList();
        final result = await restoreJmImage(
          url,
          await _rowFixture(width, height),
        );
        expect(result.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        expect(await _pixels(result), [
          for (final y in expectedRows)
            for (var x = 0; x < width; x++) ...[y, x, 127, 255],
        ]);
      },
    );
  }

  sourceRuleTest('JM covers, legacy chapters and GIF animation bytes remain byte-for-byte unchanged', () async {
    final png = await _rowFixture(3, 23);
    for (final url in [
      'https://cdn.example.invalid/media/photos/220979/00001.jpg',
      'https://cdn.example.invalid/media/albums/500000_3x4.jpg',
    ]) {
      expect(identical(await restoreJmImage(url, png), png), true);
    }
    final gif = base64Decode(
      'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
    );
    expect(
      identical(
        await restoreJmImage(
          'https://cdn.example.invalid/media/photos/500000/00001.gif',
          gif,
        ),
        gif,
      ),
      true,
    );
  });

  sourceRuleTest(
    'JM corrupt files fail rather than returning scrambled placeholders',
    () async {
      await expectLater(
        restoreJmImage(
          'https://cdn.example.invalid/media/photos/500000/00001.jpg',
          [1, 2, 3],
        ),
        throwsA(anything),
      );
      await expectLater(
        restoreJmImage(
          'https://cdn.example.invalid/media/photos/500000/00001.jpg',
          await _rowFixture(2, 2),
        ),
        throwsFormatException,
      );
    },
  );

  sourceRuleTest('JM production HTTP byte path restores reader/download/save bytes, other sources remain untouched', () async {
    const url = 'https://cdn.example.invalid/media/photos/220980/00001.jpg';
    final original = await _rowFixture(3, 23);
    final http = DioSourceHttpClient(
      dio: Dio()..httpClientAdapter = _ByteAdapter(original),
    );
    addTearDown(http.close);
    final restored = await http.fetchBytes(url, sourceId: 'jmcomic');
    expect(
      await _pixels(restored),
      await _pixels(await restoreJmImage(url, original)),
    );
    expect(restored, isNot(orderedEquals(original)));
    expect(
      await http.fetchBytes(url, sourceId: 'copymanga'),
      orderedEquals(original),
    );
    expect(
      await http.fetchBytes(url, sourceId: 'wnacg'),
      orderedEquals(original),
    );
  });
}
