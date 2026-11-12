import 'package:flutter/material.dart';

import '../../core/source/ehentai/ehentai_preferences.dart';
import '../../core/source/ehentai/ehentai_source.dart';

Future<void> showEhentaiSettingsSheet(
  BuildContext context,
  EhentaiSource source,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => EhentaiSettingsSheet(source: source),
);

/// Android E-Hentai 1.6.36 preference screen, same order and texts. The three
/// login cookies are stored only in the system secure store.
class EhentaiSettingsSheet extends StatefulWidget {
  const EhentaiSettingsSheet({super.key, required this.source});
  final EhentaiSource source;
  @override
  State<EhentaiSettingsSheet> createState() => _EhentaiSettingsSheetState();
}

class _EhentaiSettingsSheetState extends State<EhentaiSettingsSheet> {
  bool _busy = false;
  String? _error;
  EhentaiPreferences get settings => widget.source.settings;

  Future<void> _save(String key, Object value) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.source.updateSetting(key, value);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = '设置未保存：${error.message}');
    } catch (error) {
      if (mounted) setState(() => _error = '设置未保存：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(
    String key,
    String title,
    String initialValue, {
    String? help,
    bool secret = false,
    bool multiline = false,
  }) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _EhentaiSettingEditor(
        initialValue: initialValue,
        title: title,
        help: help,
        secret: secret,
        multiline: multiline,
      ),
    );
    if (value != null && mounted) await _save(key, value);
  }

  Widget _choice(
    String key,
    String title,
    String value,
    Map<String, String> choices,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: DropdownButtonFormField<String>(
      key: ValueKey('ehentai-$key'),
      initialValue: choices.containsKey(value) ? value : choices.keys.first,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: title,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final entry in choices.entries)
          DropdownMenuItem(
            value: entry.key,
            child: Text(entry.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _busy
          ? null
          : (value) {
              if (value != null) _save(key, value);
            },
    ),
  );

  Widget _text(
    String key,
    String title,
    String summary,
    String value, {
    bool secret = false,
    bool multiline = false,
    String? warning,
  }) => ListTile(
    key: ValueKey('ehentai-$key'),
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(summary),
        Text(
          value.isEmpty
              ? '未填写'
              : secret
              ? '已填写（${value.length} 个字符）'
              : value,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (warning != null)
          Text(
            warning,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
    trailing: const Icon(Icons.edit_outlined),
    onTap: _busy
        ? null
        : () => _edit(
            key,
            title,
            value,
            help: summary,
            secret: secret,
            multiline: multiline,
          ),
  );

  String _pref(String key) =>
      '${settings.preferences.get<Object?>('${EhentaiPreferences.preferencePrefix}$key') ?? ''}';

  @override
  Widget build(BuildContext context) {
    const cookieHelp = '三个值必须来自同一浏览器和网络出口。';
    final proxy = settings.proxyUrl;
    final proxyError = parseEhentaiProxy(proxy).error;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .88,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            24 + MediaQuery.viewInsetsOf(context).bottom.clamp(0, double.infinity),
          ),
          children: [
            Text('E-Hentai 设置', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              settings.hasLoginCookie
                  ? '登录 Cookie 已填写（仅保存在系统安全存储，只发送到 e-hentai.org / exhentai.org）。'
                  : '未填写完整的登录 Cookie；ExHentai、收藏夹与关注标签需要三个 Cookie。',
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            _choice(
              EhentaiPrefKeys.mirror,
              'Preferred Mirror',
              '${settings.mirrorIndex}',
              {
                for (var i = 0; i < ehentaiMirrors.length; i++)
                  '$i': ehentaiMirrors[i].$1,
              },
            ),
            for (final name in EhentaiPrefKeys.loginCookies)
              _text(
                name,
                name,
                '可填写值本身，也可直接填写 $name=...；$cookieHelp',
                settings.rawCookieField(name),
                secret: true,
              ),
            _text(
              EhentaiPrefKeys.accountTagSet,
              '关注标签组编号 (Watched tag set)',
              'E-Hentai /mytags 的标签组编号，默认 1。修改后下次打开我的关注标签时立即重新同步。',
              '${settings.accountTagSetNumber}',
            ),
            _text(
              EhentaiPrefKeys.watchedIncludeTags,
              '手动追加关注标签（兼容模式）',
              '登录后自动读取账号 /mytags；这里只用于没有登录 Cookie 时的兼容搜索。多个标签用逗号分隔。',
              _pref(EhentaiPrefKeys.watchedIncludeTags),
              multiline: true,
            ),
            _text(
              EhentaiPrefKeys.watchedExcludeTags,
              '手动追加排除标签（兼容模式）',
              '登录后隐藏标签由账号 /mytags 和网站 /watched 自动处理；这里只用于兼容模式。多个标签用逗号分隔。',
              _pref(EhentaiPrefKeys.watchedExcludeTags),
              multiline: true,
            ),
            _text(
              EhentaiPrefKeys.proxyUrl,
              '代理地址 (Proxy URL)',
              '可选。留空则跟随应用代理；可填写 http://127.0.0.1:7890。'
                  'iOS 仅支持 http:// 与 https:// 代理，不支持 socks:// / socks5://。只用于 E-Hentai 请求，保存后立即生效。',
              proxy,
              warning: proxyError,
            ),
            _text(
              EhentaiPrefKeys.userAgent,
              'User-Agent',
              '默认使用浏览器 UA；若被 Cloudflare 拦截（403/503）可尝试更换',
              settings.userAgent,
            ),
            _choice(
              EhentaiPrefKeys.imageQuality,
              '图片质量 (Image quality)',
              settings.imageQuality,
              const {
                ehentaiQualityStandard: '标准图（默认）',
                ehentaiQualityOriginal: '原图',
              },
            ),
            const Text('原图需要有效登录 Cookie；获取失败时自动回退标准图'),
            SwitchListTile(
              key: const ValueKey('ehentai-pre_resolve_images'),
              contentPadding: EdgeInsets.zero,
              title: const Text('预解析图片地址'),
              subtitle: const Text('进入阅读前就解析全部图片地址；大画廊会明显变慢，默认关闭'),
              value: settings.preResolveImages,
              onChanged: _busy
                  ? null
                  : (value) => _save(EhentaiPrefKeys.preResolveImages, value),
            ),
            _choice(
              EhentaiPrefKeys.requestInterval,
              '请求间隔 (Request interval)',
              '${settings.requestIntervalMs}',
              const {
                '0': '无（默认）',
                '500': '0.5 秒',
                '1000': '1 秒',
                '2000': '2 秒',
              },
            ),
            const Text('页面类请求（列表/详情/查看页）之间的等待时间，用于避免 429；图片下载不受影响'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EhentaiSettingEditor extends StatefulWidget {
  const _EhentaiSettingEditor({
    required this.initialValue,
    required this.title,
    required this.secret,
    required this.multiline,
    this.help,
  });
  final String initialValue;
  final String title;
  final String? help;
  final bool secret;
  final bool multiline;

  @override
  State<_EhentaiSettingEditor> createState() => _EhentaiSettingEditorState();
}

class _EhentaiSettingEditorState extends State<_EhentaiSettingEditor> {
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
      obscureText: widget.secret,
      autocorrect: !widget.secret,
      enableSuggestions: !widget.secret,
      minLines: widget.multiline ? 3 : 1,
      maxLines: widget.multiline ? 6 : 1,
      decoration: InputDecoration(
        helperText: widget.secret
            ? '${widget.help ?? ''}\n留空保存即清除此 Cookie。'
            : widget.help,
        helperMaxLines: 6,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('保存'),
      ),
    ],
  );
}
