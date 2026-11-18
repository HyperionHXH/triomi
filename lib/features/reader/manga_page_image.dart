import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/widgets/image_viewer.dart';
import 'manga_reader_settings.dart';

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
    this.imageHeaders = const {},
    this.part = 0,
    this.turns = 0,
    this.trimOverride,
    this.onGeometry,
  });
  final ImageProvider provider;
  final String url, sourceId;
  final BoxFit fit;
  final Map<String, String> imageHeaders;
  final MangaViewSettings settings;
  final int part, turns;
  final bool? trimOverride;
  final ValueChanged<Size>? onGeometry;
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
    final identityChanged =
        old.url != widget.url || old.sourceId != widget.sourceId;
    if (identityChanged ||
        old.provider != widget.provider ||
        old.settings.trim != widget.settings.trim ||
        old.trimOverride != widget.trimOverride) {
      _resolve();
    }
  }

  void _resolve({bool retainGeometry = false}) {
    final generation = ++_generation;
    if (_listener != null) _stream?.removeListener(_listener!);
    _info?.dispose();
    _info = null;
    if (!retainGeometry) _crop = null;
    _failed = false;
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
        widget.onGeometry?.call(_crop!.size);
        if (!(widget.trimOverride ?? widget.settings.trim)) return;
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
        widget.onGeometry?.call(_crop!.size);
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
      return _status(
        child: TextButton(
          onPressed: () async {
            final generation = _generation;
            await widget.provider.evict();
            if (!mounted || generation != _generation) return;
            _resolve(retainGeometry: true);
            setState(() {});
          },
          child: const Text('重新加载'),
        ),
      );
    }
    final image = _info?.image;
    var crop = _crop;
    if (image == null || crop == null) {
      return _status(child: const CircularProgressIndicator());
    }
    if (widget.part == 1) {
      crop = ui.Rect.fromLTRB(crop.left, crop.top, crop.center.dx, crop.bottom);
    }
    if (widget.part == 2) {
      crop = ui.Rect.fromLTRB(
        crop.center.dx,
        crop.top,
        crop.right,
        crop.bottom,
      );
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
    final options = widget.settings.options;
    if (options.flag('customColor')) {
      final mode = switch (options.choice('colorBlend', [
        'over',
        'multiply',
        'screen',
      ])) {
        'multiply' => BlendMode.multiply,
        'screen' => BlendMode.screen,
        _ => BlendMode.srcOver,
      };
      content = ColorFiltered(
        colorFilter: ColorFilter.mode(
          Color.fromRGBO(
            options.number('colorR', 255, 0, 255).round(),
            options.number('colorG', 220, 0, 255).round(),
            options.number('colorB', 170, 0, 255).round(),
            options.number('colorAlpha', 15, 0, 100) / 100,
          ),
          mode,
        ),
        child: content,
      );
    }
    final regionSize = crop.size;
    if (widget.turns != 0) {
      content = RotatedBox(quarterTurns: widget.turns, child: content);
    }
    final fitted = LayoutBuilder(
      builder: (context, constraints) {
        final ratio = widget.turns.isOdd
            ? regionSize.height / regionSize.width
            : regionSize.width / regionSize.height;
        final scale = options.choice('imageScale', [
          'base',
          'stretch',
          'smart',
        ]);
        final fit = switch (scale) {
          'stretch' => BoxFit.fill,
          'smart' =>
            constraints.hasBoundedHeight &&
                    ratio > constraints.maxWidth / constraints.maxHeight
                ? BoxFit.fitWidth
                : BoxFit.contain,
          _ => widget.fit,
        };
        return constraints.hasBoundedHeight
            ? SizedBox.expand(
                child: FittedBox(fit: fit, child: content),
              )
            : AspectRatio(
                aspectRatio: ratio,
                child: FittedBox(fit: BoxFit.contain, child: content),
              );
      },
    );
    // 缩放由阅读器按页统一接管：只有那里能同时控制翻页手势的让位。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: widget.settings.options.flag('longPressActions')
          ? () => showModalBottomSheet<void>(
              context: context,
              builder: (sheetContext) => SafeArea(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      title: const Text('保存原图'),
                      leading: const Icon(Icons.save_alt),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        saveImageWithFeedback(
                          context,
                          imageUrl: widget.url,
                          sourceId: widget.sourceId,
                          imageHeaders: widget.imageHeaders,
                        );
                      },
                    ),
                    ListTile(
                      title: const Text('查看完整图片'),
                      leading: const Icon(Icons.fullscreen),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        showImageViewer(
                          context,
                          imageUrl: widget.url,
                          sourceId: widget.sourceId,
                          imageHeaders: widget.imageHeaders,
                        );
                      },
                    ),
                  ],
                ),
              ),
            )
          : null,
      child: Center(child: fitted),
    );
  }

  Widget _status({required Widget child}) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.hasBoundedHeight) {
        return SizedBox.expand(child: Center(child: child));
      }
      final crop = _crop;
      // An unbounded webtoon tile must occupy a page while loading or failed;
      // tiny spinners otherwise mount dozens of images and collapse scrolling.
      final height = crop == null
          ? MediaQuery.sizeOf(context).height
          : constraints.maxWidth * crop.height / crop.width;
      return SizedBox(
        height: height,
        child: Center(child: child),
      );
    },
  );
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
