import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/widgets/image_viewer.dart';
import 'reader_work_settings.dart';

/// Uniform white/black margins only; never trim a non-uniform edge or >20%.
List<int> mangaTrimBounds(({Uint8List rgba, int width, int height}) data) {
  final bytes = data.rgba, width = data.width, height = data.height;
  if (width < 4 || height < 4 || bytes.length < width * height * 4) {
    return [0, 0, width, height];
  }
  final reference = bytes[0];
  if (!(reference < 24 || reference > 232) ||
      (bytes[1] - reference).abs() > 12 ||
      (bytes[2] - reference).abs() > 12) {
    return [0, 0, width, height];
  }
  bool background(int x, int y) {
    final index = (y * width + x) * 4;
    return (bytes[index] - reference).abs() <= 12 &&
        (bytes[index + 1] - reference).abs() <= 12 &&
        (bytes[index + 2] - reference).abs() <= 12;
  }

  bool row(int y) {
    for (var x = 0; x < width; x++) {
      if (!background(x, y)) return false;
    }
    return true;
  }

  bool column(int x) {
    for (var y = 0; y < height; y++) {
      if (!background(x, y)) return false;
    }
    return true;
  }

  var top = 0, bottom = height, left = 0, right = width;
  while (top < height ~/ 5 && row(top)) {
    top++;
  }
  while (bottom > height - height ~/ 5 && row(bottom - 1)) {
    bottom--;
  }
  while (left < width ~/ 5 && column(left)) {
    left++;
  }
  while (right > width - width ~/ 5 && column(right - 1)) {
    right--;
  }
  return [left, top, right, bottom];
}

class MangaPageImage extends StatefulWidget {
  const MangaPageImage({
    super.key,
    required this.provider,
    required this.url,
    required this.sourceId,
    required this.fit,
    required this.settings,
    required this.onRetry,
  });
  final ImageProvider provider;
  final String url, sourceId;
  final BoxFit fit;
  final MangaViewSettings settings;
  final VoidCallback onRetry;
  @override
  State<MangaPageImage> createState() => _MangaPageImageState();
}

class _MangaPageImageState extends State<MangaPageImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _info;
  ui.Rect? _crop;
  bool _failed = false;
  int _generation = 0;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(MangaPageImage old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider ||
        old.settings.trim != widget.settings.trim) {
      _resolve();
    }
  }

  void _resolve() {
    final generation = ++_generation;
    if (_listener != null) _stream?.removeListener(_listener!);
    final provider = widget.provider;
    _stream = provider.resolve(createLocalImageConfiguration(context));
    _listener = ImageStreamListener(
      (info, _) async {
        if (!mounted || generation != _generation) {
          info.dispose();
          return;
        }
        _info?.dispose();
        _info = info;
        _crop = ui.Rect.fromLTWH(
          0,
          0,
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        _failed = false;
        setState(() {});
        if (!widget.settings.trim) return;
        final width = info.image.width, height = info.image.height;
        final pixels = await info.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (pixels == null ||
            !mounted ||
            generation != _generation ||
            _info != info) {
          return;
        }
        final bounds = await compute(mangaTrimBounds, (
          rgba: pixels.buffer.asUint8List(),
          width: width,
          height: height,
        ));
        if (!mounted || generation != _generation || _info != info) return;
        setState(
          () => _crop = ui.Rect.fromLTRB(
            bounds[0].toDouble(),
            bounds[1].toDouble(),
            bounds[2].toDouble(),
            bounds[3].toDouble(),
          ),
        );
      },
      onError: (_, _) {
        if (mounted && generation == _generation) {
          setState(() => _failed = true);
        }
      },
    );
    _stream!.addListener(_listener!);
  }

  @override
  void dispose() {
    _generation++;
    if (_listener != null) _stream?.removeListener(_listener!);
    _info?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return Center(
        child: TextButton(
          onPressed: () async {
            await widget.provider.evict();
            if (!mounted) return;
            widget.onRetry();
            _resolve();
          },
          child: const Text('重新加载'),
        ),
      );
    }
    final image = _info?.image, crop = _crop;
    if (image == null || crop == null) {
      return const Center(child: CircularProgressIndicator());
    }
    Widget content = SizedBox(
      width: crop.width,
      height: crop.height,
      child: CustomPaint(painter: _PagePainter(image, crop)),
    );
    final filter = widget.settings.filter;
    if (filter != ReaderImageFilter.none) {
      content = ColorFiltered(
        colorFilter: ColorFilter.matrix(switch (filter) {
          ReaderImageFilter.grayscale => const [
            .2126,
            .7152,
            .0722,
            0,
            0,
            .2126,
            .7152,
            .0722,
            0,
            0,
            .2126,
            .7152,
            .0722,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
          ],
          ReaderImageFilter.invert => const [
            -1,
            0,
            0,
            0,
            255,
            0,
            -1,
            0,
            0,
            255,
            0,
            0,
            -1,
            0,
            255,
            0,
            0,
            0,
            1,
            0,
          ],
          ReaderImageFilter.warm => const [
            1,
            0,
            0,
            0,
            0,
            0,
            .94,
            0,
            0,
            0,
            0,
            0,
            .8,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
          ],
          ReaderImageFilter.none => throw StateError('No filter'),
        }),
        child: content,
      );
    }
    final fitted = LayoutBuilder(
      builder: (context, constraints) => constraints.hasBoundedHeight
          ? SizedBox.expand(
              child: FittedBox(fit: widget.fit, child: content),
            )
          : AspectRatio(
              aspectRatio: crop.width / crop.height,
              child: FittedBox(fit: BoxFit.contain, child: content),
            ),
    );
    return InteractiveViewer(
      minScale: 1,
      maxScale: 4,
      child: GestureDetector(
        onLongPress: () => saveImageWithFeedback(
          context,
          imageUrl: widget.url,
          sourceId: widget.sourceId,
        ),
        child: Center(child: fitted),
      ),
    );
  }
}

class _PagePainter extends CustomPainter {
  _PagePainter(this.image, this.source);
  final ui.Image image;
  final ui.Rect source;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawImageRect(
    image,
    source,
    Offset.zero & size,
    Paint()..filterQuality = FilterQuality.medium,
  );
  @override
  bool shouldRepaint(_PagePainter old) =>
      old.image != image || old.source != source;
}
