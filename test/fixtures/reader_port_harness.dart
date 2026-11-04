import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/jmcomic/jmcomic_image.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';

import '../jmcomic_client_test.dart' show encryptJmFixture;
import 'fake_preferences.dart';
import 'portable_rule_test_support.dart';
import 'test_database.dart';

const readerPortIds = ['picacomic', 'wnacg', 'jmcomic', 'ehentai'];

/// No public network: production factory, rules, TLS-shaped identities and image
/// byte processing, with synthetic metadata/geometric PNGs at the adapter seam.
class ReaderPortHarness {
  ReaderPortHarness._(this.database, this.container, this.http, this.adapter);
  final AppDatabase database;
  final ProviderContainer container;
  final DioSourceHttpClient http;
  final ReaderPortFixtureAdapter adapter;

  static Future<ReaderPortHarness> create() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    for (var y = 0; y < 420; y += 30) {
      canvas.drawRect(
        ui.Rect.fromLTWH(0, y.toDouble(), 300, 30),
        ui.Paint()..color = ui.Color(y.isEven ? 0xffd2ebe5 : 0xffefcb77),
      );
    }
    canvas.drawCircle(
      const ui.Offset(150, 210),
      85,
      ui.Paint()..color = const ui.Color(0xff1b655b),
    );
    canvas.drawRect(
      const ui.Rect.fromLTWH(120, 180, 60, 60),
      ui.Paint()..color = const ui.Color(0xffffd06f),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(300, 420);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final adapter = ReaderPortFixtureAdapter(png!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    final http = DioSourceHttpClient(
      dio: Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = adapter,
    );
    final database = openTestDatabase();
    final preferences = memoryPreferences();
    await preferences.set(
      'sources.seededBuiltins',
      SourceRegistry.builtinRuleAssets,
    );
    await preferences.set('app-update.automaticCheck', false);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        preferencesProvider.overrideWithValue(preferences),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        sourceHttpClientProvider.overrideWithValue(http),
        sourceJsRuntimeFactoryProvider.overrideWithValue(
          createSourceRuleRuntime,
        ),
      ],
    );
    final harness = ReaderPortHarness._(database, container, http, adapter);
    try {
      final registry = container.read(sourceRegistryProvider);
      for (final id in readerPortIds) {
        await registry.importFromText(
          await readSourceRuleAsset('assets/rules/$id-js.json'),
        );
      }
      await container.read(sourcesProvider.future);
      return harness;
    } catch (_) {
      await harness.close();
      rethrow;
    }
  }

  Future<JsSource> source(String id) async {
    final snapshot = await container.read(sourcesProvider.future);
    return snapshot.entries.singleWhere((e) => e.descriptor.id == id).source
        as JsSource;
  }

  MediaItem item(String id) => MediaItem(
    sourceId: id,
    remoteId: id == 'ehentai' ? '500000/aaaaaaaaaa' : '500000',
    title: 'Synthetic geometry - $id',
    type: MediaType.manga,
    url: switch (id) {
      'picacomic' => 'https://picaapi.picacomic.com/comics/500000',
      'wnacg' => 'https://www.wnacg.buzz/photos-index-aid-500000.html',
      'jmcomic' => 'https://18comic.vip/album/500000/',
      _ => 'https://e-hentai.org/g/500000/aaaaaaaaaa/',
    },
  );

  Future<void> close() async {
    container.dispose();
    http.close();
    await database.close();
  }
}

class ReaderPortFixtureAdapter implements HttpClientAdapter {
  ReaderPortFixtureAdapter(this.png);
  final Uint8List png;
  final _jmPngs = <String, Future<Uint8List>>{};
  bool offline = false;
  final requests = <RequestOptions>[];

