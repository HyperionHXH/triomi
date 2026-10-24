import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/text/zh_converter.dart';
import 'danmaku_settings.dart';
import 'hybrid_danmaku_models.dart';

/// Source time always drives emission. Animation has a separate, pause-aware
/// clock so disabling followVideoRate cannot shift which source comment is due.
class DanmakuController extends ChangeNotifier {
  DanmakuController({
    this.maxLaneCount = 8,
    DanmakuSettings? settings,
    int Function()? wallClockMs,
    this._converter,
    Future<ZhConverter> Function()? converterLoader,
  }) : _settings = (settings ?? const DanmakuSettings()).copyWith(),
       _enabled = settings?.enabled ?? true,
       _wallClockMs = wallClockMs ?? _systemWallClockMs,
       _converterLoader = converterLoader ?? ZhConverter.instance;

  static int _systemWallClockMs() => DateTime.now().millisecondsSinceEpoch;
  static const maxLayoutCache = 384;
  final int Function() _wallClockMs;
  final int maxLaneCount;
  DanmakuSettings _settings;
  DanmakuSettings get settings => _settings;
  int get scrollDurationMs => _settings.scrollDurationMs;
  int get staticDurationMs => _settings.staticDurationMs;
  int get activeLimit => _settings.maxActive;
  int get layoutCacheCount => _layouts.length;

