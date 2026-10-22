import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/source_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/page_scaffold.dart';
import '../data/lns/lns_gateway.dart';
import 'lns_access.dart';

/// 轻书架账号页：资料（轻币 / 连续签到）+ 每日签到。
///
/// 轻书架的账号域只有这两项（站点没有关注 / 粉丝 / 消息），
/// 所以不与轻之国度共用页面，避免出现站点根本没有的入口。
class LnsAccountPage extends ConsumerStatefulWidget {
  const LnsAccountPage({super.key});

  @override
  ConsumerState<LnsAccountPage> createState() => _LnsAccountPageState();
}

class _LnsAccountPageState extends ConsumerState<LnsAccountPage> {
  LnsProfile? _profile;
  bool _loading = true;
  bool _claiming = false;
  bool _claimSucceeded = false;
  bool _notLoggedIn = false;
  String? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = _profile == null;
      _error = null;
      _notLoggedIn = false;
    });
    try {
      final source = await loadLnsSource(ref);
      if (!source.isLoggedIn) {
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          _notLoggedIn = true;
          _loading = false;
        });
        return;
      }
      final profile = await source.profile();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _profile = profile;
        _claimSucceeded = profile.signedToday;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = _describe(error);
        _loading = false;
      });
    }
  }

  Future<void> _claim() async {
    if (_claiming || _claimSucceeded) return;
    final generation = ++_loadGeneration;
    setState(() => _claiming = true);
    try {
      final source = await loadLnsSource(ref);
      final result = await source.claimSign();
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _claimSucceeded = true);
      if (result.profile case final profile?) {
        setState(() {
          _profile = profile;
          _error = null;
        });
      }
      final rewards = <String>[
        if (result.reward != null) '${result.reward} 轻币',
        if (result.experienceReward != null) '${result.experienceReward} 经验',
      ];
      _toast(
        result.profile == null
            ? '签到成功，资料刷新失败，请刷新确认余额与经验'
            : rewards.isEmpty
            ? '签到成功，资料已同步'
            : '签到成功，获得 ${rewards.join('、')}',
      );
    } catch (error) {
      if (mounted) _toast('签到失败：${_describe(error)}');
    } finally {
      if (mounted) setState(() => _claiming = false);
    }
  }

  String _describe(Object error) =>
      error is SourceException ? error.userMessage : '$error';

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _manageAccount() async {
    _loadGeneration++;
    await context.push('${AppRoutes.sources}?type=novel');
    if (!mounted) return;
    setState(() {
      _profile = null;
      _claimSucceeded = false;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '轻书架',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: '账号登录与退出',
          onPressed: _manageAccount,
          icon: const Icon(Icons.manage_accounts_outlined),
        ),
      ],
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_notLoggedIn) {
      return EmptyStateView(
        icon: Icons.person_off_outlined,
        title: '还没有登录轻书架',
        message: '登录后可以查看轻币余额与每日签到。',
        action: FilledButton.icon(
          onPressed: _manageAccount,
          icon: const Icon(Icons.login, size: 18),
          label: const Text('去登录'),
        ),
      );
    }
    if (_error != null && _profile == null) {
      return EmptyStateView(
        icon: Icons.cloud_off_outlined,
        title: '资料加载失败',
        message: _error,
        action: OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('重试'),
        ),
      );
    }
    final profile = _profile;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: <Widget>[
          if (_error != null)
            ListTile(
              title: Text('资料刷新失败：$_error'),
              trailing: TextButton(onPressed: _load, child: const Text('重试')),
            ),
          if (profile != null) _profileCard(profile),
          if (profile != null) _signCard(profile),
        ],
      ),
    );
  }

  Widget _profileCard(LnsProfile profile) {
    final theme = Theme.of(context);
    final palette = context.palette;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        0,
      ),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 28,
                  backgroundColor: palette.coverPlaceholder,
                  child: const Icon(Icons.person_outline),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        profile.userName.isEmpty ? '轻书架用户' : profile.userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        'UID ${profile.id}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                _stat('轻币', '${profile.coin}', highlight: true),
                _stat('连续签到', '${profile.signInStreak} 天'),
                if (profile.experience != null)
                  _stat('经验', '${profile.experience}'),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '成长等级 ${profile.growthLevel == null ? '未提供' : 'Lv.${profile.growthLevel}'}'
              ' · 访问等级 ${profile.level == null ? '未提供' : 'Lv.${profile.level}'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              profile.experience == null
                  ? '来源未提供经验数据'
                  : profile.maxLevel
                  ? '累计经验 ${profile.experience} · 已达最高等级'
                  : '累计经验 ${profile.experience}'
                        '${profile.nextLevelExp == null ? ' · 来源未提供升级门槛' : ' · 下一级 ${profile.nextLevelExp}'}',
              style: theme.textTheme.bodySmall,
            ),
            if (profile.experienceFraction case final fraction?) ...[
              const SizedBox(height: AppSpacing.xs),
              LinearProgressIndicator(value: fraction),
            ],
            const SizedBox(height: AppSpacing.xs),
            Text(
              '每日签到累积经验，连签有额外奖励；实际奖励以来源资料为准。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value, {bool highlight = false}) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: <Widget>[
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              color: highlight ? theme.colorScheme.primary : null,
            ),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: context.palette.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }

  Widget _signCard(LnsProfile profile) {
    final theme = Theme.of(context);
    final palette = context.palette;
    final signedToday = profile.signedToday || _claimSucceeded;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        0,
      ),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('每日签到', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              signedToday ? '今天已经签过了' : '连续签到 ${profile.signInStreak} 天，签到可得轻币',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.mutedForeground,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (!signedToday && !_claiming) ? _claim : null,
                icon: _claiming
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.card_giftcard, size: 18),
                label: Text(signedToday ? '今日已签到' : '领取今日签到'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
