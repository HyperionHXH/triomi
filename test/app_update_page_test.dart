import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/settings/app_update_page.dart';
import 'package:triomi/features/settings/app_update_service.dart';
import 'package:triomi/features/settings/app_update_widgets.dart';

const _hash =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _signer =
    '2222222222222222222222222222222222222222222222222222222222222222';

AppUpdateInfo _info(int code, {String platform = 'android'}) => AppUpdateInfo(
  packageName: 'io.github.hyperionhxh.triomi',
  versionCode: code,
  version: '0.11.0',
  sha256: _hash,
  signerSha256: platform == 'android' ? _signer : null,
  platform: platform,
);

List<AppUpdateRelease> _releases(
  List<int> codes, {
  Set<int> missing = const {},
  String platform = 'android',
}) => AppUpdateRelease.parse(
  utf8.encode(
    jsonEncode([
      for (final code in codes)
        {
          'tag_name': 'v0.11.0-test.$code',
          'name': 'Triomi $code',
          'draft': false,
          'prerelease': true,
          'published_at': '2026-10-18T10:00:00Z',
          'body': 'Release $code\n\n- Keep the complete release notes.',
          'assets': [
            if (!missing.contains(code))
              for (final name
                  in platform == 'android'
                      ? ['triomi-android.apk']
                      : ['triomi-windows.zip', 'triomi-windows.update.json'])
                {
                  'name': name,
                  'state': 'uploaded',
                  'size': 1024,
                  'digest': 'sha256:$_hash',
                  'browser_download_url':
                      'https://github.com/HyperionHXH/triomi/releases/download/v0.11.0-test.$code/$name',
                },
          ],
        },
    ]),
  ),
);

class _UpdateService extends AppUpdateService {
  _UpdateService({this.platform = 'android', List<AppUpdateRelease>? available})
    : available = available ?? _releases([163, 159]);

  final String platform;
  List<AppUpdateRelease> available;
  Future<AppUpdateInfo>? currentResult;
  Future<bool>? permissionResult;
  Future<void>? launchResult;
  Future<AppUpdateCandidate> Function(AppUpdateRelease, AppUpdateCancellation)?
  download;
  final downloaded = <int>[];
  final discarded = <AppUpdateCandidate>[];
  final handedOff = <AppUpdateCandidate>[];
  final tokens = <AppUpdateCancellation>[];
  int checks = 0,
      currentReads = 0,
      cancellations = 0,
      permissionReads = 0,
      settingsOpened = 0;
  bool allowed = true, failNextCheck = false, unsupportedCurrent = false;

  AppUpdateCandidate candidate(int code) => AppUpdateCandidate(
    current: _info(162, platform: platform),
    offered: _info(code, platform: platform),
    path: '/owned/stage/update',
    bytes: 1024,
    source: 'Official release',
    decision: 'upgrade',
    signatureVerified: platform == 'android',
    manifestPath: platform == 'windows' ? '/owned/stage/manifest.json' : null,
  );

  @override
  void attachProgress() {}
  @override
  Future<AppUpdateInfo> current() async {
    currentReads++;
    if (unsupportedCurrent) {
      throw UnsupportedError('No application updater on this runtime');
    }
    if (currentResult != null) return currentResult!;
    return _info(162, platform: platform);
  }

  @override
  Future<List<AppUpdateRelease>> releases(AppUpdateCancellation token) async {
    checks++;
    if (failNextCheck) {
      failNextCheck = false;
      throw const HttpException('Network unavailable');
    }
    token.check();
    return available;
  }

  @override
  Future<AppUpdateCandidate> downloadRelease(
    AppUpdateRelease release,
    AppUpdateCancellation token,
  ) async {
    downloaded.add(release.versionCode);
    tokens.add(token);
    if (download != null) return download!(release, token);
    return candidate(release.versionCode);
  }

  @override
  Future<void> cancel(AppUpdateCancellation token) async {
    cancellations++;
    token.cancel();
  }

  @override
  Future<void> discard(AppUpdateCandidate candidate) async {
    discarded.add(candidate);
  }

  @override
  Future<bool> canInstall() async {
    permissionReads++;
    if (permissionResult != null) return permissionResult!;
    return allowed;
  }

  @override
  Future<void> openUnknownSources() async {
    settingsOpened++;
  }

