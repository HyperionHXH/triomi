import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/reader/manga_page_image.dart';
import 'package:triomi/features/reader/reader_settings.dart';
import 'package:triomi/features/reader/reader_work_settings.dart';

class _ImageStream extends ImageStreamCompleter {
  void image(ui.Image image) => setImage(ImageInfo(image: image));

  void fail() => reportError(
    exception: StateError('Isolated decode failure'),
    stack: StackTrace.current,
  );
}

class _ControlledImage extends ImageProvider<_ControlledImage> {
  final streams = <_ImageStream>[];

  @override
  Future<_ControlledImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _ControlledImage key,
    ImageDecoderCallback decode,
  ) {
    final stream = _ImageStream();
    streams.add(stream);
    return stream;
  }
}

void main() {
  testWidgets('webtoon pending and error tiles retain page geometry on retry', (
    tester,
  ) async {
    final provider = _ControlledImage();
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          child: MangaPageImage(
            provider: provider,
            url: 'https://pages.invalid/1.png',
            sourceId: 'isolated',
            fit: BoxFit.fitWidth,
            settings: const MangaViewSettings(base: ReaderSettings()),
            onRetry: () => retries++,
          ),
        ),
      ),
    );
    final tile = find.byType(MangaPageImage);
    final pendingHeight = tester.getSize(tile).height;
    expect(pendingHeight, greaterThan(300));
    provider.streams.single.fail();
    await tester.pump();
    expect(find.text('重新加载'), findsOneWidget);
    expect(tester.getSize(tile).height, pendingHeight);
    await tester.tap(find.text('重新加载'));
    await tester.pump();
    expect(retries, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.getSize(tile).height, pendingHeight);

    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.teal, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(30, 90));
    picture.dispose();
    provider.streams.last.image(image!);
    await tester.pump();
    final decodedHeight = tester.getSize(tile).height;
    expect(decodedHeight, tester.getSize(tile).width * 3);
    provider.streams.last.fail();
    await tester.pump();
    expect(tester.getSize(tile).height, decodedHeight);
    await tester.ensureVisible(find.text('重新加载'));
    await tester.tap(find.text('重新加载'));
    await tester.pump();
    expect(retries, 2);
    expect(tester.getSize(tile).height, decodedHeight);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
}
