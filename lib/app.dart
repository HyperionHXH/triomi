import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/settings/privacy_lock_controller.dart';
import 'features/settings/privacy_lock_gate.dart';
import 'features/settings/settings_controller.dart';

/// 应用根组件：装配主题、路由与本地化。
class TriomiApp extends ConsumerStatefulWidget {
  const TriomiApp({super.key});

  @override
  ConsumerState<TriomiApp> createState() => _TriomiAppState();
}

class _TriomiAppState extends ConsumerState<TriomiApp> {
  late final PrivacyLockBackButtonDispatcher _backDispatcher;

  @override
  void initState() {
    super.initState();
    _backDispatcher = PrivacyLockBackButtonDispatcher(ref.read(privacyLockProvider));
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
      backButtonDispatcher: _backDispatcher,
      locale: const Locale('zh'),
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        // 界面字号只影响界面，不影响阅读器排版（阅读器有独立设置）。
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(appearance.uiFontScale)),
          child: PrivacyLockGate(child: child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}
