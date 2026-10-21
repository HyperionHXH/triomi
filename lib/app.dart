import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/storage/preferences.dart';
import 'core/theme/app_theme.dart';
import 'features/settings/app_update_page.dart';
import 'features/settings/app_update_service.dart';
import 'features/settings/app_update_widgets.dart';
import 'features/settings/settings_controller.dart';

/// 应用根组件：装配主题、路由与本地化。
class TriomiApp extends ConsumerStatefulWidget {
  const TriomiApp({super.key});

  @override
  ConsumerState<TriomiApp> createState() => _TriomiAppState();
}

class _TriomiAppState extends ConsumerState<TriomiApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkForStartupUpdate());
    });
  }

  Future<void> _checkForStartupUpdate() async {
    if (kDebugMode ||
        kIsWeb ||
        !{
          TargetPlatform.android,
          TargetPlatform.windows,
        }.contains(defaultTargetPlatform)) {
      return;
    }
    if (!mounted) return;

    final service = AppUpdateService();
    final cancellation = AppUpdateCancellation();
    try {
      final current = await service.current();
      final releases = await service.releases(cancellation);
      cancellation.check();
      final update = newestAppUpdateRelease(current, releases);
      if (!mounted || update == null) return;
      final dismissedTag = ref
          .read(preferencesProvider)
          .get<String>('app-update.dismissed.${current.platform}');
      if (dismissedTag == update.tag) return;
      final navigatorContext = AppRouter.rootNavigator?.context;
      if (navigatorContext == null || !navigatorContext.mounted) return;
      final shouldOpen = await showStartupUpdateDialog(
        navigatorContext,
        release: update,
        windows: current.platform == 'windows',
      );
      if (!mounted) return;
      if (shouldOpen == true) {
        unawaited(
          AppRouter.rootNavigator
              ?.push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => AppUpdatePage(initialRelease: update),
                ),
              )
              .then<void>((_) {}),
        );
      } else if (shouldOpen == false) {
        await ref
            .read(preferencesProvider)
            .set('app-update.dismissed.${current.platform}', update.tag);
      }
    } catch (_) {
      // A startup network failure must not block or interrupt the home screen.
    } finally {
      service.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final appearance = ref.watch(appearanceProvider);
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Triomi',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(
        accent: appearance.accentPalette,
        covers: appearance.coverAppearance,
      ),
      darkTheme: AppTheme.dark(
        accent: appearance.accentPalette,
        covers: appearance.coverAppearance,
      ),
      themeMode: appearance.themeMode,
      routeInformationProvider: router.routeInformationProvider,
      routeInformationParser: router.routeInformationParser,
      routerDelegate: router.routerDelegate,
      locale: const Locale('zh'),
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
