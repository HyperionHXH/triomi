import 'package:flutter/material.dart';

/// Global reader controls. Stored alongside existing reader.manga preferences.
class MangaReaderOptions {
  const MangaReaderOptions([this.values = const {}]);
  final Map<String, Object?> values;
  bool flag(String key) =>
      values[key] is bool ? values[key] as bool : switches[key]?.$2 ?? false;
  double number(String key, double fallback, double min, double max) {
    final value = values[key];
    return value is num && value.isFinite
        ? value.toDouble().clamp(min, max)
        : fallback;
  }

  String choice(String key, List<String> allowed) =>
      allowed.contains(values[key]) ? values[key] as String : allowed.first;
  static const switches = <String, (String, bool)>{
    'splitWide': ('分页：自动拆分宽页', false),
    'splitWebtoon': ('条漫：自动拆分宽页', false),
    'reverseSplit': ('交换宽页左右半页顺序', false),
    'rotateWide': ('分页：宽页旋转适配（不拆分时）', false),
    'rotateWebtoon': ('条漫：宽页旋转适配（不拆分时）', false),
    'rotateCounterclockwise': ('宽页向逆时针旋转', false),
    'invertDoublePages': ('交换双页左右位置', false),
    'pageAnimation': ('点击翻页动画', true),
    'navigatePan': ('放大时点按先平移，到边界再翻页', true),
    'landscapeZoom': ('横向宽图自动放大浏览', false),
    'webtoonZoom': ('条漫允许捏合放大', true),
    'webtoonDoubleTap': ('条漫允许双击放大', true),
    'trimWebtoon': ('条漫独立裁去均匀黑白边', false),
    'invertVolume': ('反转音量键翻页', false),
    'smallerTapZones': ('缩小侧边点按区域（25%）', false),
    'showTapZones': ('进入阅读时显示点按区域', false),
    'showReadingMode': ('进入阅读时显示阅读方向', false),
    'showPageNumber': ('隐藏控制栏时显示页码', true),
    'fullscreen': ('全屏阅读', true),
    'cutout': ('允许画面延伸到刘海区域', true),
    'keepScreenOn': ('漫画阅读时保持屏幕常亮', true),
    'longPressActions': ('长按图片显示操作', true),
    'chapterTransition': ('显示章节过渡页', true),
    'skipRead': ('连续阅读时跳过已读章节', false),
    'skipDuplicates': ('连续阅读时跳过相同编号章节', false),
    'skipFiltered': ('连续阅读时跳过目录已过滤章节', true),
    'smoothAutoScroll': ('条漫平滑自动滚动', true),
    'autoWebtoon': ('来源明确标注条漫时自动使用条漫', false),
    'flashPage': ('翻页闪屏（电子墨水屏，默认关闭）', false),
    'verticalSeekbar': ('横屏使用竖向进度条', false),
    'customColor': ('自定义画面颜色滤镜（不改变夜间模式）', false),
    'leftSeekbar': ('竖向进度条位于左侧', false),
  };
  static const choices = <String, (String, Map<String, String>)>{
    'chapterFilter': (
      '章节目录筛选',
      {'all': '全部章节', 'unread': '仅未读章节', 'read': '仅已读章节'},
    ),
    'zoomStart': (
      '放大起点',
      {'auto': '按阅读方向', 'left': '左侧', 'right': '右侧', 'center': '中心'},
    ),
    'wideZoomType': ('宽图自动放大方式', {'double': '两倍', 'height': '适应屏幕高度'}),
    'pageLayout': ('双页布局（开启双页后）', {'width': '按可用宽度', 'landscape': '仅横屏'}),
    'tapInvert': (
      '反转点按区域',
      {'none': '不反转', 'horizontal': '水平', 'vertical': '垂直', 'both': '水平和垂直'},
    ),
    'tapLayout': (
      '点按导航布局',
      {
        'existing': '现有左右区域',
        'l': 'L形',
        'kindle': '顶部菜单/左后右前',
        'edge': '边缘前进/底部后退',
        'disabled': '仅呼出菜单',
      },
    ),
    'centerMargin': ('双页中央间距', {'none': '无', 'small': '窄', 'large': '宽'}),
    'webtoonWidth': (
      '条漫画面宽度',
      {
        'fit': '适应宽度',
        '4:3': '4:3显示区',
        '3:2': '3:2显示区',
        '16:9': '16:9显示区',
        '20:9': '20:9显示区',
      },
    ),
    'hideOnScroll': ('滚动隐藏菜单灵敏度', {'off': '不自动隐藏', 'high': '高', 'low': '低'}),
    'flashColor': ('闪屏颜色', {'black': '黑', 'white': '白', 'alternate': '黑白交替'}),
    'imageScale': (
      '图像高级适配',
      {'base': '使用图片适配设置', 'stretch': '拉伸铺满', 'smart': '智能适配'},
    ),
    'colorBlend': (
      '颜色滤镜混合',
      {'over': '覆盖', 'multiply': '正片叠底', 'screen': '滤色'},
    ),
  };
  static const sliders = <String, (String, double, double, double, int)>{
    'webtoonPadding': ('条漫左右留白（每侧%）', 0, 0, 25, 25),
    'webtoonGap': ('条漫图片间距', 0, 0, 48, 12),
    'flashDuration': ('闪屏时长（毫秒）', 100, 100, 1000, 9),
    'flashInterval': ('每几页闪屏一次', 1, 1, 10, 9),
    'menuHideSeconds': ('控制栏自动隐藏（秒，0不自动隐藏）', 0, 0, 15, 15),
    'colorR': ('颜色红色分量', 255, 0, 255, 255),
    'colorG': ('颜色绿色分量', 220, 0, 255, 255),
    'colorB': ('颜色蓝色分量', 170, 0, 255, 255),
    'colorAlpha': ('颜色滤镜强度%', 15, 0, 100, 100),
  };
}

class MangaReaderOptionsSection extends StatelessWidget {
  const MangaReaderOptionsSection({
    super.key,
    required this.options,
    required this.save,
  });
  final MangaReaderOptions options;
  final Future<void> Function(String, Object) save;
  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: const Text('更多阅读操作（Komikku）'),
    subtitle: const Text('全局生效；分页/条漫专用项按当前模式应用'),
    children: [
      for (final entry in MangaReaderOptions.switches.entries)
        SwitchListTile(
          title: Text(entry.value.$1),
          value: options.flag(entry.key),
          onChanged: (v) => save(entry.key, v),
        ),
      for (final entry in MangaReaderOptions.choices.entries)
        Padding(
          padding: const EdgeInsets.all(8),
          child: DropdownButtonFormField<String>(
            initialValue: options.choice(
              entry.key,
              entry.value.$2.keys.toList(),
            ),
            decoration: InputDecoration(labelText: entry.value.$1),
            items: [
              for (final v in entry.value.$2.entries)
                DropdownMenuItem(value: v.key, child: Text(v.value)),
            ],
            onChanged: (v) {
              if (v != null) save(entry.key, v);
            },
          ),
        ),
      for (final entry in MangaReaderOptions.sliders.entries) ...[
        Text(
          '${entry.value.$1}：${options.number(entry.key, entry.value.$2, entry.value.$3, entry.value.$4).round()}',
        ),
        Slider(
          value: options.number(
            entry.key,
            entry.value.$2,
            entry.value.$3,
            entry.value.$4,
          ),
          min: entry.value.$3,
          max: entry.value.$4,
          divisions: entry.value.$5,
          onChanged: (v) => save(entry.key, v),
        ),
      ],
    ],
  );
}
