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
    'rotateWide': ('分页：旋转宽页', false),
    'rotateWebtoon': ('条漫：旋转宽页', false),
    'rotateCounterclockwise': ('宽页向逆时针旋转', false),
    'invertDoublePages': ('交换双页左右位置', false),
    'pageAnimation': ('点击翻页动画', true),
    'navigatePan': ('放大时优先平移', true),
    'landscapeZoom': ('自动放大宽图', false),
    'webtoonZoom': ('条漫允许捏合放大', true),
    'webtoonDoubleTap': ('条漫允许双击放大', true),
    'trimWebtoon': ('条漫裁边', false),
    'invertVolume': ('反转音量键翻页', false),
    'smallerTapZones': ('缩小点按区域', false),
    'showTapZones': ('提示点按区域', false),
    'showReadingMode': ('提示阅读方向', false),
    'showPageNumber': ('隐藏控制栏时显示页码', true),
    'fullscreen': ('全屏阅读', true),
    'cutout': ('延伸至刘海区', true),
    'keepScreenOn': ('屏幕常亮', true),
    'longPressActions': ('长按图片操作', true),
    'chapterTransition': ('显示章节过渡页', true),
    'skipRead': ('跳过已读章节', false),
    'skipDuplicates': ('跳过同编号章节', false),
    'skipFiltered': ('跳过已过滤章节', true),
    'smoothAutoScroll': ('条漫平滑自动滚动', true),
    'autoWebtoon': ('识别条漫模式', false),
    'flashPage': ('翻页闪屏', false),
    'verticalSeekbar': ('横屏使用竖向进度条', false),
    'customColor': ('自定义滤镜', false),
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
    'pageLayout': ('双页显示条件', {'width': '按可用宽度', 'landscape': '仅横屏'}),
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
    'webtoonPadding': ('条漫留白 (%)', 0, 0, 25, 25),
    'webtoonGap': ('条漫图片间距', 0, 0, 48, 12),
    'flashDuration': ('闪屏时长（毫秒）', 100, 100, 1000, 9),
    'flashInterval': ('每几页闪屏一次', 1, 1, 10, 9),
    'menuHideSeconds': ('控制栏自动隐藏 (秒)', 0, 0, 15, 15),
    'colorR': ('颜色红色分量', 255, 0, 255, 255),
    'colorG': ('颜色绿色分量', 220, 0, 255, 255),
    'colorB': ('颜色蓝色分量', 170, 0, 255, 255),
    'colorAlpha': ('颜色滤镜强度%', 15, 0, 100, 100),
  };
}
