import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';

/// 应用外壳：三档自适应导航（对齐 PROJECT_SPEC 6.2）。
///
/// - `compact`  (< 600)   底部 NavigationBar
/// - `medium`   (600~1240) NavigationRail
/// - `expanded` (> 1240)  Komikku 式 Sidebar + Content
class AdaptiveShell extends StatelessWidget {
  const AdaptiveShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const List<_ShellDestination> _destinations = <_ShellDestination>[
    _ShellDestination(
      label: '书架',
      icon: Icons.collections_bookmark_outlined,
      selectedIcon: Icons.collections_bookmark,
    ),
    _ShellDestination(
      label: '发现',
      icon: Icons.explore_outlined,
      selectedIcon: Icons.explore,
    ),
    _ShellDestination(
      label: '追番',
      icon: Icons.live_tv_outlined,
      selectedIcon: Icons.live_tv,
    ),
    _ShellDestination(
      label: '我的',
      icon: Icons.person_outline,
      selectedIcon: Icons.person,
    ),
  ];

  void _goBranch(int index) {
    // 再次点击当前分支时回到该分支的根页面，符合移动端习惯。
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final sizeClass = AppBreakpoints.of(MediaQuery.sizeOf(context).width);

    switch (sizeClass) {
      case WindowSizeClass.compact:
        return Scaffold(
          body: navigationShell,
          bottomNavigationBar: NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: _goBranch,
            destinations: <Widget>[
              for (final destination in _destinations)
                NavigationDestination(
                  icon: Icon(destination.icon),
                  selectedIcon: Icon(destination.selectedIcon),
                  label: destination.label,
                ),
            ],
          ),
        );

      case WindowSizeClass.medium:
        return Scaffold(
          body: Row(
            children: <Widget>[
              NavigationRail(
                selectedIndex: navigationShell.currentIndex,
                onDestinationSelected: _goBranch,
                destinations: <NavigationRailDestination>[
                  for (final destination in _destinations)
                    NavigationRailDestination(
                      icon: Icon(destination.icon),
                      selectedIcon: Icon(destination.selectedIcon),
                      label: Text(destination.label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: navigationShell),
            ],
          ),
        );

      case WindowSizeClass.expanded:
        return Scaffold(
          body: Row(
            children: <Widget>[
              _DesktopSidebar(
                currentIndex: navigationShell.currentIndex,
                onSelect: _goBranch,
              ),
              VerticalDivider(width: 1, color: context.palette.divider),
              Expanded(child: navigationShell),
            ],
          ),
        );
    }
  }
}

/// 桌面端侧边栏（Komikku 观感：无边框、选中项圆角高亮、底部固定设置入口）。
class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({required this.currentIndex, required this.onSelect});

  final int currentIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    return Container(
      width: AppSpacing.sidebarWidth,
      color: palette.sidebar,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.lg,
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.auto_stories_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text('Triomi', style: theme.textTheme.titleMedium),
                ],
              ),
            ),
            for (
              var index = 0;
              index < AdaptiveShell._destinations.length;
              index++
            )
              _SidebarItem(
                destination: AdaptiveShell._destinations[index],
                selected: index == currentIndex,
                onTap: () => onSelect(index),
              ),
            const Spacer(),
            _SidebarItem(
              destination: const _ShellDestination(
                label: '设置',
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings,
              ),
              selected: false,
              onTap: () => context.push(AppRoutes.settings),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text(
                'v0.1.0 · M0',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.mutedForeground,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _ShellDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;
    final foreground = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: AppRadius.controlRadius,
          child: InkWell(
            borderRadius: AppRadius.controlRadius,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs + 2,
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    selected ? destination.selectedIcon : destination.icon,
                    size: 20,
                    color: selected ? foreground : palette.mutedForeground,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    destination.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                      fontWeight: selected
                          ? AppTypography.medium
                          : AppTypography.regular,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShellDestination {
  const _ShellDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
