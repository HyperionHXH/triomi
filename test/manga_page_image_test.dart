import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/reader/manga_page_image.dart';
import 'package:triomi/features/reader/reader_settings.dart';
import 'package:triomi/features/reader/reader_work_settings.dart';

class _ControlledImage extends ImageProvider<_ControlledImage> {
  final image = Completer<ImageInfo>();

  @override
  Future<_ControlledImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _ControlledImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(image.future);
}

class _RetryImage extends ImageProvider<_RetryImage> {
  final first = Completer<ImageInfo>();
  final second = Completer<ImageInfo>();
  int loads = 0;

  @override
  Future<_RetryImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _RetryImage key,
    ImageDecoderCallback decode,
  ) =>
      OneFrameImageStreamCompleter(++loads == 1 ? first.future : second.future);
}

void main() {
  Widget page(ImageProvider provider) => MaterialApp(
    home: SingleChildScrollView(
      child: SizedBox(
        width: 300,
        child: MangaPageImage(
          provider: provider,
          url: 'https://example.test/page.png',
          sourceId: 'reader-test',
          fit: BoxFit.fitWidth,
          settings: const MangaViewSettings(base: ReaderSettings()),
        ),
      ),
    ),
  );

  testWidgets(
    'webtoon pending and failed pages reserve a readable scroll extent',
    (tester) async {
      final provider = _ControlledImage();
      await tester.pumpWidget(page(provider));
      final pendingHeight = tester.getSize(find.byType(MangaPageImage)).height;
      expect(pendingHeight, greaterThan(300));
      provider.image.completeError(StateError('page unavailable'));
      await tester.pump();
      expect(find.text('重新加载'), findsOneWidget);
      expect(tester.getSize(find.byType(MangaPageImage)).height, pendingHeight);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a replacement provider does not inherit the prior page failure',
    (tester) async {
      final failed = _ControlledImage();
      await tester.pumpWidget(page(failed));
      failed.image.completeError(StateError('old page unavailable'));
      await tester.pump();
      expect(find.text('重新加载'), findsOneWidget);
      final pending = _ControlledImage();
      await tester.pumpWidget(page(pending));
      expect(find.text('重新加载'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 10, 20),
        Paint()..color = Colors.white,
      );
      final picture = recorder.endRecording();
      final image = picture.toImageSync(10, 20);
      picture.dispose();
      pending.image.complete(ImageInfo(image: image));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'same resized provider retries its failed load and renders the next image',
    (tester) async {
      final source = _RetryImage();
      final resized = ResizeImage(
        source,
        width: 100,
        height: 100,
        policy: ResizeImagePolicy.fit,
      );
      await tester.pumpWidget(page(resized));
      expect(source.loads, 1);
      source.first.completeError(StateError('temporary page failure'));
      await tester.pump();
      expect(find.text('重新加载'), findsOneWidget);
      await tester.ensureVisible(find.text('重新加载'));
      await tester.pump();
      expect(find.text('重新加载').hitTestable(), findsOneWidget);
      await tester.tap(find.text('重新加载'));
      await tester.pump();
      expect(
        source.loads,
        2,
        reason: 'retry evicts the same ResizeImage cache identity',
      );
      expect(find.text('重新加载'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 10, 20),
        Paint()..color = Colors.white,
      );
      final picture = recorder.endRecording();
      final image = picture.toImageSync(10, 20);
      picture.dispose();
      source.second.complete(ImageInfo(image: image));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('重新加载'), findsNothing);
      expect(source.loads, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
