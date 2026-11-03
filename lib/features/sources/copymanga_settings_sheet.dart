import 'package:flutter/material.dart';

import '../../core/source/copymanga/copymanga_js_source.dart';
import '../../core/source/copymanga/copymanga_preferences.dart';

Future<void> showCopyMangaSettingsSheet(
  BuildContext context,
  CopyMangaJsSource source,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => CopyMangaSettingsSheet(source: source),
);

/// Android 1.4.85's Copy settings, with credentials kept in the account dialog.
class CopyMangaSettingsSheet extends StatefulWidget {
  const CopyMangaSettingsSheet({super.key, required this.source});
  final CopyMangaJsSource source;
  @override
  State<CopyMangaSettingsSheet> createState() => _CopyMangaSettingsSheetState();
}

class _CopyMangaSettingsSheetState extends State<CopyMangaSettingsSheet> {
  bool _busy = false;
  String? _error;
  Map<String, String> _themes = {'': '全部'};
  CopyMangaPreferences get settings => widget.source.settings;

  Future<void> _save(String key, Object value) async {
    setState(() { _busy = true; _error = null; });
    try {
      await widget.source.updateSetting(key, value);
    } catch (error) {
      if (mounted) setState(() => _error = '设置未保存：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );

  Widget _choice(String key, String label, Map<String, String> choices, {String? help}) {
    final value = settings.value(key) as String;
    final entries = {...choices, if (!choices.containsKey(value)) value: value};
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: DropdownButtonFormField<String>(
        key: ValueKey('copymanga-$key'),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, helperText: help, helperMaxLines: 4,
          border: const OutlineInputBorder()),
        items: [for (final entry in entries.entries)
          DropdownMenuItem(value: entry.key,
            child: Text(entry.value, overflow: TextOverflow.ellipsis))],
        onChanged: _busy ? null : (value) { if (value != null) _save(key, value); },
      ),
    );
  }

  Widget _toggle(String key, String title, String subtitle) => SwitchListTile(
    key: ValueKey('copymanga-$key'),
    contentPadding: EdgeInsets.zero,
    title: Text(title), subtitle: Text(subtitle),
    value: settings.value(key) as bool,
    onChanged: _busy ? null : (value) => _save(key, value),
  );

  Future<void> _edit(String key, String title, {String? help, bool multiline = false}) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _CopySettingEditor(
        initialValue: settings.value(key) as String,
        title: title,
        help: help,
        multiline: multiline,
      ),
    );
    if (value != null && mounted) await _save(key, value);
  }

  Future<void> _refreshThemes() async {
    setState(() { _busy = true; _error = null; });
    try {
      final tags = await widget.source.searchTags();
      if (mounted) setState(() => _themes = {'': '全部', for (final tag in tags) tag.id: tag.label});
    } catch (error) {
      if (mounted) setState(() => _error = '主题获取失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _websiteLogin() async {
    setState(() { _busy = true; _error = null; });
    try {
      final saved = await widget.source.openWebsiteSession();
      if (mounted && saved) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('网站会话已验证并安全保存')));
      }
    } catch (error) {
      if (mounted) setState(() => _error = '网站登录未完成：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .88,
      child: ListView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(context).bottom.clamp(0, double.infinity)),
        children: [
          Text('拷贝漫画设置', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('对应 Android 拷贝漫画 1.4.85 的 Copy 服务。更改只影响新请求；'
            '已下载内容不改写。评论和图片设置变更后，已缓存章节需在缓存管理中清理并重新打开。'),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          _heading('线路与显示'),
          _choice('apiDomain', '官方 API 线路', {
            for (final entry in copyMangaApiDomains.entries) entry.key: '${entry.value} · ${entry.key}',
          }, help: '仅支持官方 Copy 线路；账号会话按所选 API 主机隔离，不向图片或跳转站点发送。'),
          _choice('webDomain', '网站链接', {
            for (final entry in copyMangaWebDomains.entries) entry.key: '${entry.value} · ${entry.key}',
          }, help: '仅改变“打开网站”目标；书架与章节标识保持不变。'),
          _choice('platform', '平台参数', {'': '无（省略 Header）', ' ': '空格',
            '1': '1（默认）', '2': '2', '3': '3', '4': '4', '5': '5'}),
          _choice('resolution', '图片分辨率', {'800': '800', '1200': '1200', '1500': '1500'},
            help: '默认 1500 像素。修改后新请求的图片地址生效，离线文件保持原状。'),
          _choice('latestMode', '最新更新列表', {'updated': '近期更新（默认）', 'new': '最新入库'}),
          _choice('languageConversion', '简繁设置', {'off': '原文（默认）', 't2s': '简体', 's2t': '繁體'},
            help: '使用应用现有 OpenCC 字表转换作品、章节与原生评论文字，不改写标识或搜索条件。'),
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('User-Agent'),
            subtitle: Text(settings.value('userAgent') as String, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.edit_outlined),
            onTap: _busy ? null : () => _edit('userAgent', 'User-Agent',
              help: '默认 Firefox 114。支持 reset / desktop / mobile / app / none；留空或换行不会保存。')),
          Wrap(spacing: 8, children: [
            for (final command in const {'reset': '恢复默认', 'desktop': '随机桌面', 'mobile': '随机移动',
              'app': '应用默认', 'none': '禁用 UA'}.entries)
              ActionChip(label: Text(command.value),
                onPressed: _busy ? null : () => _save('userAgent', command.key)),
          ]),
          const Text('随机模式使用 Android 插件相同的公开 UA 列表和离线默认值；'
            'app 使用应用网络默认 UA；none 不发送 API / 图片 User-Agent。网站登录窗口仍使用系统浏览器默认 UA。'),
          _heading('可选账号'),
          Text(widget.source.isLoggedIn
            ? '当前线路已登录：${widget.source.accountName ?? ''}'
            : '当前线路未登录；匿名搜索、目录与公开章节仍可使用。'),
          const Text('使用来源卡片的“账号”入口登录或退出。密码不保存；会话只存系统安全存储，不进入规则、备份或 JS。'),
          _toggle('enableLogin', '启用登录状态浏览', '关闭时保留安全会话但所有请求按游客发送。退出账号会清除所有 Copy 线路的本机会话。'),
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.public),
            title: const Text('通过官方网站登录'),
            subtitle: const Text('在原生浏览器登录后明确选择“保存会话”。只读取所选官网的 token Cookie，'
              '在所选 API 验证后移至安全存储；仅 localStorage / 请求头登录的网站请使用账号密码入口。'),
            onTap: _busy ? null : _websiteLogin),
          _heading('搜索筛选'),
          _choice('qType', '搜索类型', {'': '全部', 'name': '名称', 'author': '作者', 'local': '汉化组'}),
          _choice('rank', '排行榜', {'': '不查看', 'day': '日榜（上升最快）', 'week': '周榜（最近 7 天）',
            'month': '月榜（最近 30 天）', 'total': '总榜单'}, help: '关键词为空时使用榜单或受众筛选；填写关键词后按搜索类型查询。'),
          _choice('audience', '受众类型', {'': '默认（男频，不切换榜单）', 'male': '男频榜单', 'female': '女频榜单'}),
          _choice('ordering', '排序方式', {'-datetime_updated': '更新时间 · 新→旧（默认）',
            'datetime_updated': '更新时间 · 旧→新', '-popular': '热门 · 高→低', 'popular': '热门 · 低→高'}),
          _choice('region', '地区 / 状态', {'': '全部', 'japan': '日本', 'korea': '韩国', 'west': '欧美', 'finish': '已完结'}),
          _choice('theme', '主题', _themes),
          Align(alignment: Alignment.centerLeft, child: TextButton.icon(
            onPressed: _busy ? null : _refreshThemes, icon: const Icon(Icons.refresh), label: const Text('从站点刷新主题标签'))),
          _choice('freeType', '免费 / 付费参数', {'': '全部', '1': '免费', '2': '付费'},
            help: '按 Android 请求协议发送 free_type；Copy 站点是否使用此参数由服务端决定，不解锁付费内容。'),
          _toggle('collect', '读取源站收藏', '关键词为空时只读获取当前线路账号的收藏。需要已登录并启用登录浏览；不会写入远端书架。'),
          _heading('章节与评论'),
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('隐藏指定章节'),
            subtitle: Text((settings.value('hideChapters') as String).isEmpty
              ? '未隐藏。每行一个准确章节名；按站点原文匹配，适用于所有分组。'
              : settings.value('hideChapters') as String),
            trailing: const Icon(Icons.edit_outlined),
            onTap: _busy ? null : () => _edit('hideChapters', '隐藏指定章节', multiline: true,
              help: '每行一个准确章节名，例如第01话；匹配原始简繁文字，不是作品名。')),
          _toggle('showMangaComments', '显示漫画总评', '在目录中加入原生“漫画评论”章节；会读取站点全部评论，可能增加请求时间。'),
          _toggle('showChapterComments', '章末吐槽页', '章节图片之后以原生文字显示评论；不生成假图片地址。'),
          _choice('commentMode', '章末吐槽格式', {'separate': '分页（适合手机）', 'merge': '合并（适合平板）'}),
          _toggle('reverseChapterComments', '倒序展开评论', '将新→旧顺序更改为旧→新。'),
          _choice('commentApiDomain', '章节吐槽 API 线路', {
            for (final entry in copyMangaApiDomains.entries) entry.key: '${entry.value} · ${entry.key}',
          }, help: '与漫画 API 独立选择。只有与当前账号 API 完全相同的主机才会收到登录凭据。'),
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('吐槽正则屏蔽'),
            subtitle: Text((settings.value('commentRegex') as String).isEmpty
              ? '每行一个正则；匹配评论正文任意部分即屏蔽。空行忽略，留空关闭。'
              : settings.value('commentRegex') as String),
            trailing: const Icon(Icons.edit_outlined),
            onTap: _busy ? null : () => _edit('commentRegex', '吐槽正则屏蔽', multiline: true,
              help: '例如：广告|引战。无效正则不会保存。适用于漫画总评与章末吐槽。')),
          const SizedBox(height: 12),
          FilledButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('完成')),
        ],
      ),
    ),
  );
}

class _CopySettingEditor extends StatefulWidget {
  const _CopySettingEditor({required this.initialValue, required this.title, this.help, required this.multiline});
  final String initialValue;
  final String title;
  final String? help;
  final bool multiline;

  @override
  State<_CopySettingEditor> createState() => _CopySettingEditorState();
}

class _CopySettingEditorState extends State<_CopySettingEditor> {
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      minLines: widget.multiline ? 4 : 1,
      maxLines: widget.multiline ? 8 : 1,
      decoration: InputDecoration(helperText: widget.help, helperMaxLines: 6),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: () => Navigator.pop(context, _controller.text), child: const Text('保存')),
    ],
  );
}
