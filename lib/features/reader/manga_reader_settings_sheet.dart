import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'manga_reader_options.dart';
import 'manga_reader_settings.dart';
import 'manga_zoom_view.dart';
import 'reader_settings.dart';

/// Komikku-style reader dialog: three swipeable, independently scrolling tabs.
class MangaReaderSettingsSheet extends ConsumerWidget {
  const MangaReaderSettingsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(mangaViewSettingsProvider);
    final prefs = ref.read(mangaReaderPreferencesProvider);
    final options = view.options;
    Widget toggle(String title, String key, bool enabled) => SwitchListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      title: Text(title),
      value: enabled,
      onChanged: (value) => prefs.set(key, value),
    );
    Widget select(
      String title,
      String key,
      String selected,
      Map<String, String> values,
    ) => ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      title: Text(title),
      trailing: DropdownButton<String>(
        value: selected,
        items: [
          for (final entry in values.entries)
            DropdownMenuItem(value: entry.key, child: Text(entry.value)),
        ],
        onChanged: (value) {
          if (value != null) prefs.set(key, value);
        },
      ),
    );
    Widget slider(
      String title,
      String key,
      double value,
      double min,
      double max,
      int steps, {
      bool integer = true,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, top: 8),
          child: Text('$title · ${value.toStringAsFixed(integer ? 0 : 1)}'),
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: steps,
          onChanged: (v) => prefs.set(key, integer ? v.round() : v),
        ),
      ],
    );
    Widget choices<T extends Enum>(
      String title,
      String key,
      T selected,
      List<T> values,
      String Function(T) label,
    ) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title),
          Wrap(
            spacing: 6,
            children: [
              for (final v in values)
                ChoiceChip(
                  label: Text(label(v)),
                  selected: selected == v,
                  onSelected: (_) => prefs.set(key, v.name),
                ),
            ],
          ),
        ],
      ),
    );
    List<Widget> advanced(bool Function(String) include) => [
      for (final entry in MangaReaderOptions.switches.entries)
        if (include(entry.key))
          toggle(entry.value.$1, entry.key, options.flag(entry.key)),
      for (final entry in MangaReaderOptions.choices.entries)
        if (include(entry.key))
          select(
            entry.value.$1,
            entry.key,
            options.choice(entry.key, entry.value.$2.keys.toList()),
            entry.value.$2,
          ),
      for (final entry in MangaReaderOptions.sliders.entries)
        if (include(entry.key))
          slider(
            entry.value.$1,
            entry.key,
            options.number(
              entry.key,
              entry.value.$2,
              entry.value.$3,
              entry.value.$4,
            ),
            entry.value.$3,
            entry.value.$4,
            entry.value.$5,
          ),
    ];
    const layoutKeys = {
      'splitWide',
      'splitWebtoon',
      'reverseSplit',
      'rotateWide',
      'rotateWebtoon',
      'rotateCounterclockwise',
      'invertDoublePages',
      'landscapeZoom',
      'trimWebtoon',
      'autoWebtoon',
      'zoomStart',
      'wideZoomType',
      'pageLayout',
      'centerMargin',
      'webtoonWidth',
      'imageScale',
      'webtoonPadding',
      'webtoonGap',
      'webtoonZoom',
      'webtoonDoubleTap',
      'smoothAutoScroll',
    };
    bool colorKey(String key) =>
        key == 'customColor' || key.startsWith('color');
    Widget page(String key, List<Widget> children) => ListView(
      key: PageStorageKey(key),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      children: children,
    );
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SizedBox(
          width: double.infinity,
          height: MediaQuery.sizeOf(context).height * .69,
          child: DefaultTabController(
            length: 3,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: '阅读模式'),
                    Tab(text: '通用'),
                    Tab(text: '滤镜'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      page('layout', [
                        choices(
                          '翻页方向',
                          'mode',
                          view.base.mode,
                          ReadingMode.values,
                          (v) => v.label,
                        ),
                        choices(
                          '图片适配',
                          'fit',
                          view.base.fit,
                          ImageFit.values,
                          (v) => v.label,
                        ),
                        toggle('裁边', 'trim', view.trim),
                        toggle('双页', 'doublePage', view.doublePage),
                        if (view.doublePage)
                          toggle('封面单页', 'soloCover', view.soloCover),
                        ...advanced(layoutKeys.contains),
                        slider(
                          '条漫自动滚动 (px/s)',
                          'autoScroll',
                          view.autoScroll,
                          0,
                          120,
                          12,
                        ),
                      ]),
                      page('general', [
                        select('触摸区域', 'tapZones', view.tapZones.name, const {
                          'directional': '按阅读方向',
                          'nextBoth': '两侧下一页',
                          'centerOnly': '只开控制栏',
                        }),
                        toggle('音量键翻页', 'volumeKeys', view.volumeKeys),
                        toggle('允许放大', 'zoom', view.zoom),
                        if (view.zoom) ...[
                          toggle('双击放大', 'doubleTapZoom', view.doubleTapZoom),
                          if (view.doubleTapZoom)
                            slider(
                              '双击倍率',
                              'doubleTapScale',
                              view.doubleTapScale,
                              1.5,
                              4,
                              5,
                              integer: false,
                            ),
                          select(
                            '缩放动画',
                            'zoomDuration',
                            view.zoomDuration.name,
                            {
                              for (final v in ZoomDurationPreset.values)
                                v.name: v.label,
                            },
                          ),
                        ],
                        ...advanced(
                          (key) => !layoutKeys.contains(key) && !colorKey(key),
                        ),
                        slider(
                          '解码缓存 (MiB)',
                          'cacheMiB',
                          view.cacheMiB.toDouble(),
                          24,
                          256,
                          29,
                        ),
                      ]),
                      page('color', [
                        choices(
                          '背景',
                          'background',
                          view.base.background,
                          ReaderBackground.values,
                          (v) => v.label,
                        ),
                        select('图像滤镜', 'filter', view.filter.name, const {
                          'none': '原图',
                          'grayscale': '灰度',
                          'invert': '反色',
                          'warm': '暖色',
                        }),
                        toggle('夜间模式', 'nightMode', view.night.enabled),
                        if (view.night.enabled) ...[
                          Wrap(
                            spacing: 6,
                            children: [
                              for (final preset in MangaNightMode.presets)
                                ChoiceChip(
                                  label: Text('$preset%'),
                                  selected: view.night.brightness == preset,
                                  onSelected: (_) =>
                                      prefs.set('nightBrightness', preset),
                                ),
                            ],
                          ),
                          slider(
                            '亮度 (%)',
                            'nightBrightness',
                            view.night.brightness.toDouble(),
                            5,
                            100,
                            19,
                          ),
                        ],
                        ...advanced(
                          (key) =>
                              colorKey(key) &&
                              (key == 'customColor' ||
                                  options.flag('customColor')),
                        ),
                      ]),
                    ],
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: prefs.reset,
                      child: const Text('恢复默认'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('完成'),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
