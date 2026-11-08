import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/storage/preferences.dart';
import 'core/theme/app_theme.dart';
import 'features/library/data/library_auto_sync.dart';
import 'features/settings/app_update_page.dart';
import 'features/settings/app_update_service.dart';
import 'features/settings/app_update_widgets.dart';
import 'features/settings/onboarding_controller.dart';
import 'features/settings/onboarding_page.dart';
import 'features/settings/settings_controller.dart';

/// 应用根组件：装配主题、路由与本地化。
class TriomiApp extends ConsumerStatefulWidget {
  const TriomiApp({super.key});

  @override
  ConsumerState<TriomiApp> createState() => _TriomiAppState();
}

class _TriomiAppState extends ConsumerState<TriomiApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_runStartup());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    final sync = ref.read(libraryAutoSyncProvider.notifier);
    if (lifecycle == AppLifecycleState.resumed) {
      sync.onResumed();
    } else if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached ||
        lifecycle == AppLifecycleState.hidden) {
      sync.onPaused();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _runStartup() async {
    if (ref.read(onboardingProvider)) {
      final navigator = AppRouter.rootNavigator;
      if (navigator != null) {
        await navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const OnboardingPage(firstRun: true),
          ),
        );
      }
    }
    if (!mounted) return;
    ref.read(libraryAutoSyncProvider.notifier).onResumed();
    await _checkForStartupUpdate();
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

    try {
      final preferences = ref.read(preferencesProvider);
      final result = await checkStartupAppUpdate(preferences);
      if (!mounted ||
          result == null ||
          !ref.read(preferencesProvider).automaticAppUpdateCheckEnabled) {
        return;
      }
      final current = result.current;
      final update = result.release;
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
      builder: (context, child) {
        final media = MediaQuery.of(context);
        if (media.viewInsets.isNonNegative) return child!;
        // iOS keyboard dismissal can briefly report an out-of-view frame.
        // Normalize once above both Navigator dialogs and Scaffold snackbars;
        // positive keyboard avoidance and all other system metrics stay intact.
        final insets = media.viewInsets.clamp(
          EdgeInsets.zero,
          EdgeInsetsGeometry.infinity,
        ) as EdgeInsets;
        return MediaQuery(
          data: media.copyWith(
            viewInsets: insets,
            padding: (media.viewPadding - insets).clamp(
              EdgeInsets.zero,
              EdgeInsetsGeometry.infinity,
            ) as EdgeInsets,
          ),
          child: child!,
        );
      },
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