  List<DanmakuComment> _raw = const [];
  List<DanmakuComment> _comments = const [];
  final List<ActiveDanmaku> _active = [];
  final LinkedHashMap<({String text, int color}), _TextLayout> _layouts =
      LinkedHashMap();
  final Map<({String text, int mode}), double> _recentDuplicates = {};
  int _cursor = 0;
  int _massiveLane = 0;
  double _anchorVideoMs = 0;
  double _anchorAnimationMs = 0;
  int _anchorWallMs = 0;
  bool _hasAnchor = false;
  bool _playing = false;
  double _rate = 1;
  double _width = 0;
  double _height = 0;
  double _configuredLaneHeight = 24;
  TextStyle _baseStyle = const TextStyle(fontSize: 16, color: Colors.white);
  bool _enabled;
  bool _disposed = false;
  ZhConverter? _converter;
  Future<void>? _converterLoading;
  final Future<ZhConverter> Function() _converterLoader;
  final Map<String, String> _convertedTexts = {};

  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    applySettings(_settings.copyWith(enabled: value));
  }

  List<ActiveDanmaku> get active => List.unmodifiable(_active);
  double get laneHeight => math.max(
    _settings.fontSize + (_settings.outline ? _settings.outlineWidth * 2 : 0),
    _settings.fontSize * _settings.lineHeight,
  );
  double get areaHeight => _height * _settings.area;
  int get laneCount =>
      math.max(0, math.min(maxLaneCount, (areaHeight / laneHeight).floor()));

  TextStyle get _style => _baseStyle.copyWith(
    fontSize: _settings.fontSize,
    fontWeight: FontWeight.values[_settings.fontWeight - 1],
    height: 1,
    shadows: const [],
  );

  /// Applies immediately, without reloading comments or the video. Existing
  /// visible comments are rebuilt once so layout/filter changes are observable.
  void applySettings(DanmakuSettings next) {
    _anchorAnimationMs = animationNowMs;
    _anchorVideoMs = nowMs;
    _anchorWallMs = _wallClockMs();
    _settings = next.copyWith();
    _enabled = next.enabled;
    _rebuildFiltered(rebuildLayouts: true);
    _loadConverter();
    notifyListeners();
  }

  void _loadConverter() {
    if (_settings.conversion == ZhConversionMode.off ||
        _converter != null ||
        _converterLoading != null) {
      return;
    }
    _converterLoading = _initializeConverter();
  }

  Future<void> _initializeConverter() async {
    try {
      final converter = await _converterLoader();
      if (_disposed) return;
      _converter = converter;
      _rebuildFiltered(rebuildLayouts: true);
      notifyListeners();
    } catch (error, stack) {
      if (!_disposed) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'danmaku',
            context: ErrorDescription('加载已有 OpenCC 字表'),
          ),
        );
      }
    } finally {
      _converterLoading = null;
    }
  }

  String _converted(String text) => _convertedTexts.putIfAbsent(
    text,
    () => _converter?.convert(text, _settings.conversion) ?? text,
  );

  void _rebuildFiltered({bool rebuildLayouts = false}) {
    final visible = [
      for (final item in _active)
        (comment: item.comment, startMs: item.startMs),
    ];
    _convertedTexts.clear();
    _comments = [
      for (final comment in _raw)
        if (_allows(comment)) comment,
    ];
    _active.clear();
    if (rebuildLayouts) _clearLayouts();
    _recentDuplicates.clear();
    _massiveLane = 0;
    _resyncCursor(nowMs);
    if (_enabled && _settings.area > 0) {
      for (final item in visible) {
        if (_allows(item.comment) &&
            animationNowMs - item.startMs <
                (item.comment.mode == 4 || item.comment.mode == 5
                    ? staticDurationMs
                    : scrollDurationMs)) {
          _enter(item.comment, item.startMs);
        }
      }
    }
  }

  bool _allows(DanmakuComment comment) {
    final modeAllowed = switch (comment.mode) {
      5 => _settings.showTop,
      4 => _settings.showBottom,
      _ => _settings.showScroll,
    };
    if (!modeAllowed || _settings.filters(comment.text, user: comment.user)) {
      return false;
    }
    final converted = _converted(comment.text);
    return converted == comment.text ||
        !_settings.filters(converted, user: comment.user);
  }

  set height(double value) {
    final next = value.isFinite ? math.max(0.0, value) : 0.0;
    if (_height == next) return;
    _height = next;
    _active.clear();
  }

  /// Kept compatible with the existing player/controller consumer API.
  void configure({
    required double width,
    required double laneHeight,
    required TextStyle style,
  }) {
    final safeWidth = width.isFinite ? math.max(0.0, width) : 0.0;
    if (_width == safeWidth &&
        _configuredLaneHeight == laneHeight &&
        _baseStyle == style) {
      return;
    }
    _width = safeWidth;
    _configuredLaneHeight = laneHeight;
    _baseStyle = style;
    _rebuildFiltered(rebuildLayouts: true);
  }

  void load(List<DanmakuComment> comments) {
    _active.clear();
    _raw = [
      for (final comment in comments)
        if (comment.time.isFinite &&
            comment.time >= 0 &&
            comment.text.length <= DanmakuShieldRule.maxTextLength)
          comment,
    ]..sort((a, b) => a.time.compareTo(b.time));
    _rebuildFiltered(rebuildLayouts: true);
    // A late source load starts after the current timestamp; only a fresh
    // playback at zero may include timestamp-zero comments.
    _resyncCursor(nowMs == 0 ? -0.001 : nowMs);
    _loadConverter();
    notifyListeners();
  }

  void clear() {
    _raw = const [];
    _comments = const [];
    _cursor = 0;
    _active.clear();
    _recentDuplicates.clear();
    _convertedTexts.clear();
    _clearLayouts();
    notifyListeners();
  }

  void update(Duration position, {required bool playing, double rate = 1}) {
    final previousVideo = nowMs;
    final animation = animationNowMs;
    final nextVideo = position.inMilliseconds.toDouble();
    if (_hasAnchor &&
        (nextVideo < _anchorVideoMs - 250 ||
            (nextVideo - previousVideo).abs() > 2000)) {
      _active.clear();
      _recentDuplicates.clear();
      _resyncCursor(nextVideo - 0.001);
    }
    _anchorAnimationMs = animation;
    _anchorVideoMs = nextVideo;
    _anchorWallMs = _wallClockMs();
    _hasAnchor = true;
    _playing = playing;
    _rate = rate.isFinite && rate > 0 ? rate : 1;
    _advance();
    notifyListeners();
  }

  void seek(Duration position) {
    _anchorVideoMs = position.inMilliseconds.toDouble();
    _anchorAnimationMs = 0;
    _anchorWallMs = _wallClockMs();
    _hasAnchor = true;
    _resyncCursor(_anchorVideoMs);
    _active.clear();
    _recentDuplicates.clear();
    notifyListeners();
  }

  void _resyncCursor(double videoMs) {
    var low = 0;
    var high = _comments.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_comments[mid].time * 1000 <= videoMs) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    _cursor = low;
  }

  double get _wallDelta =>
      _playing ? math.max(0, _wallClockMs() - _anchorWallMs).toDouble() : 0;
  double get nowMs => _anchorVideoMs + _wallDelta * _rate;
  double get animationNowMs =>
      _anchorAnimationMs + _wallDelta * (_settings.followVideoRate ? _rate : 1);

  /// Filtering is prepared outside the ticker. Text layouts are cached at
  /// admission; only bounded visible comments are painted each frame.
  void tick() {
    if (!_playing || !_enabled) return;
    _advance();
    notifyListeners();
  }

  void _advance() {
    if (!_enabled || _settings.area <= 0) return;
    final animation = animationNowMs;
    _active.removeWhere((item) => animation - item.startMs >= _lifetime(item));
    final video = nowMs;
    // Skip entries too late to be visible rather than piling up after stalls.
    var processed = 0;
    while (_cursor < _comments.length &&
        _comments[_cursor].time * 1000 <= video) {
      final comment = _comments[_cursor++];
      if (++processed > 1000) {
        _resyncCursor(video);
        break;
      }
      final sourceAge = video - comment.time * 1000;
      final animationAge = sourceAge / (_settings.followVideoRate ? 1 : _rate);
      final lifetime = comment.mode == 4 || comment.mode == 5
          ? staticDurationMs
          : scrollDurationMs;
      if (animationAge >= lifetime) continue;
      _enter(comment, animation - animationAge);
    }
  }

  int _lifetime(ActiveDanmaku item) =>
      item.lane == null ? staticDurationMs : scrollDurationMs;

  void _enter(DanmakuComment comment, double startMs) {
    if (laneCount <= 0 || _width <= 0) return;
    final text = _converted(comment.text);
    final key = (text: text, mode: comment.mode);
    if (_settings.mergeDuplicates) {
      final sourceMs = comment.time * 1000;
      final last = _recentDuplicates[key];
      if (last != null &&
          sourceMs - last <= DanmakuSettings.duplicateWindowMs) {
        for (final item in _active) {
          if (item.text == text && item.comment.mode == comment.mode) {
            item.duplicateCount++;
            return;
          }
        }
        // One representative per source-time window, even after it leaves.
        return;
      }
      _recentDuplicates.removeWhere((_, time) => sourceMs - time > 5000);
      if (_recentDuplicates.length >= 600) _recentDuplicates.clear();
    }
    if (_active.length >= activeLimit) return;
    final layout = _layout(text, comment.color);
    final fixed = comment.mode == 4 || comment.mode == 5;
    final lane = _pickLane(layout.width, fixed ? comment.mode : 1, startMs);
    if (lane == null) return;
    if (_settings.mergeDuplicates) {
      _recentDuplicates[key] = comment.time * 1000;
    }
    final item = ActiveDanmaku(
      comment,
      startMs,
      layout.width,
      lane: fixed ? null : lane,
      slot: lane,
      text: text,
    ).._layout = layout;
    _active.add(item);
  }

  int? _pickLane(double width, int mode, double startMs) {
    if (_settings.massive) return _massiveLane++ % laneCount;
    final now = animationNowMs;
    final padding = _settings.outline ? _settings.outlineWidth * 2 : 0.0;
    final glyphHeight = _settings.fontSize + padding;
    for (var lane = 0; lane < laneCount; lane++) {
      final top = mode == 4
          ? areaHeight - (lane + 1) * laneHeight
          : lane * laneHeight;
      var occupied = false;
      for (final last in _active) {
        final lastTop = last.comment.mode == 4
            ? areaHeight - (last.slot + 1) * laneHeight
            : last.slot * laneHeight;
        if (top + glyphHeight <= lastTop || lastTop + glyphHeight <= top) {
          continue;
        }
        if (mode != 1 || last.lane == null) {
          occupied = true;
          break;
        }
        final previousSpeed = (_width + last.width) / scrollDurationMs;
        final newSpeed = (_width + width) / scrollDurationMs;
        final age = now - last.startMs;
        final previousRight = _width - age * previousSpeed + last.width;
        final newLeft = _width - (now - startMs) * newSpeed;
        final timeLeft = math.max(0, scrollDurationMs - age);
        final separation = newLeft - previousRight;
        // Prevent catching up before the older comment completely exits.
        if (separation < 8 ||
            separation + (previousSpeed - newSpeed) * timeLeft < 8) {
          occupied = true;
          break;
        }
      }
      if (!occupied) return lane;
    }
    return null;
  }

  _TextLayout _layout(String text, int sourceColor) {
    final color = _settings.showColor ? sourceColor & 0xFFFFFF : 0xFFFFFF;
    final key = (text: text, color: color);
    final cached = _layouts.remove(key);
    if (cached != null) {
      _layouts[key] = cached;
      return cached;
    }
    final style = _style.copyWith(
      color: Color(0xFF000000 | color).withValues(alpha: _settings.opacity),
    );
    final fill = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    TextPainter? stroke;
    if (_settings.outline) {
      stroke = TextPainter(
        text: TextSpan(
          text: text,
          style: style.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = _settings.outlineWidth * 2
              ..color = Colors.black.withValues(alpha: _settings.opacity),
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
    }
    final layout = _TextLayout(fill, stroke);
    _layouts[key] = layout;
    // Evicted painters may still belong to visible entries; retain those until
    // a later entry/clear, while keeping the cache and active set both bounded.
    while (_layouts.length > maxLayoutCache) {
      final oldest = _layouts.keys.first;
      final removed = _layouts.remove(oldest)!;
      if (_active.any((item) => identical(item._layout, removed))) {
        _layouts[oldest] = removed;
      } else {
        removed.dispose();
      }
    }
    return layout;
  }

  void _clearLayouts() {
    _active.clear();
    for (final layout in _layouts.values) {
      layout.dispose();
    }
    _layouts.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _clearLayouts();
    super.dispose();
  }
}

class _TextLayout {
  _TextLayout(this.fill, this.stroke);
  final TextPainter fill;
  final TextPainter? stroke;
  double get width => fill.width;
  void paint(Canvas canvas, Offset offset) {
    stroke?.paint(canvas, offset);
    fill.paint(canvas, offset);
  }

  void dispose() {
    fill.dispose();
    stroke?.dispose();
  }
}

class ActiveDanmaku {
  ActiveDanmaku(
    this.comment,
    this.startMs,
    this.width, {
    this.lane,
    this.slot = 0,
    String? text,
  }) : text = text ?? comment.text;
  final DanmakuComment comment;

  /// Pause-aware animation time, independent of source emission time.
  final double startMs;
  final double width;
  final int? lane;
  final int slot;
  final String text;
  _TextLayout? _layout;
  int duplicateCount = 1;
}

/// Ignores input, so video controls retain pointer/gesture ownership.
class DanmakuOverlay extends StatelessWidget {
  const DanmakuOverlay({super.key, required this.controller});
  final DanmakuController controller;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => DanmakuCanvas(
      controller: controller,
      width: constraints.maxWidth,
      height: constraints.maxHeight,
      style: DefaultTextStyle.of(context).style,
    ),
  );
}