  Future<Uint8List> _scrambledJmPng(String url) async {
    final rows = jmImageRows(url);
    final codec = await ui.instantiateImageCodec(png);
    final image = (await codec.getNextFrame()).image;
    try {
      final raw = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final pixels = raw.buffer.asUint8List(
        raw.offsetInBytes,
        raw.lengthInBytes,
      );
      final scrambled = Uint8List(pixels.length);
      final stride = image.width * 4;
      final step = image.height ~/ rows;
      final remainder = image.height % rows;
      // Invert the site permutation at the raw-byte boundary, not by calling
      // the production restore function. The reader must recover the geometry.
      for (var i = 0; i < rows; i++) {
        final length = step + (i == 0 ? remainder : 0);
        final originalY = step * i + (i == 0 ? 0 : remainder);
        final scrambledY = image.height - step * (i + 1) - remainder;
        scrambled.setRange(
          scrambledY * stride,
          (scrambledY + length) * stride,
          pixels,
          originalY * stride,
        );
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(scrambled);
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: image.width,
        height: image.height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final encodedCodec = await descriptor.instantiateCodec();
      final encodedImage = (await encodedCodec.getNextFrame()).image;
      try {
        final data = (await encodedImage.toByteData(
          format: ui.ImageByteFormat.png,
        ))!;
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        encodedImage.dispose();
        encodedCodec.dispose();
        descriptor.dispose();
        buffer.dispose();
      }
    } finally {
      image.dispose();
      codec.dispose();
    }
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (offline) throw StateError('Offline fixture: network is forbidden');
    requests.add(options);
    final uri = options.uri;
    ResponseBody text(String body, [int status = 200]) =>
        ResponseBody.fromString(body, status);
    ResponseBody json(Object data) =>
        text(jsonEncode({'code': 200, 'data': data}));
    if (uri.host == 'geometry.example.invalid' ||
        uri.host == 'geometry.hath.network') {
      if (uri.path.startsWith('/media/photos/')) {
        final bytes = await (_jmPngs[uri.path] ??= _scrambledJmPng(
          uri.toString(),
        ));
        return ResponseBody.fromBytes(bytes, 200);
      }
      return ResponseBody.fromBytes(png, 200);
    }
    if (uri.host == 'picaapi.picacomic.com') {
      if (uri.path == '/auth/sign-in') {
        return json({'token': 'synthetic-not-a-real-session'});
      }
      if (uri.path.endsWith('/pages')) {
        return json({
          'pages': {
            'page': 1,
            'pages': 1,
            'docs': [
              for (var i = 1; i <= 2; i++)
                {
                  'media': {
                    'fileServer': 'https://geometry.example.invalid',
                    'path': 'pica-$i.png',
                  },
                },
            ],
          },
        });
      }
      if (uri.path.endsWith('/eps')) {
        return json({
          'eps': {
            'page': 1,
            'pages': 1,
            'docs': [
              {'order': 1, 'title': 'Synthetic geometry episode'},
            ],
          },
        });
      }
      if (uri.path == '/comics/500000') {
        return json({
          'comic': {
            '_id': '500000',
            'title': 'Synthetic geometry - picacomic',
            'thumb': {
              'fileServer': 'https://geometry.example.invalid',
              'path': 'cover.png',
            },
          },
        });
      }
    }
    if (uri.host == 'www.wnacg.buzz') {
      if (uri.path.startsWith('/photos-gallery')) {
        return text(
          '<script>document.writeln(${jsonEncode('var imglist=[{url:fast_img_host+"//geometry.example.invalid/wn-1.png",caption:"[0001]"},{url:fast_img_host+"//geometry.example.invalid/wn-2.png",caption:"[0002]"}];')});</script>',
        );
      }
      if (uri.path.startsWith('/photos-index')) {
        return text(
          '<h2>Synthetic geometry - wnacg</h2><div class="uwthumb">'
          '<img src="https://geometry.example.invalid/cover.png"></div>',
        );
      }
    }
    if (uri.host == 'rup4a04-c02.tos-cn-hongkong.bytepluses.com') {
      return text('', 404);
    }
    if (uri.host == 'www.cdnhjk.net') {
      final timestamp = (options.headers['Tokenparam'] as String)
          .split(',')
          .first;
      final data = uri.path == '/album'
          ? <String, Object?>{
              'id': 500000,
              'name': 'Synthetic geometry - jmcomic',
              'author': <String>[],
              'series_id': '0',
              'series': <Object>[],
            }
          : uri.path == '/comic_read'
          ? <String, Object?>{
              'images': [
                for (var i = 1; i <= 2; i++)
                  {
                    'image':
                        'https://geometry.example.invalid/media/photos/500000/0000$i.png',
                  },
              ],
            }
          : throw StateError('Unexpected JM fixture path');
      return json(encryptJmFixture(data, '${timestamp}185Hcomic3PAPP7R'));
    }
    if (uri.host == 'e-hentai.org') {
      if (uri.path.startsWith('/s/')) {
        return text(
          '<img id="img" src="https://geometry.hath.network:4443/h/eh-${uri.pathSegments.last}.png">',
        );
      }
      if (uri.path == '/g/500000/aaaaaaaaaa/') {
        return text(
          '''
        <h1 id="gn">Synthetic geometry - ehentai</h1>
        <table id="gdd"><tr><td class="gdt1">Length:</td><td class="gdt2">2 pages</td></tr></table>
        <div id="gdt"><a href="https://e-hentai.org/s/aaaa/500000-1"><img alt="1"></a>
        <a href="https://e-hentai.org/s/bbbb/500000-2"><img alt="2"></a></div>''',
        );
      }
    }
    throw StateError('No fixture response for ${uri.host}${uri.path}');
  }

  @override
  void close({bool force = false}) {}
}
