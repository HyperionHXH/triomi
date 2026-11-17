import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 缩放边界：平移不得露出底色，只允许在放大后可移动范围内拖动。
Offset mangaClampOffset(Offset offset, double scale, Size size) {
  if (scale <= 1 || size.isEmpty) return Offset.zero;
  final maxX = size.width * (scale - 1) / 2;
  final maxY = size.height * (scale - 1) / 2;
  return Offset(offset.dx.clamp(-maxX, maxX), offset.dy.clamp(-maxY, maxY));
}

/// 让 [anchor]（相对视图中心）在缩放后仍停在同一位置。
///
/// 与 Komikku 的 `zoomToward`/`animateScaleAndCenter` 等价：捏合保持焦点、
/// 双击保持落点，而不是一律居中，避免双击边缘后又看不到想看的内容。
Offset mangaAnchorOffset({
  required Offset anchor,
  required Offset offset,
  required double fromScale,
  required double toScale,
}) {
  if (fromScale <= 0) return offset;
  final ratio = toScale / fromScale;
  return anchor - (anchor - offset) * ratio;
}

/// 双击时在「原始大小」和「放大倍率」之间切换（Komikku 默认 2 倍，5 倍上限）。
double mangaDoubleTapTarget(double scale, double zoomScale, double maxScale) =>
    scale > 1.01 ? 1 : zoomScale.clamp(1.01, maxScale);

/// 双击/捏合动画时长预设。0 = 直接跳变（Komikku 的 No Animation）。
enum ZoomDurationPreset {
  none('无动画', 0),
  fast('快', 120),
  normal('标准', 250),
  slow('慢', 400);

  const ZoomDurationPreset(this.label, this.milliseconds);

  final String label;
  final int milliseconds;
}

/// 每张页面自己的缩放层：捏合、双击、放大后单指拖动。
///
/// 与阅读器翻页的协作：放大状态下父级 PageView 使用不可滚动物理，
/// 因此单指拖动只平移图片，不会误翻页；回到 1 倍后翻页恢复。
class MangaZoomView extends StatefulWidget {
  const MangaZoomView({
    super.key,
    required this.child,
    required this.enabled,
    required this.doubleTapZoom,
    required this.doubleTapScale,
    required this.duration,
    required this.resetToken,
    this.onTapUp,
    this.onZoomChanged,
    this.onLongPress,
  });

  final Widget child;
  final bool enabled;
  final bool doubleTapZoom;
  final double doubleTapScale;
  final ZoomDurationPreset duration;

  /// 翻页、换章或设置变化后递增：把遗留的放大状态复位。
  final int resetToken;
  final ValueChanged<TapUpDetails>? onTapUp;
  final ValueChanged<bool>? onZoomChanged;
  final VoidCallback? onLongPress;

  static const double maxScale = 5;

  @override
  State<MangaZoomView> createState() => MangaZoomViewState();
}