class DanmakuCanvas extends StatefulWidget {
  const DanmakuCanvas({
    super.key,
    required this.controller,
    required this.width,
    required this.height,
    required this.style,
  });
  final DanmakuController controller;
  final double width;
  final double height;
  final TextStyle style;

  @override
  State<DanmakuCanvas> createState() => _DanmakuCanvasState();
}

class _DanmakuCanvasState extends State<DanmakuCanvas>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _syncConfig();
    _ticker = createTicker((_) => widget.controller.tick())..start();
  }

  void _syncConfig() => widget.controller
    ..height = widget.height
    ..configure(
      width: widget.width,
      laneHeight: widget.style.fontSize ?? 16,
      style: widget.style,
    );

  @override
  void didUpdateWidget(covariant DanmakuCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncConfig();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        size: Size(widget.width, widget.height),
        painter: _DanmakuPainter(widget.controller),
      ),
    ),
  );
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter(this.controller) : super(repaint: controller);
  final DanmakuController controller;

  @override
  void paint(Canvas canvas, Size size) {
    if (!controller.enabled || controller.settings.area <= 0) return;
    final now = controller.animationNowMs;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, controller.areaHeight));
    // Read the private bounded list directly: no list copy or text layout/frame.
    for (final item in controller._active) {
      final lifetime = item.lane == null
          ? controller.staticDurationMs
          : controller.scrollDurationMs;
      final age = now - item.startMs;
      if (age < 0 || age >= lifetime) continue;
      final x = item.lane == null
          ? (size.width - item.width) / 2
          : size.width - age / lifetime * (size.width + item.width);
      final y = item.comment.mode == 4
          ? controller.areaHeight - (item.slot + 1) * controller.laneHeight
          : item.slot * controller.laneHeight;
      item._layout?.paint(canvas, Offset(x, y));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) =>
      oldDelegate.controller != controller;
}
