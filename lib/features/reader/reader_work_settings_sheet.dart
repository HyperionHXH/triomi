import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../novel/reader/novel_reader_settings.dart';
import 'reader_settings.dart';
import 'reader_work_settings.dart';

class ReaderWorkSettingsSheet extends ConsumerWidget {
  const ReaderWorkSettingsSheet({super.key, required this.workKey});
  final ReaderWorkKey workKey;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(readerWorkSettingsProvider(workKey));
    final repository = ref.read(readerWorkSettingsRepositoryProvider);
    Future<void> set(String field, Object value) =>
        repository.set(workKey, field, value);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .85,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('本作品阅读设置', style: Theme.of(context).textTheme.titleLarge),
            Text(settings.hasOverrides ? '仅影响当前作品，随备份保存' : '继承全局阅读模式/适配/背景'),
            const SizedBox(height: 12),
            Text('阅读模式', style: Theme.of(context).textTheme.titleSmall),
            Wrap(
              spacing: 8,
              children: [
                for (final mode in ReadingMode.values)
                  ChoiceChip(
                    label: Text(mode.label),
                    selected: settings.base.mode == mode,
                    onSelected: (_) => set('mode', mode.name),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text('图片适配', style: Theme.of(context).textTheme.titleSmall),
            Wrap(
              spacing: 8,
              children: [
                for (final fit in ImageFit.values)
                  ChoiceChip(
                    label: Text(fit.label),
                    selected: settings.base.fit == fit,
                    onSelected: (_) => set('fit', fit.name),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text('背景', style: Theme.of(context).textTheme.titleSmall),
            Wrap(
              spacing: 8,
              children: [
                for (final color in ReaderBackground.values)
                  ChoiceChip(
                    label: Text(color.label),
                    selected: settings.base.background == color,
                    onSelected: (_) => set('background', color.name),
                  ),
              ],
            ),
            DropdownButtonFormField<ReaderOrientation>(
              initialValue: settings.orientation,
              decoration: const InputDecoration(labelText: '屏幕方向'),
              items: [
                for (final orientation in ReaderOrientation.values)
                  DropdownMenuItem(
                    value: orientation,
                    child: Text(switch (orientation) {
                      ReaderOrientation.system => '跟随系统',
                      ReaderOrientation.portrait => '竖屏',
                      ReaderOrientation.landscape => '横屏',
                    }),
                  ),
              ],
              onChanged: (value) {
                if (value != null) set('orientation', value.name);
              },
            ),
            DropdownButtonFormField<ReaderTapZones>(
              initialValue: settings.tapZones,
              decoration: const InputDecoration(labelText: '触摸区域'),
              items: [
                const DropdownMenuItem(
                  value: ReaderTapZones.directional,
                  child: Text('按阅读方向左右翻页'),
                ),
                const DropdownMenuItem(
                  value: ReaderTapZones.nextBoth,
                  child: Text('两侧均下一页'),
                ),
                const DropdownMenuItem(
                  value: ReaderTapZones.centerOnly,
                  child: Text('点击只显示控制条'),
                ),
              ],
              onChanged: (value) {
                if (value != null) set('tapZones', value.name);
              },
            ),
            SwitchListTile(
              title: const Text('自动裁去均匀黑白边'),
              subtitle: const Text('每侧最多20%，不裁掉非均匀内容'),
              value: settings.trim,
              onChanged: (value) => set('trim', value),
            ),
            SwitchListTile(
              title: const Text('双页'),
              subtitle: const Text('宽度至少600时生效；条漫保持单列'),
              value: settings.doublePage,
              onChanged: (value) => set('doublePage', value),
            ),
            SwitchListTile(
              title: const Text('音量键翻页'),
              value: settings.volumeKeys,
              onChanged: (value) => set('volumeKeys', value),
            ),
            DropdownButtonFormField<ReaderImageFilter>(
              initialValue: settings.filter,
              decoration: const InputDecoration(labelText: '图像滤镜'),
              items: [
                for (final entry in {
                  ReaderImageFilter.none: '原图',
                  ReaderImageFilter.grayscale: '灰度',
                  ReaderImageFilter.invert: '反色',
                  ReaderImageFilter.warm: '暖色',
                }.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) {
                if (value != null) set('filter', value.name);
              },
            ),
            Text('条漫自动滚动 ${settings.autoScroll.round()} px/s；控制条显示或应用后台时暂停'),
            Slider(
              value: settings.autoScroll,
              min: 0,
              max: 120,
              divisions: 12,
              onChanged: (value) => set('autoScroll', value),
            ),
            Text('下一章预载 ${settings.preload} 张'),
            Slider(
              value: settings.preload.toDouble(),
              min: 0,
              max: 8,
              divisions: 8,
              onChanged: (value) => set('preload', value.round()),
            ),
            Text('解码图片缓存 ${settings.cacheMiB} MiB（可见图片额外占用，退出恢复原预算）'),
            Slider(
              value: settings.cacheMiB.toDouble(),
              min: 24,
              max: 256,
              divisions: 29,
              onChanged: (value) => set('cacheMiB', value.round()),
            ),
            TextButton(
              onPressed: () => repository.reset(workKey),
              child: const Text('清除此作品覆盖，恢复继承'),
            ),
          ],
        ),
      ),
    );
  }
}
