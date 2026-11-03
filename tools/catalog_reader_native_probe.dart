// Offline catalog-byte installation through the current production factory.
// Requires the sibling catalog checkout; no real accounts or upstream traffic.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/catalog_installer.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/jmcomic/jmcomic_js_source.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/picacomic/picacomic_js_source.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_catalog.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/widgets/image_viewer.dart';

import '../test/fixtures/fake_http_client.dart';
import '../test/fixtures/portable_rule_test_support.dart';
import '../test/fixtures/reader_port_harness.dart';

Future<List<int>> pixels(List<int> bytes) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
  final image = (await codec.getNextFrame()).image;
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    codec.dispose();
  }
}

void main() {
  final public = Platform.environment['TRIOMI_PUBLIC_CATALOG'] == '1';
  // Construct before flutter_test's offline HTTP override. Opt-in downloads
  // access only GitHub; all account/site/image traffic stays synthetic.
  final network = public ? HttpClient() : null;
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDownAll(() => network?.close(force: true));
  final checkout = Directory(
    Platform.environment['TRIOMI_CATALOG_CHECKOUT'] ??
        '../Mihon-Extensions-ios',
  );
  for (final id in readerPortIds) {
    sourceRuleTest(
      'Catalog $id installs and reads through native factory',
      () async {
        final harness = await ReaderPortHarness.create();
        addTearDown(harness.close);
        final registry = harness.container.read(sourceRegistryProvider);
        await registry.remove(id);
        late SourceCatalogEntry entry;
        final SourceHttpClient download = public
            ? DioSourceHttpClient(
                dio: Dio(BaseOptions(validateStatus: (_) => true))
                  ..httpClientAdapter = IOHttpClientAdapter(
                    createHttpClient: () => network!,
                  ),
              )
            : FakeHttpClient((request) async {
                expect(request.url, entry.url);
                return SourceResponse(
                  statusCode: 200,
                  url: request.url,
                  body: await File(
                    '${checkout.path}/repo/triomi/rules/$id.json',
                  ).readAsString(),
                );
              });
        final entries = SourceCatalogIndex.parse(
          public
              ? (await download.send(
                  const SourceRequest(
                    url: 'https://raw.githubusercontent.com/HyperionHXH/Mihon-Extensions/main/repo/triomi/index.json',
                  ),
                  sourceId: id,
                )).body
              : await File('${checkout.path}/repo/triomi/index.json')
                    .readAsString(),
        );
        entry = entries.singleWhere((e) => e.id == id);
        // The installer always validates exports with generic JS. Only the real
        // registry factory supplies native gateways when the installed rule loads.
        final installerRegistry = SourceRegistry(
          repository: registry.repository,
          http: download,
          jsRuntimeFactory: createSourceRuleRuntime,
        );
        addTearDown(installerRegistry.dispose);
        await CatalogInstaller(installerRegistry).install(entry);
        final snapshot = await registry.load();
        expect(snapshot.failures, isEmpty);
        final source =
            snapshot.entries.singleWhere((e) => e.descriptor.id == id).source
                as JsSource;
        if (id == 'jmcomic' || id == 'picacomic') {
          expect(source.descriptor.name, contains('需原生网关宿主'));
        }
        if (id == 'picacomic') {
          expect(source, isA<PicacomicJsSource>());
          final account = source as AccountProvider;
          expect(account.isLoggedIn, false);
          await expectLater(source.detail(harness.item(id)), throwsA(anything));
          expect(
            harness.adapter.requests.where(
              (r) => r.uri.host == 'picaapi.picacomic.com',
            ),
            isEmpty,
          );
          await account.login('fixture', 'fixture');
        } else if (id == 'jmcomic') {
          expect(source, isA<JmcomicJsSource>());
        }
        final item = await source.detail(harness.item(id));
        final chapters = await source.chapters(item);
        expect(chapters, hasLength(1));
        final content = await source.content(chapters.single);
        expect(content.images, hasLength(2));
        final image = await loadImageBytes(
          content.images.first,
          sourceId: id,
          headers: content.imageHeaders,
          http: harness.http,
        );
        expect(await pixels(image!), await pixels(harness.adapter.png));
      },
    );
  }
}