class MangaZoomViewState extends State<MangaZoomView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(vsync: this)
    ..addListener(_onAnimationTick);
  double _scale = 1;
  Offset _offset = Offset.zero;
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;
  Size _size = Size.zero;
  Offset _doubleTapPosition = Offset.zero;
  (double, Offset) _from = (1, Offset.zero);
  (double, Offset) _to = (1, Offset.zero);
  bool _reportedZoomed = false;

  bool get zoomed => _scale > 1.005;

  @override
  void didUpdateWidget(MangaZoomView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetToken != widget.resetToken ||
        oldWidget.enabled != widget.enabled) {
      // 复位后必须通知父级：否则翻页手势会一直保持禁用。
      _reset();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  void _notify() {
    if (!mounted) return;
    widget.onZoomChanged?.call(zoomed);
  }

  void _apply(double scale, Offset offset) {
    _scale = scale.clamp(1, MangaZoomView.maxScale);
    _offset = mangaClampOffset(offset, _scale, _size);
  }

  void _reset({bool notify = true}) {
    _animation.stop();
    setState(() {
      _scale = 1;
      _offset = Offset.zero;
    });
    if (notify) _syncZoom();
  }

  void _onAnimationTick() {
    final t = Curves.easeOut.transform(_animation.value.clamp(0, 1));
    setState(() {
      _scale = _from.$1 + (_to.$1 - _from.$1) * t;
      _offset = mangaClampOffset(
        Offset.lerp(_from.$2, _to.$2, t)!,
        _scale,
        _size,
      );
    });
    _syncZoom();
  }

  /// 只在「是否放大」真的变化时通知：动画每帧都会改比例，
  /// 但父级只在跨越 1 倍时才需要切换翻页手势。
  void _syncZoom() {
    if (_reportedZoomed == zoomed) return;
    _reportedZoomed = zoomed;
    _notify();
  }

  void _animateTo(double scale, Offset offset) {
    final target = scale.clamp(1.0, MangaZoomView.maxScale).toDouble();
    final destination = (target, mangaClampOffset(offset, target, _size));
    if (widget.duration.milliseconds == 0) {
      setState(() {
        _scale = destination.$1;
        _offset = destination.$2;
      });
      _syncZoom();
      return;
    }
    _from = (_scale, _offset);
    _to = destination;
    _animation
      ..stop()
      ..duration = Duration(milliseconds: widget.duration.milliseconds)
      ..forward(from: 0);
  }

  Offset _relative(Offset local) =>
      local - Offset(_size.width / 2, _size.height / 2);

  void _onScaleStart(ScaleStartDetails details) {
    if (!widget.enabled) return;
    _animation.stop();
    _startScale = _scale;
    _startOffset = _offset;
    _startFocal = _relative(details.localFocalPoint);
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (!widget.enabled) return;
    // 1 倍时单指拖动交给 PageView 翻页；只有双指或已放大才吃手势。
    if (details.pointerCount < 2 && _startScale <= 1.005) return;
    final focal = _relative(details.localFocalPoint);
    final target = (_startScale * details.scale).clamp(
      1.0,
      MangaZoomView.maxScale,
    );
    final offset = mangaAnchorOffset(
      anchor: focal,
      offset: _startOffset + (focal - _startFocal),
      fromScale: _startScale,
      toScale: target,
    );
    setState(() => _apply(target, offset));
    _notify();
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (!widget.enabled) return;
    if (_scale < 1.02) {
      _animateTo(1, Offset.zero);
    } else {
      setState(() => _apply(_scale, _offset));
      _notify();
    }
  }

  void _onDoubleTap() {
    if (!widget.enabled || !widget.doubleTapZoom || _size.isEmpty) return;
    final target = mangaDoubleTapTarget(
      _scale,
      widget.doubleTapScale,
      MangaZoomView.maxScale,
    );
    if (target <= 1.01) {
      _animateTo(1, Offset.zero);
      return;
    }
    final anchor = _relative(_doubleTapPosition);
    _animateTo(
      target,
      mangaAnchorOffset(
        anchor: anchor,
        offset: _offset,
        fromScale: _scale,
        toScale: target,
      ),
    );
  }

  /// 放大后点按左右区域先平移；已经在边界上返回 false 让它继续翻页。
  bool panBy(double dx) {
    if (_scale <= 1.005 || _size.isEmpty) return false;
    final next = mangaClampOffset(_offset + Offset(dx, 0), _scale, _size);
    if ((next.dx - _offset.dx).abs() < 1) return false;
    _animation.stop();
    setState(() => _offset = next);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != _size) {
          _size = size;
          _offset = mangaClampOffset(_offset, _scale, _size);
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: widget.enabled ? _onScaleStart : null,
          onScaleUpdate: widget.enabled ? _onScaleUpdate : null,
          onScaleEnd: widget.enabled ? _onScaleEnd : null,
          onDoubleTapDown: widget.enabled && widget.doubleTapZoom
              ? (details) => _doubleTapPosition = details.localPosition
              : null,
          onDoubleTap: widget.enabled && widget.doubleTapZoom
              ? _onDoubleTap
              : null,
          onTapUp: widget.onTapUp,
          onLongPress: widget.onLongPress,
          child: ClipRect(
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                ..scaleByDouble(_scale, _scale, 1, 1),
              child: widget.child,
            ),
          ),
        );
      },
    );
  }

  /// 供测试断言当前缩放状态。
  @visibleForTesting
  double get debugScale => _scale;

  @visibleForTesting
  double get debugMaxPanX => math.max(0, _size.width * (_scale - 1) / 2);

  @visibleForTesting
  Offset get debugOffset => _offset;
}
