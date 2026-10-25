import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'data/player_settings.dart';

enum PlayerMenuAction {
  skip,
  subtitles,
  pip,
  line,
  episodes,
  retry,
  danmakuSettings,
  danmakuSources,
  toggleDanmaku,
}

/// A small, scrollable menu whose secondary pages stay inside the same anchor.
/// Keeping one panel avoids pushing submenus off narrow phone screens.
class PlayerMenu extends StatefulWidget {
  const PlayerMenu({
    super.key,
    required this.settings,
    required this.onSettingsChanged,
    required this.onAction,
    required this.onVisibilityChanged,
    required this.builder,
    this.controller,
    this.nativeAndroid = false,
    this.lineName,
    this.danmakuEnabled = false,
    this.danmakuOn = true,
    this.volumeEnabled = true,
    this.volumeStatus,
    this.onVolumeChanged,
  });

  final PlayerSettings settings;
  final Future<void> Function(PlayerSettings) onSettingsChanged;
  final Future<void> Function(PlayerMenuAction) onAction;
  final ValueChanged<bool> onVisibilityChanged;
  final Widget Function(BuildContext, VoidCallback) builder;
  final MenuController? controller;
  final bool nativeAndroid;
  final String? lineName;
  final bool danmakuEnabled;
  final bool danmakuOn;
  final bool volumeEnabled;
  final String? volumeStatus;
  final Future<double> Function(double)? onVolumeChanged;

  @override
  State<PlayerMenu> createState() => _PlayerMenuState();
}

enum _MenuPage {
  root,
  speed,
  ratio,
  preferences,
  holdSpeed,
  volume,
  danmaku,
  info,
}

class _PlayerMenuState extends State<PlayerMenu> {
  late final MenuController _controller;
  final _scrollController = ScrollController();
  final _anchorFocus = FocusNode(debugLabel: 'Player menu anchor');
  late PlayerSettings _settings;
  _MenuPage _page = _MenuPage.root;
  LocalHistoryEntry? _history;
  bool _open = false;
  bool _disposing = false;
  bool _busy = false;
  bool _volumeDragging = false;
  String? _error;
  Size? _overlaySize;

  @override
  void initState() {
    _controller = widget.controller ?? MenuController();
    super.initState();
    _settings = widget.settings;
  }

