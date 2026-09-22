import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'dandanplay_client.dart';

/// 弹幕控制器：接收播放位置，维护屏幕上的弹幕集合。
///
/// 全部计算发生在**视频时间轴**上：控制器每次收到位置更新时记录
/// 「(视频时间, 挂钟时间)」锚点，绘制层据此推算当前的虚拟视频时间——
/// 播放时弹幕匀速前进，暂停时整层冻结，拖动进度后由 [seek] 清屏重来。
class DanmakuController extends ChangeNotifier {
  DanmakuController({
    this.scrollDurationMs = 9000,
    this.staticDurationMs = 4200,
    this.maxLaneCount = 8,
  });

  /// 滚动弹幕横穿屏幕的时长。
  final int scrollDurationMs;

  /// 顶部 / 底部弹幕的驻留时长。
  final int staticDurationMs;

  /// 航道数上限（实际按层高换算，取两者较小值）。
  final int maxLaneCount;

  List<DanmakuComment> _comments = const <DanmakuComment>[];

  /// 下一条待入场的弹幕下标（[comments] 已按时间排序）。
  int _cursor = 0;

  final List<ActiveDanmaku> _active = <ActiveDanmaku>[];

  /// 每条航道最近一次入场的 (视频时刻, 文本宽度)。
  final List<({double startMs, double width})> _lanes =
      <({double startMs, double width})>[];

  // 时间轴锚点：视频时间 + 挂钟时间 + 是否播放中。
  double _anchorVideoMs = 0;
  int _anchorWallMs = 0;
  bool _playing = true;

  // 布局参数（由绘制层 configure）。
  double _width = 0;
  double _laneHeight = 24;
  TextStyle _style = const TextStyle(fontSize: 16, color: Colors.white);

  bool _enabled = true;
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (!value) _active.clear();
    notifyListeners();
  }

  List<ActiveDanmaku> get active => _active;
  double get laneHeight => _laneHeight;

  /// 由绘制层在尺寸 / 样式变化时调用。
  void configure({
    required double width,
    required double laneHeight,
    required TextStyle style,
  }) {
    if (width == _width && laneHeight == _laneHeight && style == _style) return;
    _width = width;
    _laneHeight = laneHeight;
    _style = style;
    _active.clear(); // 样式变了，文本宽度需重新量，清屏重来最干净。
    notifyListeners();
  }

  /// 装载一集的弹幕（内部按时间排序）。
  void load(List<DanmakuComment> comments) {
    _comments = <DanmakuComment>[...comments]
      ..sort((a, b) => a.time.compareTo(b.time));
    _cursor = 0;
    _active.clear();
    _resyncCursor(_anchorVideoMs);
    notifyListeners();
  }

  void clear() {
    _comments = const <DanmakuComment>[];
    _cursor = 0;
    _active.clear();
    notifyListeners();
  }

  /// 播放位置更新（视频时间轴）。
  void update(Duration position, {required bool playing}) {
    _anchorVideoMs = position.inMilliseconds.toDouble();
    _anchorWallMs = DateTime.now().millisecondsSinceEpoch;
    _playing = playing;

    if (!_enabled || _comments.isEmpty) return;

    // 出场。
    _active.removeWhere((item) => _nowMs - item.startMs > _lifetime(item));

    // 入场：时间到点的全部放出（追帧时允许一次进多条）。
    while (_cursor < _comments.length &&
        _comments[_cursor].time * 1000 <= _nowMs) {
      _enter(_comments[_cursor]);
      _cursor++;
    }

    notifyListeners();
  }

  /// 拖动进度后调用：光标重定位并清屏，避免「补放几百条历史弹幕」。
  void seek(Duration position) {
    _anchorVideoMs = position.inMilliseconds.toDouble();
    _anchorWallMs = DateTime.now().millisecondsSinceEpoch;
    _resyncCursor(_anchorVideoMs);
    _active.clear();
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

  /// 当前虚拟视频时间（毫秒）。播放中按挂钟流逝推进，暂停时冻结。
  double get _nowMs {
    if (!_playing) return _anchorVideoMs;
    final wallDelta = DateTime.now().millisecondsSinceEpoch - _anchorWallMs;
    return _anchorVideoMs + wallDelta;
  }

  /// 供绘制层读取虚拟时间轴（保持时间轴逻辑单点维护）。
  double get nowMs => _nowMs;

  /// 绘制层的 Ticker 每帧调用一次，驱动重绘。
  void tick() => notifyListeners();

  int _lifetime(ActiveDanmaku item) =>
      item.lane == null ? staticDurationMs : scrollDurationMs;

  void _enter(DanmakuComment comment) {
    final textWidth = _measure(comment.text);
    if (comment.mode == 4 || comment.mode == 5) {
      // 顶部 / 底部：绘制层按入场顺序叠放，最多三层，放不下就丢。
      final sameKind = _active
          .where(
            (item) => item.lane == null && item.comment.mode == comment.mode,
          )
          .length;
      if (sameKind >= 3) return;
      _active.add(ActiveDanmaku(comment, _nowMs, textWidth));
      return;
    }

    final lane = _pickLane(textWidth);
    if (lane == null) return; // 全部航道都挤不上时丢弃，不打架
    _active.add(ActiveDanmaku(comment, _nowMs, textWidth, lane: lane));
  }

  /// 选一条此刻能容下新弹幕的航道（优先空闲最久的）。
  int? _pickLane(double textWidth) {
    if (_width <= 0 || _laneHeight <= 0) return null;
    final laneCount = math.min(maxLaneCount, (_laneHeightForLanes()).floor());
    if (laneCount <= 0) return null;

    while (_lanes.length < laneCount) {
      _lanes.add((startMs: -1e9, width: 0));
    }

    int? best;
    var bestStart = double.infinity;
    for (var lane = 0; lane < laneCount; lane++) {
      final last = _lanes[lane];
      final travelled =
          (_nowMs - last.startMs) / scrollDurationMs * (_width + last.width);
      if (travelled >= last.width + textWidth + 8 && last.startMs < bestStart) {
        best = lane;
        bestStart = last.startMs;
      }
    }
    if (best == null) return null;
    _lanes[best] = (startMs: _nowMs, width: textWidth);
    return best;
  }

  double _laneHeightForLanes() => _height / _laneHeight;

  double _height = 0;
  set height(double value) => _height = value;

  double _measure(String text) {
    if (text.isEmpty || _width <= 0) return 0;
    final painter = TextPainter(
      text: TextSpan(text: text, style: _style),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width;
  }
}

/// 屏幕上正在飘的一条弹幕（仅供本文件与绘制层使用）。
class ActiveDanmaku {
  const ActiveDanmaku(this.comment, this.startMs, this.width, {this.lane});

  final DanmakuComment comment;

  /// 入场时刻（视频时间轴，毫秒）。
  final double startMs;

  /// 预先量好的文本宽度（避免每帧排版）。
  final double width;

  /// 滚动弹幕占用的航道；顶部 / 底部为 null。
  final int? lane;
}

/// 弹幕层：盖在播放器画面上，透明命中测试（不挡播放器手势）。
class DanmakuOverlay extends StatelessWidget {
  const DanmakuOverlay({super.key, required this.controller});

  final DanmakuController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final style = DefaultTextStyle.of(context).style
            .copyWith(fontSize: 16, color: Colors.white);
        return DanmakuCanvas(
          controller: controller,
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          style: style,
        );
      },
    );
  }
}

