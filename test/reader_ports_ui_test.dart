import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/picacomic/picacomic_js_source.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/features/reader/manga_page_image.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';
import 'package:triomi/features/sources/picacomic_settings_sheet.dart';

import 'fixtures/reader_port_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Four reader ports production UI with synthetic geometric content',
    (tester) async {
      final harness = (await tester.runAsync(ReaderPortHarness.create))!;
      final client = HttpClient();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 400));
        client.close(force: true);
        await tester.runAsync(harness.close);
      });
      Future<void> until(bool Function() ready, String reason) async {
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        while (!ready() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
        expect(ready(), true, reason: reason);
        expect(tester.takeException(), isNull, reason: reason);
      }

      Future<void> capture(String name, String description) async {
        await tester.pump(const Duration(milliseconds: 350));
        expect(tester.takeException(), isNull);
        const raw = String.fromEnvironment('TRIOMI_READER_PORT_CAPTURE_URL');
        if (raw.isEmpty) return; // Desktop contract has no native screenshots.
        final base = Uri.parse(raw);
        expect(base.host, '127.0.0.1');
        await tester.runAsync(() async {
          final request = await client.postUrl(base.resolve('/__tour/capture'));
          final body = utf8.encode(
            jsonEncode({
              'name': name,
              'route': '/reader-ports/fixture',
              'description': description,
            }),
          );
          request.headers.contentType = ContentType.json;
          request.contentLength = body.length;
          request.add(body);
          final response = await request.close().timeout(
            const Duration(seconds: 50),
          );
          await response.drain<void>();
          expect(response.statusCode, 200);
        });
      }

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: harness.container,
          child: const TriomiApp(),
        ),
      );
      final router = harness.container.read(routerProvider);
      router.go('${AppRoutes.sources}?type=manga');
      await until(
        () => find.text('哔咔漫画').evaluate().isNotEmpty,
        'Installed source list',
      );
      await capture(
        '01_reader_ports_sources.png',
        'Actual production source management; four installed NSFW rules, no live content',
      );

      final pica =
          (await tester.runAsync(() => harness.source('picacomic')))!
              as PicacomicJsSource;
      final context = tester.element(find.text('哔咔漫画').first);
      unawaited(showPicacomicSettingsSheet(context, pica));
      await until(
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
        'Pica settings dialog',
      );
      await capture(
        '02_pica_settings.png',
        'Production non-secret settings with required-account disclosure',
      );
      await tester.enterText(
        find.byType(TextField).last,
        'synthetic-fixture-filter',
      );
      final save = find.widgetWithText(FilledButton, '保存');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await until(
        () => find.byType(AlertDialog).evaluate().isEmpty,
        'Settings save and exit animation',
      );
      expect(pica.settings.blocked, 'synthetic-fixture-filter');
      expect(pica.isLoggedIn, false);

      for (final id in readerPortIds) {
        final source = (await tester.runAsync(() => harness.source(id)))!;
        if (source is AccountProvider) {
          // Only the synthetic adapter sees these fixture strings. No real account.
          await tester.runAsync(
            () => (source as AccountProvider).login('fixture', 'fixture'),
          );
        }
        final item = (await tester.runAsync(
          () => source.detail(harness.item(id)),
        ))!;
        final chapters = (await tester.runAsync(() => source.chapters(item)))!;
        expect(chapters, hasLength(1));
        unawaited(
          router.push<void>(
            AppRoutes.reader,
            extra: MangaReaderArgs(
              item: item,
              chapters: chapters,
              initialIndex: 0,
            ),
          ),
        );
        await until(
          () => find
              .descendant(
                of: find.byType(MangaPageImage),
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is CustomPaint &&
                      widget.painter.runtimeType.toString() == '_PagePainter',
                ),
              )
              .evaluate()
              .isNotEmpty,
          'Production $id decoded image painter',
        );
        if (find.text(item.title).evaluate().isEmpty) {
          await tester.tapAt(tester.getCenter(find.byType(MangaReaderPage)));
          await tester.pump(const Duration(milliseconds: 300));
        }
        await until(
          () => find.text(item.title).evaluate().isNotEmpty,
          '$id reader toolbar title',
        );
        final index = readerPortIds.indexOf(id) + 3;
        await capture(
          '0${index}_${id}_reader.png',
          'Synthetic geometry through actual $id rule, byte host and production reader; NOT live upstream acceptance',
        );
        router.pop();
        await until(
          () => find.byType(MangaReaderPage).evaluate().isEmpty,
          '$id reader return',
        );
      }
      expect(harness.adapter.requests, isNotEmpty);
      expect(
        harness.adapter.requests.every(
          (request) => request.uri.scheme == 'https',
        ),
        true,
      );
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