  @override
  Future<void> launchInstaller(AppUpdateCandidate candidate) async {
    handedOff.add(candidate);
    if (launchResult != null) await launchResult;
  }

  @override
  Future<void> revealWindowsBundle(
    AppUpdateCandidate candidate,
    AppUpdateCancellation token,
  ) async {
    token.check();
    handedOff.add(candidate);
  }
}

Future<void> _open(
  WidgetTester tester,
  _UpdateService service, {
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: AppUpdatePage(service: service),
    ),
  );
  await tester.pumpAndSettle();
}

Future<Finder> _reveal(WidgetTester tester, Finder finder) async {
  await tester.pump();
  if (finder.evaluate().isEmpty) {
    final dialogs = find.byType(AlertDialog);
    final sheets = find.byType(BottomSheet);
    final scope = dialogs.evaluate().isNotEmpty
        ? dialogs.last
        : sheets.evaluate().isNotEmpty
        ? sheets.last
        : find.byType(AppUpdatePage).last;
    final scrollable = find
        .descendant(of: scope, matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(position.minScrollExtent);
    await tester.pump();
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: scrollable,
      maxScrolls: 40,
      duration: const Duration(milliseconds: 50),
    );
    await tester.pump();
  }
  expect(finder, findsOneWidget);
  for (var attempt = 0; attempt < 3; attempt++) {
    await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.hitTestable().evaluate().isNotEmpty) {
      break;
    }
  }
  final target = finder.hitTestable();
  expect(
    target,
    findsOneWidget,
    reason: 'The requested consumer widget must be visible to a real pointer.',
  );
  return target;
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = await _reveal(tester, find.byKey(ValueKey(key)));
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _download(WidgetTester tester) async {
  await _tap(tester, 'app-update-download');
  await _tap(tester, 'app-update-download-confirm');
}