/// 内部画布：持有一个常驻 Ticker，每帧让弹幕层重绘。
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
    // 每帧触发一次重绘；弹幕坐标全部由控制器的虚拟时间轴推导。
    _ticker = createTicker((_) => widget.controller.tick());
    _ticker.start();
  }

  void _syncConfig() {
    final controller = widget.controller;
    controller
      ..height = widget.height
      ..configure(
        width: widget.width,
        laneHeight: widget.style.fontSize! * 1.6,
        style: widget.style,
      );
  }

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
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size(widget.width, widget.height),
        painter: _DanmakuPainter(controller: widget.controller),
      ),
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({required this.controller});

  final DanmakuController controller;

  @override
  void paint(Canvas canvas, Size size) {
    if (!controller.enabled) return;

    final nowMs = _virtualNowMs();
    var topSlots = 0;
    var bottomSlots = 0;

    for (final item in controller.active) {
      final lifetime = item.lane == null
          ? controller.staticDurationMs
          : controller.scrollDurationMs;
      if (nowMs - item.startMs > lifetime) continue;

      final style = TextStyle(
        fontSize: 16,
        color: Color(0xFF000000 | item.comment.color).withValues(alpha: 0.92),
        shadows: const <Shadow>[
          Shadow(offset: Offset(1, 1), blurRadius: 2, color: Colors.black54),
        ],
      );

      if (item.lane != null) {
        // 滚动弹幕：从右侧匀速飘向左侧。
        final progress = (nowMs - item.startMs) / controller.scrollDurationMs;
        final x = size.width - progress * (size.width + item.width);
        final y = item.lane! * controller.laneHeight + 2;
        _draw(canvas, item.comment.text, Offset(x, y), style);
      } else {
        // 顶部（5）/ 底部（4）：居中叠放。
        final isTop = item.comment.mode == 5;
        final slot = isTop ? topSlots : bottomSlots;
        if (slot >= 3) continue;
        final y = isTop
            ? slot * controller.laneHeight + 2
            : size.height - (slot + 1) * controller.laneHeight - 2;
        final x = (size.width - item.width) / 2;
        _draw(canvas, item.comment.text, Offset(x, y), style);
        if (isTop) {
          topSlots++;
        } else {
          bottomSlots++;
        }
      }
    }
  }

  /// 从控制器读虚拟视频时间：绘制层不自己推锚点，保持时间轴逻辑单点维护。
  double _virtualNowMs() => controller.nowMs;

  void _draw(Canvas canvas, String text, Offset offset, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) => true;
}
