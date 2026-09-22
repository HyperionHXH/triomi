import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';

/// 发现页：来源榜单 + 全局搜索。
///
/// M1 接入规则引擎后，这里会变成「源选择器 + 榜单列表」；
/// 搜索走聚合搜索（并行查询全部可搜索来源，逐源返回成功或错误）。
class DiscoverPage extends StatelessWidget {
  const DiscoverPage({super.key});

  void _showComingSoon(BuildContext context, String feature) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$feature 将在 M1 接入规则引擎后开放')));
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '发现',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: TextField(
              readOnly: true,
              onTap: () => _showComingSoon(context, '搜索'),
              decoration: const InputDecoration(
                hintText: '搜索番剧 / 漫画 / 小说',
                prefixIcon: Icon(Icons.search, size: 20),
              ),
            ),
          ),
          const Expanded(
            child: EmptyStateView(
              icon: Icons.travel_explore_outlined,
              title: '还没有可用的来源',
              message: '添加来源规则后，各站的榜单与搜索结果会在这里按来源分组展示。',
            ),
          ),
        ],
      ),
    );
  }
}