  @override
  void didUpdateWidget(PlayerMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_busy && !_volumeDragging) {
      _settings = widget.settings;
    } else if (!_busy) {
      // Device polling may update the other preferences, not the drag draft.
      _settings = widget.settings.copyWith(volume: _settings.volume);
    }
  }

  void _opened() {
    final overlay = Overlay.of(
      context,
      rootOverlay: true,
    ).context.findRenderObject();
    if (overlay is RenderBox && overlay.hasSize) _overlaySize = overlay.size;
    _open = true;
    _page = _MenuPage.root;
    _error = null;
    _settings = widget.settings;
    final route = ModalRoute.of(context);
    if (route != null) {
      _history = LocalHistoryEntry(
        onRemove: () {
          _history = null;
          if (!_disposing && _controller.isOpen) _controller.close();
        },
      );
      route.addLocalHistoryEntry(_history!);
    }
    widget.onVisibilityChanged(true);
    setState(() {});
  }

  void _closed() {
    final history = _history;
    _history = null;
    history?.remove();
    if (!_open) return;
    _open = false;
    _volumeDragging = false;
    if (!_disposing) widget.onVisibilityChanged(false);
  }

  void _navigate(_MenuPage page) {
    setState(() {
      _page = page;
      _error = null;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  Future<void> _change(
    PlayerSettings settings, {
    bool volumeOnly = false,
  }) async {
    if (_busy) return;
    final previous = widget.settings;
    setState(() {
      _settings = settings;
      _busy = true;
      _error = null;
    });
    try {
      final changeVolume = widget.onVolumeChanged;
      if (volumeOnly && changeVolume != null) {
        final actual = await changeVolume(settings.volume);
        if (mounted) {
          _settings = _settings.copyWith(volume: actual);
          _error = widget.volumeStatus;
        }
      } else {
        await widget.onSettingsChanged(settings);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _settings = previous;
          _error = '设置未能应用，请重试';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _act(PlayerMenuAction action) async {
    if (_busy) return;
    // The owner acquires its action hold synchronously before the anchor closes.
    final result = widget.onAction(action);
    _controller.close();
    await result;
  }

  @override
  void dispose() {
    _disposing = true;
    if (_open) {
      final onVisibilityChanged = widget.onVisibilityChanged;
      scheduleMicrotask(() => onVisibilityChanged(false));
    }
    final history = _history;
    _history = null;
    history?.remove();
    _scrollController.dispose();
    _anchorFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // SafeArea consumes its padding before this control is built. The root
    // overlay does not retain that local MediaQuery; reserve these insets
    // inside the menu child, where native edge clamping cannot discard them.
    var safe = media.padding;
    context.visitAncestorElements((element) {
      final ancestor = element.widget;
      if (ancestor is MediaQuery && ancestor.data.size == media.size) {
        final padding = ancestor.data.padding;
        safe = EdgeInsets.fromLTRB(
          math.max(safe.left, padding.left),
          math.max(safe.top, padding.top),
          math.max(safe.right, padding.right),
          math.max(safe.bottom, padding.bottom),
        );
      }
      return true;
    });
    final rootMedia =
        MediaQuery.maybeOf(
          Navigator.of(context, rootNavigator: true).context,
        ) ??
        media;
    final insets = math.max(
      media.viewInsets.bottom,
      rootMedia.viewInsets.bottom,
    );
    final menuMargin = EdgeInsets.fromLTRB(
      safe.left + 8,
      safe.top + 8,
      safe.right + 8,
      safe.bottom + insets + 8,
    );
    final viewport = _overlaySize ?? media.size;
    final width = math.min(
      296.0,
      math.max(0.0, viewport.width - menuMargin.horizontal - 16),
    );
    final height = math.max(
      0.0,
      math.min(480.0, viewport.height - menuMargin.vertical - 16),
    );
    final colors = Theme.of(context).colorScheme;
    return MenuAnchor(
      controller: _controller,
      childFocusNode: _anchorFocus,
      reservedPadding: const EdgeInsets.all(8),
      useRootOverlay: true,
      consumeOutsideTap: true,
      onOpen: _opened,
      onClose: _closed,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shadowColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
      ),
      menuChildren: [
        Padding(
          padding: menuMargin,
          child: Material(
            color: colors.surfaceContainerHigh,
            surfaceTintColor: colors.surfaceTint,
            elevation: 8,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: colors.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: width,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: height),
                child: Scrollbar(
                  controller: _scrollController,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _items(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
      builder: (context, controller, _) => Focus(
        focusNode: _anchorFocus,
        child: widget.builder(context, () {
          if (controller.isOpen) {
            controller.close();
          } else {
            controller.open();
          }
        }),
      ),
    );
  }

  List<Widget> _items(BuildContext context) {
    final items = <Widget>[];
    if (_page != _MenuPage.root) {
      items.add(
        _row(
          key: const ValueKey('player-menu-back'),
          icon: Icons.arrow_back_rounded,
          label: switch (_page) {
            _MenuPage.speed => '播放倍速',
            _MenuPage.ratio => '画面比例',
            _MenuPage.preferences => '播放偏好',
            _MenuPage.holdSpeed => '长按倍速',
            _MenuPage.volume => '音量',
            _MenuPage.danmaku => '弹幕',
            _MenuPage.info => '预载说明',
            _MenuPage.root => '播放设置',
          },
          onTap: () => _navigate(
            _page == _MenuPage.holdSpeed
                ? _MenuPage.preferences
                : _MenuPage.root,
          ),
        ),
      );
      items.add(const Divider(height: 8));
    }
    switch (_page) {
      case _MenuPage.root:
        items.addAll([
          _link(
            'speed',
            Icons.speed_rounded,
            '播放倍速',
            '${_settings.speed}×',
            _MenuPage.speed,
          ),
          _link(
            'ratio',
            Icons.aspect_ratio_rounded,
            '画面比例',
            _settings.aspectRatio.label,
            _MenuPage.ratio,
          ),
          _link(
            'preferences',
            Icons.tune_rounded,
            '播放偏好',
            null,
            _MenuPage.preferences,
          ),
          _link(
            'volume',
            Icons.volume_up_rounded,
            '音量',
            widget.volumeStatus ?? '${(_settings.volume * 100).round()}%',
            _MenuPage.volume,
          ),
          const Divider(height: 8),
          _action(PlayerMenuAction.episodes, Icons.playlist_play_rounded, '选集'),
          if (widget.lineName != null)
            _action(
              PlayerMenuAction.line,
              Icons.alt_route_rounded,
              '切换线路',
              detail: widget.lineName,
            ),
          _action(PlayerMenuAction.subtitles, Icons.subtitles_rounded, '字幕'),
          if (widget.danmakuEnabled)
            _link(
              'danmaku',
              Icons.speaker_notes_outlined,
              '弹幕',
              widget.danmakuOn ? '已开启' : '已关闭',
              _MenuPage.danmaku,
            ),
          if (widget.nativeAndroid)
            _action(
              PlayerMenuAction.pip,
              Icons.picture_in_picture_alt_rounded,
              '画中画',
            ),
          _action(PlayerMenuAction.retry, Icons.refresh_rounded, '重新加载'),
          const Divider(height: 8),
          _link('info', Icons.memory_outlined, '预载说明', null, _MenuPage.info),
        ]);
      case _MenuPage.speed:
        for (final value in [.5, .75, 1.0, 1.25, 1.5, 2.0, 3.0]) {
          items.add(
            _choice(
              'speed-$value',
              '$value×',
              _settings.speed == value,
              () => _change(_settings.copyWith(speed: value)),
            ),
          );
        }
      case _MenuPage.ratio:
        for (final ratio in VideoAspectRatio.values) {
          items.add(
            _choice(
              'ratio-${ratio.name}',
              ratio.label,
              _settings.aspectRatio == ratio,
              () => _change(_settings.copyWith(aspectRatio: ratio)),
            ),
          );
        }
      case _MenuPage.preferences:
        items.addAll([
          _choice(
            'auto-next',
            '同列表自动播放下一集',
            _settings.autoNext,
            () => _change(_settings.copyWith(autoNext: !_settings.autoNext)),
          ),
          _choice(
            'background-audio',
            '后台音频',
            _settings.backgroundAudio,
            () => _change(
              _settings.copyWith(backgroundAudio: !_settings.backgroundAudio),
            ),
            detail: widget.nativeAndroid ? '媒体通知与锁屏控制；退出后停止' : '最小化继续音频；退出后停止',
          ),
          _link(
            'hold-speed',
            Icons.touch_app_outlined,
            '长按倍速',
            '${_settings.holdSpeed}×',
            _MenuPage.holdSpeed,
          ),
          _action(
            PlayerMenuAction.skip,
            Icons.fast_forward_rounded,
            '跳过秒数',
            detail: '${_settings.skipSeconds} 秒',
          ),
        ]);
      case _MenuPage.holdSpeed:
        for (final value in [1.0, 1.5, 2.0, 2.5, 3.0]) {
          items.add(
            _choice(
              'hold-speed-$value',
              '$value×',
              _settings.holdSpeed == value,
              () => _change(_settings.copyWith(holdSpeed: value)),
            ),
          );
        }
      case _MenuPage.volume:
        items.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              widget.volumeStatus ?? '${(_settings.volume * 100).round()}%',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        );
        items.add(
          Slider(
            key: const ValueKey('player-menu-volume-slider'),
            value: _settings.volume,
            onChangeStart: _busy || !widget.volumeEnabled
                ? null
                : (_) => setState(() => _volumeDragging = true),
            onChanged: _busy || !widget.volumeEnabled
                ? null
                : (value) => setState(() {
                    _settings = _settings.copyWith(volume: value);
                  }),
            onChangeEnd: _busy || !widget.volumeEnabled
                ? null
                : (value) {
                    _volumeDragging = false;
                    unawaited(
                      _change(
                        _settings.copyWith(volume: value),
                        volumeOnly: true,
                      ),
                    );
                  },
          ),
        );
      case _MenuPage.danmaku:
        items.addAll([
          _choice(
            'danmaku-toggle',
            '显示弹幕',
            widget.danmakuOn,
            () => _act(PlayerMenuAction.toggleDanmaku),
          ),
          _action(PlayerMenuAction.danmakuSettings, Icons.tune_rounded, '弹幕设置'),
          _action(
            PlayerMenuAction.danmakuSources,
            Icons.hub_outlined,
            '来源 / 匹配',
          ),
        ]);
      case _MenuPage.info:
        items.add(
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '持续预载本集 · 有界内存\n\n'
              '${widget.nativeAndroid ? '应用堆上限的 1/8，最多 128 MiB' : '最多 128 MiB'}'
              '（不含解码器）。向本集结尾加载，满额后随播放释放并继续。'
              '退出即释放，不写入离线下载；离线观看请使用下载管理。',
            ),
          ),
        );
    }
    if (_busy) items.add(const LinearProgressIndicator(minHeight: 2));
    if (_error != null) {
      items.add(
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );
    }
    return items;
  }

  Widget _link(
    String id,
    IconData icon,
    String label,
    String? detail,
    _MenuPage page,
  ) => _row(
    key: ValueKey('player-menu-$id'),
    icon: icon,
    label: label,
    detail: detail,
    trailing: const Icon(Icons.chevron_right_rounded, size: 18),
    onTap: () => _navigate(page),
  );

  Widget _action(
    PlayerMenuAction action,
    IconData icon,
    String label, {
    String? detail,
  }) => _row(
    key: ValueKey('player-menu-action-${action.name}'),
    icon: icon,
    label: label,
    detail: detail,
    onTap: _busy ? null : () => unawaited(_act(action)),
  );

  Widget _choice(
    String id,
    String label,
    bool selected,
    VoidCallback onTap, {
    String? detail,
  }) => Semantics(
    selected: selected,
    child: _row(
      key: ValueKey('player-menu-$id'),
      icon: selected
          ? Icons.check_circle_rounded
          : Icons.radio_button_unchecked_rounded,
      label: label,
      detail: detail,
      selected: selected,
      onTap: _busy ? null : onTap,
    ),
  );

  Widget _row({
    required Key key,
    required IconData icon,
    required String label,
    String? detail,
    Widget? trailing,
    bool selected = false,
    required VoidCallback? onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: selected ? colors.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: selected
                      ? colors.onSecondaryContainer
                      : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: selected
                              ? colors.onSecondaryContainer
                              : colors.onSurface,
                          fontWeight: selected ? FontWeight.w600 : null,
                        ),
                      ),
                      if (detail != null)
                        Text(
                          detail,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 6), trailing],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
