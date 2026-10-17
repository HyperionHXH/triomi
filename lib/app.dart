import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/settings/settings_controller.dart';

/// 应用根组件：装配主题、路由与本地化。
class TriomiApp extends ConsumerWidget {
  const TriomiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