void main() {
  testWidgets('startup update choice fits phone and desktop dialogs', (
    tester,
  ) async {
    final release = _releases([169]).first;
    for (final (size, windows) in [
      (const Size(360, 640), false),
      (const Size(1200, 800), true),
    ]) {
      await tester.binding.setSurfaceSize(size);
      Future<bool?>? choice;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => choice = showStartupUpdateDialog(
                    context,
                    release: release,
                    windows: windows,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('有新版本可用'), findsOneWidget);
      expect(
        find.textContaining(windows ? 'Windows' : 'Android'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('app-startup-update-later')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('app-startup-update-open')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('app-startup-update-open')));
      await tester.pumpAndSettle();
      expect(await choice, true);
      expect(tester.takeException(), isNull);
    }
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets(
    'entry only reads installed identity and selecting an older release cannot download',
    (tester) async {
      final service = _UpdateService();
      await _open(tester, service);
      expect(service.currentReads, 1);
      expect(service.checks, 0);
      expect(service.downloaded, isEmpty);
      await _tap(tester, 'app-update-check');
      expect(service.checks, 1);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('app-update-download')),
            )
            .onPressed,
        isNotNull,
      );
      await _tap(tester, 'app-update-history');
      await _tap(tester, 'app-update-release-159');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('app-update-download')),
            )
            .onPressed,
        isNull,
      );
      expect(service.downloaded, isEmpty);
      await _tap(tester, 'app-update-history');
      await _tap(tester, 'app-update-release-163');
      await _download(tester);
      expect(service.downloaded, [163]);
      expect(service.handedOff, isEmpty);
      await _tap(tester, 'app-update-ready-later');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('missing platform asset and equal builds never enter download', (
    tester,
  ) async {
    final service = _UpdateService(
      available: _releases([164, 162], missing: {164}),
    );
    await _open(tester, service);
    await _tap(tester, 'app-update-check');
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('app-update-download')),
          )
          .onPressed,
      isNull,
    );
    await _tap(tester, 'app-update-history');
    await _tap(tester, 'app-update-release-162');
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('app-update-download')),
          )
          .onPressed,
      isNull,
    );
    expect(service.downloaded, isEmpty);
    expect(service.permissionReads, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'failed release query only retries after another explicit action',
    (tester) async {
      final service = _UpdateService()..failNextCheck = true;
      await _open(tester, service);
      await _tap(tester, 'app-update-check');
      expect(service.checks, 1);
      expect(find.byKey(const ValueKey('app-update-download')), findsNothing);
      expect(find.byKey(const ValueKey('app-update-retry')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(service.checks, 1);
      await _tap(tester, 'app-update-retry');
      expect(service.checks, 2);
      expect(find.byKey(const ValueKey('app-update-download')), findsOneWidget);
      expect(service.downloaded, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'empty release history remains checkable instead of offering a fake update',
    (tester) async {
      final service = _UpdateService(available: []);
      await _open(tester, service);
      await _tap(tester, 'app-update-check');
      expect(find.byKey(const ValueKey('app-update-download')), findsNothing);
      expect(find.byKey(const ValueKey('app-update-history')), findsNothing);
      service.available = _releases([163]);
      await _tap(tester, 'app-update-check');
      expect(service.checks, 2);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('app-update-download')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'cancelled transfer cannot publish even a late candidate or launch an installer',
    (tester) async {
      final complete = Completer<AppUpdateCandidate>();
      final service = _UpdateService()..download = (_, _) => complete.future;
      await _open(tester, service);
      await _tap(tester, 'app-update-check');
      await _tap(tester, 'app-update-download');
      await tester.tap(
        find.byKey(const ValueKey('app-update-download-confirm')),
      );
      await tester.pump();
      service.onProgress?.call(const AppUpdateProgress('download', 512, 1024));
      await tester.pump();
      service.onProgress?.call(const AppUpdateProgress('verify', 1024, 1024));
      await tester.pump();
      final transfer = find.byType(AppUpdateTransferView);
      await _reveal(tester, transfer);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.descendant(
                of: transfer,
                matching: find.byType(LinearProgressIndicator),
              ),
            )
            .value,
        isNull,
      );
      final cancel = find.byKey(const ValueKey('app-update-transfer-cancel'));
      expect(cancel.hitTestable(), findsOneWidget);
      await _reveal(tester, cancel);
      await tester.tap(cancel.hitTestable());
      await tester.pump();
      expect(service.tokens.single.cancelled, isTrue);
      final candidate = service.candidate(163);
      complete.complete(candidate);
      await tester.pumpAndSettle();
      expect(service.cancellations, 1);
      expect(service.discarded, [candidate]);
      expect(find.byType(AppUpdateReadyView), findsNothing);
      expect(
        find.byKey(const ValueKey('app-update-ready-confirm')),
        findsNothing,
      );
      expect(service.handedOff, isEmpty);
      expect(service.permissionReads, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'dispose cancels owned transfer and ignores late progress while discarding late result',
    (tester) async {
      final complete = Completer<AppUpdateCandidate>();
      final service = _UpdateService()..download = (_, _) => complete.future;
      await _open(tester, service);
      await _tap(tester, 'app-update-check');
      await _tap(tester, 'app-update-download');
      await tester.tap(
        find.byKey(const ValueKey('app-update-download-confirm')),
      );
      await tester.pump();
      final lateProgress = service.onProgress!;
      await tester.pumpWidget(const SizedBox.shrink());
      expect(service.tokens.single.cancelled, isTrue);
      lateProgress(const AppUpdateProgress('verified', 1024, 1024));
      final candidate = service.candidate(163);
      complete.complete(candidate);
      await tester.pumpAndSettle();
      expect(service.discarded, [candidate]);
      expect(service.handedOff, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a late installed identity read after disposal cannot mutate the closed page',
    (tester) async {
      final complete = Completer<AppUpdateInfo>();
      final service = _UpdateService()..currentResult = complete.future;
      await tester.pumpWidget(
        MaterialApp(home: AppUpdatePage(service: service)),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      complete.complete(_info(162));
      await tester.pumpAndSettle();
      expect(service.currentReads, 1);
      expect(service.checks, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'later keeps a verified candidate and permission denial never launches or opens settings',
    (tester) async {
      final service = _UpdateService()..allowed = false;
      await _open(tester, service);
      await _tap(tester, 'app-update-check');
      await _download(tester);
      await _tap(tester, 'app-update-ready-later');
      expect(find.byType(AppUpdateReadyView), findsOneWidget);
      expect(service.permissionReads, 0);
      expect(service.discarded, isEmpty);
      await _tap(tester, 'app-update-ready-install');
      await _tap(tester, 'app-update-ready-confirm');
      expect(service.permissionReads, 1);
      expect(service.handedOff, isEmpty);
      expect(service.settingsOpened, 0);
      await _tap(tester, 'app-update-permission-cancel');
      expect(find.byType(AppUpdateReadyView), findsOneWidget);
      expect(service.settingsOpened, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(service.discarded, hasLength(1));
    },
  );

  testWidgets(
    'opening permission settings never resumes installation without another explicit consent',
    (tester) async {
      final service = _UpdateService()..allowed = false;
      await _open(tester, service);
      await _tap(tester, 'app-update-check');
      await _download(tester);
      await _tap(tester, 'app-update-ready-confirm');
      await _tap(tester, 'app-update-permission-settings');
      expect(service.settingsOpened, 1);
      expect(service.handedOff, isEmpty);
      service.allowed = true;
      await tester.pump(const Duration(seconds: 1));
      expect(service.handedOff, isEmpty);
      await _tap(tester, 'app-update-ready-install');
      await _tap(tester, 'app-update-ready-confirm');
      expect(service.permissionReads, 2);
      expect(service.handedOff, hasLength(1));
      expect(find.byType(AppUpdateHandoffView), findsOneWidget);
      expect(find.byType(AppUpdateReadyView), findsNothing);
      expect(
        find.byKey(const ValueKey('app-update-ready-confirm')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(service.discarded, isEmpty);
    },
  );

  testWidgets(
    'single ready consent hands off and a return can deliberately reopen without redownloading',
    (tester) async {
      final service = _UpdateService();
      await _open(tester, service);
      await _tap(tester, 'app-update-check');
      await _download(tester);
      await _tap(tester, 'app-update-ready-confirm');
      expect(service.handedOff, hasLength(1));
      expect(find.byType(AppUpdateHandoffView), findsOneWidget);
      await _tap(tester, 'app-update-handoff-reopen');
      expect(service.handedOff, hasLength(1));
      await _tap(tester, 'app-update-ready-confirm');
      expect(service.handedOff, hasLength(2));
      expect(service.downloaded, [163]);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(service.discarded, isEmpty);
    },
  );

  testWidgets(
    'dispose during system handoff does not remove the file being read',
    (tester) async {
      final launch = Completer<void>();
      final service = _UpdateService()..launchResult = launch.future;
      await _open(tester, service);
      await _tap(tester, 'app-update-check');
      await _download(tester);
      await tester.tap(find.byKey(const ValueKey('app-update-ready-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(service.handedOff, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(service.discarded, isEmpty);
      launch.complete();
      await tester.pumpAndSettle();
      expect(service.discarded, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'permission-read cancellation cannot fall through into a system launch',
    (tester) async {
      final permission = Completer<bool>();
      final service = _UpdateService()..permissionResult = permission.future;
      await _open(tester, service);
      await _tap(tester, 'app-update-check');
      await _download(tester);
      await tester.tap(find.byKey(const ValueKey('app-update-ready-confirm')));
      await tester.pump();
      final cancel = find.byKey(const ValueKey('app-update-transfer-cancel'));
      await _reveal(tester, cancel);
      await tester.tap(cancel.hitTestable());
      await tester.pump();
      permission.complete(true);
      await tester.pumpAndSettle();
      expect(service.handedOff, isEmpty);
      expect(find.byType(AppUpdateReadyView), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Windows identity selects ZIP workflow and never queries Android permission',
    (tester) async {
      final service = _UpdateService(
        platform: 'windows',
        available: _releases([163], platform: 'windows'),
      );
      await _open(tester, service);
      await _tap(tester, 'app-update-check');
      await _download(tester);
      await _tap(tester, 'app-update-ready-later');
      expect(
        find.byKey(const ValueKey('app-update-ready-install')),
        findsNothing,
      );
      await _tap(tester, 'app-update-ready-reveal');
      await _tap(tester, 'app-update-ready-confirm');
      expect(service.permissionReads, 0);
      expect(service.handedOff, hasLength(1));
      expect(
        tester
            .widget<AppUpdateHandoffView>(find.byType(AppUpdateHandoffView))
            .windows,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(service.discarded, isEmpty);
    },
  );

  for (final decision in [
    'wrongSigner',
    'wrongPackage',
    'downgrade',
    'sameVersionChanged',
  ]) {
    testWidgets(
      'rejected $decision candidate never exposes install or calls the system',
      (tester) async {
        final service = _UpdateService();
        final rejected = AppUpdateCandidate(
          current: _info(162),
          offered: _info(163),
          path: '/owned/stage/rejected',
          bytes: 1024,
          source: 'Rejected local identity',
          decision: decision,
          signatureVerified: decision != 'wrongSigner',
        );
        service.download = (_, _) async => rejected;
        await _open(tester, service);
        await _tap(tester, 'app-update-check');
        await _download(tester);
        expect(find.byType(AppUpdateReadyView), findsOneWidget);
        expect(
          find.byKey(const ValueKey('app-update-ready-install')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('app-update-ready-confirm')),
          findsNothing,
        );
        expect(service.permissionReads, 0);
        expect(service.handedOff, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(service.discarded, [rejected]);
      },
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'narrow $brightness page keeps 200-percent ready and permission actions reachable',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final service = _UpdateService()..allowed = false;
        await _open(tester, service, textScale: 2, brightness: brightness);
        await _tap(tester, 'app-update-check');
        await _download(tester);
        await _tap(tester, 'app-update-ready-later');
        expect(service.handedOff, isEmpty);
        await _tap(tester, 'app-update-ready-install');
        await _tap(tester, 'app-update-ready-confirm');
        await _tap(tester, 'app-update-permission-cancel');
        expect(service.settingsOpened, 0);
        expect(service.handedOff, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'back during transfer keeps route owned and offers explicit cancellation',
    (tester) async {
      final complete = Completer<AppUpdateCandidate>();
      final service = _UpdateService()..download = (_, _) => complete.future;
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const Scaffold()),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => AppUpdatePage(service: service),
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'app-update-check');
      await _tap(tester, 'app-update-download');
      await tester.tap(
        find.byKey(const ValueKey('app-update-download-confirm')),
      );
      await tester.pump();
      await navigator.currentState!.maybePop();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AppUpdatePage), findsOneWidget);
      expect(
        find.byKey(const ValueKey('app-update-back-cancel')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('app-update-back-cancel')));
      await tester.pump();
      complete.complete(service.candidate(163));
      await tester.pumpAndSettle();
      expect(service.tokens.single.cancelled, isTrue);
      expect(service.handedOff, isEmpty);
      expect(service.discarded, hasLength(1));
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(AppUpdatePage), findsOneWidget);
      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(AppUpdatePage), findsNothing);
    },
  );

  testWidgets(
    'failed download retry asks again before starting another real transfer',
    (tester) async {
      final service = _UpdateService();
      var failed = false;
      service.download = (release, _) async {
        if (!failed) {
          failed = true;
          throw const HttpException('Network interrupted');
        }
        return service.candidate(release.versionCode);
      };
      await _open(tester, service);
      await _tap(tester, 'app-update-check');
      await _download(tester);
      expect(service.downloaded, [163]);
      expect(find.byType(AppUpdateReadyView), findsNothing);
      await _tap(tester, 'app-update-retry');
      expect(service.downloaded, [163]);
      await _tap(tester, 'app-update-download-confirm');
      expect(service.downloaded, [163, 163]);
      await _tap(tester, 'app-update-ready-later');
      expect(find.byType(AppUpdateReadyView), findsOneWidget);
      expect(service.handedOff, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed system handoff after disposal still removes its untransferred candidate',
    (tester) async {
      final launch = Completer<void>();
      final service = _UpdateService()..launchResult = launch.future;
      await _open(tester, service);
      await _tap(tester, 'app-update-check');
      await _download(tester);
      await tester.tap(find.byKey(const ValueKey('app-update-ready-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(service.handedOff, hasLength(1));
      final candidate = service.handedOff.single;
      await tester.pumpWidget(const SizedBox.shrink());
      launch.completeError(StateError('System could not open installer'));
      await tester.pumpAndSettle();
      expect(service.discarded, [candidate]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow local Windows form stays scrollable with keyboard and cancel does not install',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final service = _UpdateService(platform: 'windows');
      await _open(tester, service, textScale: 2);
      await _tap(tester, 'app-update-local-packages');
      final zip = find.byKey(const ValueKey('app-update-local-zip'));
      await tester.ensureVisible(zip);
      await tester.enterText(zip, 'D:/owned/update.zip');
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      final manifest = find.byKey(const ValueKey('app-update-local-manifest'));
      await tester.ensureVisible(manifest);
      await tester.enterText(manifest, 'D:/owned/triomi-windows.update.json');
      await _tap(tester, 'app-update-local-verify');
      await _tap(tester, 'app-update-confirm-cancel');
      expect(service.handedOff, isEmpty);
      expect(service.permissionReads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'handoff rereads real installed identity without claiming or triggering installation',
    (tester) async {
      final service = _UpdateService();
      await _open(tester, service);
      await _tap(tester, 'app-update-check');
      await _download(tester);
      await _tap(tester, 'app-update-ready-confirm');
      expect(service.handedOff, hasLength(1));
      service.currentResult = Future.value(_info(163));
      final refresh = find.descendant(
        of: find.byType(AppUpdateHandoffView),
        matching: find.byIcon(Icons.refresh),
      );
      await _reveal(tester, refresh);
      await tester.tap(refresh.hitTestable());
      await tester.pumpAndSettle();
      expect(service.currentReads, 3);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('app-update-installed-version')),
            )
            .data,
        contains('163'),
      );
      expect(find.byType(AppUpdateHandoffView), findsOneWidget);
      expect(service.handedOff, hasLength(1));
      expect(
        find.byKey(const ValueKey('app-update-handoff-reopen')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('app-update-ready-confirm')),
        findsNothing,
      );
      expect(service.handedOff, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(service.discarded, isEmpty);
    },
  );

  testWidgets(
    'unsupported current capability exposes no repeated read or update requests',
    (tester) async {
      final service = _UpdateService()..unsupportedCurrent = true;
      await _open(tester, service);
      expect(service.currentReads, 1);
      expect(service.checks, 0);
      expect(service.downloaded, isEmpty);
      expect(find.byKey(const ValueKey('app-update-check')), findsNothing);
      expect(find.byKey(const ValueKey('app-update-retry')), findsNothing);
      expect(
        find.byKey(const ValueKey('app-update-refresh-current')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('app-update-download')), findsNothing);
      expect(
        find.byKey(const ValueKey('app-update-local-packages')),
        findsNothing,
      );
      expect(find.byType(AppUpdateTransferView), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(service.currentReads, 1);
      expect(service.checks, 0);
      expect(service.permissionReads, 0);
      expect(service.settingsOpened, 0);
      expect(service.handedOff, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'retained candidate remains the visible operation target after selecting an older release',
    (tester) async {
      final permission = Completer<bool>();
      final launch = Completer<void>();
      final service = _UpdateService()
        ..permissionResult = permission.future
        ..launchResult = launch.future;
      final offeredRelease = service.available.first;
      final olderRelease = service.available.last;
      final retained = service.candidate(offeredRelease.versionCode);
      service.download = (_, _) async => retained;
      await _open(tester, service);
      await _tap(tester, 'app-update-check');
      await _download(tester);
      await _tap(tester, 'app-update-ready-later');
      await _tap(tester, 'app-update-history');
      await _tap(tester, 'app-update-release-${olderRelease.versionCode}');
      await _tap(tester, 'app-update-ready-install');
      final confirm = await _reveal(
        tester,
        find.byKey(const ValueKey('app-update-ready-confirm')),
      );
      await tester.tap(confirm);
      await tester.pump();
      final transfer = find.byType(AppUpdateTransferView);
      await _reveal(tester, transfer);
      expect(
        tester.widget<AppUpdateTransferView>(transfer).versionLabel,
        contains('${retained.offered.versionCode}'),
      );
      expect(
        tester.widget<AppUpdateTransferView>(transfer).versionLabel,
        isNot(contains('${olderRelease.versionCode}')),
      );
      permission.complete(true);
      await tester.pump();
      await _reveal(tester, transfer);
      expect(
        tester.widget<AppUpdateTransferView>(transfer).versionLabel,
        contains('${retained.offered.versionCode}'),
      );
      expect(service.handedOff, [retained]);
      launch.complete();
      await tester.pumpAndSettle();
      await _reveal(tester, find.byType(AppUpdateHandoffView));
      expect(service.downloaded, [offeredRelease.versionCode]);
      expect(service.handedOff, [retained]);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(service.discarded, isEmpty);
    },
  );
}
