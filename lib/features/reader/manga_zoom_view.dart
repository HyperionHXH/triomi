import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
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

/// 第二指按下立即认领，不再和翻页 DragGestureRecognizer 竞争阈值。
/// 单指超过 5dp 才开始移动，点击/双击/长按仍由各自识别器处理。
class _ReaderScaleRecognizer extends ScaleGestureRecognizer {
  _ReaderScaleRecognizer() {
    gestureSettings = const DeviceGestureSettings(touchSlop: 2.5);
  }

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    if (event is PointerDownEvent && pointerCount >= 2) {
      resolve(GestureDisposition.accepted);
    }
  }
}

/// 每张页面自己的缩放层：捏合、双击、放大后单指拖动。
///
/// 父级只负责布局与滚动物理，触摸由这一层独占仲裁：单指在原始大小时
/// 驱动真实 ScrollPosition；第二指落下立即中止翻页并锁定整个触摸序列。
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
    this.scrollPosition,
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

  /// 条漫缩放包在整个列表外，滚动位置由已构建的列表项提供。
  final ScrollPosition? Function()? scrollPosition;

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
  double _gestureScaleBase = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;
  Size _size = Size.zero;
  Offset _doubleTapPosition = Offset.zero;
  (double, Offset) _from = (1, Offset.zero);
  (double, Offset) _to = (1, Offset.zero);
  bool _reportedZoomed = false;
  ScrollPosition? _scroll;
  ScrollHoldController? _hold;
  Drag? _drag;
  double _scrollOrigin = 0;
  bool _pinched = false;
  final Set<int> _touches = {};

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
    _drag?.cancel();
    _hold?.cancel();
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

  void _onPointerDown(PointerDownEvent event) {
    if (_touches.isEmpty) {
      _pinched = false;
      _animation.stop();
      _scroll =
          widget.scrollPosition?.call() ??
          Scrollable.maybeOf(context)?.position;
      _scrollOrigin = _scroll?.pixels ?? 0;
      _hold = _scroll?.hold(() => _hold = null);
    }
    _touches.add(event.pointer);
  }

  void _onPointerUp(PointerEvent event) {
    _touches.remove(event.pointer);
    if (_touches.isEmpty) {
      // 先处理最终 UP（包括 fling），再释放点击的 hold。
      scheduleMicrotask(() {
        if (!mounted || _touches.isNotEmpty) return;
        _hold?.cancel();
        _hold = null;
      });
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _animation.stop();
    _startScale = _scale;
    _gestureScaleBase = 1;
    _startOffset = _offset;
    _startFocal = _relative(details.localFocalPoint);
    if (details.pointerCount >= 2 && !_pinched) {
      _pinched = true;
      // 第一指先动也可转成捏合；撤销页偏移，不把相邻页拖出来。
      _drag?.cancel();
      _drag = null;
      _scroll?.jumpTo(_scrollOrigin);
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (!_pinched && !zoomed && details.pointerCount == 1) {
      final scroll = _scroll;
      if (scroll == null) return;
      _drag ??= scroll.drag(
        DragStartDetails(
          globalPosition: details.focalPoint,
          localPosition: details.localFocalPoint,
          sourceTimeStamp: details.sourceTimeStamp,
        ),
        () => _drag = null,
      );
      final vertical =
          axisDirectionToAxis(scroll.axisDirection) == Axis.vertical;
      final delta = vertical
          ? details.focalPointDelta.dy
          : details.focalPointDelta.dx;
      _drag?.update(
        DragUpdateDetails(
          delta: vertical ? Offset(0, delta) : Offset(delta, 0),
          primaryDelta: delta,
          globalPosition: details.focalPoint,
          localPosition: details.localFocalPoint,
          sourceTimeStamp: details.sourceTimeStamp,
        ),
      );
      return;
    }
    if (!widget.enabled) return;
    final focal = _relative(details.localFocalPoint);
    final target = (_startScale * details.scale / _gestureScaleBase).clamp(
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
    if (target == 1 && details.pointerCount >= 2) {
      // 触及最小值后重设基准，反向张开立即放大，无需补回收缩过量。
      _startScale = 1;
      _gestureScaleBase = details.scale;
      _startOffset = _offset;
      _startFocal = focal;
    }
    _syncZoom();
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (details.pointerCount != 0) return;
    if (!_pinched) {
      final velocity = details.velocity.pixelsPerSecond;
      final vertical =
          _scroll != null &&
          axisDirectionToAxis(_scroll!.axisDirection) == Axis.vertical;
      _drag?.end(
        DragEndDetails(
          velocity: Velocity(
            pixelsPerSecond: vertical
                ? Offset(0, velocity.dy)
                : Offset(velocity.dx, 0),
          ),
          primaryVelocity: vertical ? velocity.dy : velocity.dx,
        ),
      );
      _drag = null;
    }
    if (_scale < 1.02) {
      _animateTo(1, Offset.zero);
    } else {
      setState(() => _apply(_scale, _offset));
      _syncZoom();
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
        return Listener(
          onPointerDown: _onPointerDown,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerUp,
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              _ReaderScaleRecognizer:
                  GestureRecognizerFactoryWithHandlers<_ReaderScaleRecognizer>(
                    _ReaderScaleRecognizer.new,
                    (recognizer) => recognizer
                      ..onStart = _onScaleStart
                      ..onUpdate = _onScaleUpdate
                      ..onEnd = _onScaleEnd,
                  ),
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
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
