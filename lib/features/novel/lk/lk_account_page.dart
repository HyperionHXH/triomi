import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/lk_account.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/page_scaffold.dart';
import 'lk_access.dart';

/// 轻之国度账号页：资料 / 轻币余额 / 关注粉丝 + 七日签到。
class LkAccountPage extends ConsumerStatefulWidget {
  const LkAccountPage({super.key});

  @override
  ConsumerState<LkAccountPage> createState() => _LkAccountPageState();
}

class _LkAccountPageState extends ConsumerState<LkAccountPage> {
  LkProfile? _profile;
  LkSignDetail? _sign;
  bool _loading = true;
  bool _claiming = false;
  bool _notLoggedIn = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _notLoggedIn = false;
    });
    try {
      final source = await loadLkAccount(ref);
      if (!source.isLoggedIn) {
        if (!mounted) return;
        setState(() {
          _notLoggedIn = true;
          _loading = false;
        });
        return;
      }
      final profile = await source.profile();
      final sign = await source.signDetail();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _sign = sign;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeSourceError(error);
        _loading = false;
      });
    }
  }

  Future<void> _claim() async {
    setState(() => _claiming = true);
    try {
      final source = await loadLkAccount(ref);
      await source.claimSign();
      // 余额与连续天数以站点返回为准，签完重新拉一次。
      await _load();
      if (mounted) _toast('签到成功，轻币已到账');
    } catch (error) {
      if (mounted) _toast('签到失败：${describeSourceError(error)}');
    } finally {
      if (mounted) setState(() => _claiming = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '轻之国度',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh),
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
        title: '还没有登录轻之国度',
        message: '登录后可以查看轻币余额、七日签到与站点消息。',
        action: FilledButton.icon(
          onPressed: () => context.push(AppRoutes.sources),
          icon: const Icon(Icons.login, size: 18),
          label: const Text('去登录'),
        ),
      );
    }
    if (_error != null) {
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
    final sign = _sign;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: <Widget>[
          if (profile != null) _profileCard(profile),
          if (sign != null) _signCard(sign),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 资料

  Widget _profileCard(LkProfile profile) {
    final theme = Theme.of(context);
    final palette = context.palette;
    final avatarUrl = profile.avatarUrl;
    final subtitle = <String>[
      'UID ${profile.uid}',
      if (profile.levelName.isNotEmpty) profile.levelName,
    ].join(' · ');

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
                  foregroundImage: avatarUrl == null
                      ? null
                      : NetworkImage(avatarUrl),
                  child: const Icon(Icons.person_outline),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        profile.nickname,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.mutedForeground,
                        ),
                      ),
                      if (profile.signature.isNotEmpty) ...<Widget>[
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          profile.signature,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                _stat('轻币', '${profile.coin}', highlight: true),
                _stat('关注', _countLabel(profile.followingCount)),
                _stat('粉丝', _countLabel(profile.fansCount)),
                _stat('发布', _countLabel(profile.postCount)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _countLabel(int? value) => value == null ? '—' : '$value';

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

  // ---------------------------------------------------------------- 签到

  Widget _signCard(LkSignDetail sign) {
    final theme = Theme.of(context);
    final palette = context.palette;
    final claimedToday = sign.claimed || !sign.hasClaimable;
    final progressText = sign.subtitle.isNotEmpty
        ? sign.subtitle
        : '连续签到 ${sign.progress}/${sign.totalProgress} 天';

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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(sign.title, style: theme.textTheme.titleSmall),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        progressText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '第 ${sign.currentDay} 天',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.mutedForeground,
                  ),
                ),
              ],
            ),
            if (sign.days.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: <Widget>[
                  for (final day in sign.days) _signDayChip(day),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (!claimedToday && !_claiming) ? _claim : null,
                icon: _claiming
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.card_giftcard, size: 18),
                label: Text(claimedToday ? '今日已签到' : '领取今日签到'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _signDayChip(LkSignDay day) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = day.claimed;
    final ready = day.claimable && !done;
    final background = done
        ? scheme.primaryContainer
        : ready
        ? scheme.tertiaryContainer
        : context.palette.coverPlaceholder;
    final foreground = done
        ? scheme.onPrimaryContainer
        : ready
        ? scheme.onTertiaryContainer
        : context.palette.mutedForeground;

    return Container(
      width: 62,
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.xs,
        horizontal: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: AppRadius.controlRadius,
      ),
      child: Column(
        children: <Widget>[
          Text(
            '第${day.day}天',
            style: theme.textTheme.bodySmall?.copyWith(color: foreground),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            done ? '已领' : '+${day.rewardAmount}',
            style: theme.textTheme.titleSmall?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}
